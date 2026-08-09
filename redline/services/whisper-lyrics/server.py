#!/usr/bin/env python3
"""GPU transcription service shaped like an AudioMuse-AI external lyrics API.

AudioMuse consults its configured lyrics-API slots before falling back to its
internal (CPU-bound) Whisper ONNX decoder. This service fills that slot:
given artist/title it finds the track via Navidrome's Subsonic API, downloads
it, and transcribes it with faster-whisper (CTranslate2, device-resident KV
cache) on the GPU. A hit here means AudioMuse's own Whisper never runs.

This is used a handful of times a month, so the server process itself never
touches CUDA: transcription happens in a worker subprocess (`--worker`) that
is spawned on demand and killed after IDLE_TIMEOUT seconds of inactivity.
Between bursts the service holds no VRAM at all — not even a CUDA context.
The worker is kept alive across a burst rather than respawned per track:
thousands of short-lived CUDA contexts are what wedge this box's driver.

GET /lyrics?artist=...&title=...&key=...  ->  {"lyrics": "..."} or 404 (miss)
GET /health                               ->  200 (the model loads lazily)
"""

import hmac
import json
import logging
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("whisper-lyrics")

NAVIDROME_URL = os.environ["NAVIDROME_URL"].rstrip("/")
NAVIDROME_USER = os.environ["NAVIDROME_USER"]
NAVIDROME_PASSWORD = os.environ["NAVIDROME_PASSWORD"]
API_KEY = os.environ.get("API_KEY", "")
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "large-v3-turbo")
PORT = int(os.environ.get("PORT", "8801"))
# Seconds of inactivity before the GPU worker is killed; <= 0 keeps it alive.
IDLE_TIMEOUT = float(os.environ.get("IDLE_TIMEOUT", "300"))


def worker_main() -> int:
    """Child process: own the GPU, transcribe paths fed as JSON lines on stdin.

    Requests arrive on stdin, one `{"path": ...}` per line; replies go out on
    the inherited fd named by RESULT_FD (not stdout, which libraries print to)
    as `{"text": ...}` or `{"error": ...}`. EOF on stdin ends the process, and
    with it every byte of GPU state.
    """
    log.info("Worker loading faster-whisper model %r ...", WHISPER_MODEL)
    from faster_whisper import WhisperModel

    model = WhisperModel(WHISPER_MODEL, device="cuda", compute_type="float16")
    log.info("Worker ready")

    out = os.fdopen(int(os.environ["RESULT_FD"]), "w")
    for line in sys.stdin:
        path = json.loads(line)["path"]
        try:
            segments, info = model.transcribe(path, beam_size=5, vad_filter=True)
            reply = {
                "text": "\n".join(seg.text.strip() for seg in segments).strip(),
                "language": info.language,
            }
        except Exception as exc:
            log.exception("Worker failed on %s", path)
            reply = {"error": f"{type(exc).__name__}: {exc}"}
        out.write(json.dumps(reply) + "\n")
        out.flush()
    log.info("Worker stdin closed; exiting")
    return 0


