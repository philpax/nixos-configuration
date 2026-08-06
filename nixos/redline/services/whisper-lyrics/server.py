#!/usr/bin/env python3
"""GPU transcription service shaped like an AudioMuse-AI external lyrics API.

AudioMuse consults its configured lyrics-API slots before falling back to its
internal (CPU-bound) Whisper ONNX decoder. This service fills that slot:
given artist/title it finds the track via Navidrome's Subsonic API, downloads
it, and transcribes it with faster-whisper (CTranslate2, device-resident KV
cache) on the GPU. A hit here means AudioMuse's own Whisper never runs.

GET /lyrics?artist=...&title=...&key=...  ->  {"lyrics": "..."} or 404 (miss)
GET /health                               ->  200 once the model is loaded
"""

import hmac
import json
import logging
import os
import sys
import tempfile
import threading
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

log.info("Loading faster-whisper model %r ...", WHISPER_MODEL)
from faster_whisper import WhisperModel  # noqa: E402  (import after logging setup)

model = WhisperModel(WHISPER_MODEL, device="cuda", compute_type="float16")
# One transcription at a time; concurrent requests queue on this lock and
# AudioMuse's slot timeout (set generously in audiomuse.nix) absorbs the wait.
gpu_lock = threading.Lock()
log.info("Model loaded; serving on port %d", PORT)


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
        with gpu_lock:
            segments, info = model.transcribe(tmp.name, beam_size=5, vad_filter=True)
            text = "\n".join(seg.text.strip() for seg in segments).strip()
    log.info(
        "Transcribed %s: language=%s, %d chars", song_id, info.language, len(text)
    )
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
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