class Worker:
    """Lazily spawned GPU worker, reaped once idle. Serialises transcriptions."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.proc: subprocess.Popen | None = None
        self.replies = None
        self.last_use = time.monotonic()

    def _spawn(self) -> None:
        read_fd, write_fd = os.pipe()
        try:
            self.proc = subprocess.Popen(
                [sys.executable, os.path.abspath(__file__), "--worker"],
                stdin=subprocess.PIPE,
                pass_fds=(write_fd,),
                env={**os.environ, "RESULT_FD": str(write_fd)},
                text=True,
            )
        finally:
            os.close(write_fd)
        self.replies = os.fdopen(read_fd, "r")

    def shutdown(self) -> None:
        """Close stdin so the worker exits at EOF; kill it if it lingers."""
        proc, replies = self.proc, self.replies
        self.proc, self.replies = None, None
        if proc is None:
            return
        try:
            proc.stdin.close()
            proc.wait(timeout=30)
        except Exception:
            proc.kill()
            proc.wait()
        finally:
            if replies is not None:
                replies.close()

    def transcribe(self, path: str) -> dict:
        with self.lock:
            try:
                return self._request(path)
            except Exception:
                # A worker that died mid-burst (OOM, idle race) shouldn't cost
                # the caller its request: respawn once and retry.
                log.exception("Worker request failed; restarting worker")
                self.shutdown()
                return self._request(path)
            finally:
                self.last_use = time.monotonic()

    def _request(self, path: str) -> dict:
        if self.proc is None or self.proc.poll() is not None:
            self.shutdown()
            self._spawn()
        self.proc.stdin.write(json.dumps({"path": path}) + "\n")
        self.proc.stdin.flush()
        line = self.replies.readline()
        if not line:
            raise RuntimeError("worker exited without replying")
        return json.loads(line)

    def reap_when_idle(self) -> None:
        while True:
            time.sleep(min(IDLE_TIMEOUT, 30.0))
            with self.lock:
                idle = time.monotonic() - self.last_use
                if self.proc is not None and idle >= IDLE_TIMEOUT:
                    log.info("Idle for %.0fs; stopping GPU worker", idle)
                    self.shutdown()


worker = Worker()


def subsonic(endpoint: str, **params):
    query = {
        "u": NAVIDROME_USER,
        "p": NAVIDROME_PASSWORD,
        "v": "1.16.1",
        "c": "whisper-lyrics",
        "f": "json",
        **params,
    }
    url = f"{NAVIDROME_URL}/rest/{endpoint}?{urllib.parse.urlencode(query)}"
    return urllib.request.urlopen(url, timeout=30)


def normalize(s: str) -> str:
    return "".join(c for c in s.lower() if c.isalnum())


def find_song(artist: str, title: str):
    """Best Subsonic match for artist/title, preferring exact normalized matches."""
    with subsonic(
        "search3",
        query=f"{artist} {title}",
        songCount=10,
        artistCount=0,
        albumCount=0,
    ) as resp:
        data = json.load(resp)
    result = data.get("subsonic-response", {}).get("searchResult3") or {}
    songs = result.get("song") or []
    for song in songs:
        if normalize(song.get("title", "")) == normalize(title) and normalize(
            song.get("artist", "")
        ) == normalize(artist):
            return song
    return songs[0] if songs else None


def transcribe(song_id: str, suffix: str) -> str:
    with tempfile.NamedTemporaryFile(suffix=f".{suffix or 'audio'}") as tmp:
        with subsonic("download", id=song_id) as resp:
            while chunk := resp.read(1 << 20):
                tmp.write(chunk)
        tmp.flush()
        reply = worker.transcribe(tmp.name)
    if "error" in reply:
        raise RuntimeError(reply["error"])
    text = reply["text"]
    log.info("Transcribed %s: language=%s, %d chars", song_id, reply["language"], len(text))
    return text


class Handler(BaseHTTPRequestHandler):
    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # route http.server logging into ours
        log.info("%s %s", self.address_string(), fmt % args)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)

        def param(key: str) -> str:
            return (query.get(key) or [""])[0].strip()

        if parsed.path == "/health":
            return self._send(200, {"status": "ok"})
        if parsed.path != "/lyrics":
            return self._send(404, {"error": "not found"})
        if API_KEY and not hmac.compare_digest(param("key"), API_KEY):
            return self._send(403, {"error": "bad key"})

        artist, title = param("artist"), param("title")
        if not artist or not title:
            return self._send(400, {"error": "artist and title required"})

        try:
            song = find_song(artist, title)
            if song is None:
                log.info("No Subsonic match for %r / %r", artist, title)
                return self._send(404, {"error": "track not found"})
            text = transcribe(song["id"], song.get("suffix", ""))
        except Exception:
            log.exception("Transcription failed for %r / %r", artist, title)
            return self._send(500, {"error": "transcription failed"})

        if not text:
            # Instrumental (VAD found no speech): a miss, so AudioMuse stores
            # its instrumental sentinel rather than fake lyrics.
            return self._send(404, {"error": "no speech detected"})
        return self._send(200, {"lyrics": text})


def main() -> None:
    if IDLE_TIMEOUT > 0:
        threading.Thread(target=worker.reap_when_idle, daemon=True).start()
    log.info("Serving on port %d (GPU worker spawns on first request)", PORT)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    try:
        server.serve_forever()
    finally:
        with worker.lock:
            worker.shutdown()


if __name__ == "__main__":
    if "--worker" in sys.argv[1:]:
        sys.exit(worker_main())
    sys.exit(main())
