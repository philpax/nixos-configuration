"""Check live cleanup after killing only the Frame niri monitoring client.

Run on Frame with a built frame-niri executable as the sole argument.
The check opens a nested desktop briefly and stops it before returning.
"""

import os
import re
import select
import signal
import subprocess
import sys
import time
from pathlib import Path


def main():
    launcher = sys.argv[1]
    host_runtime = Path(f"/run/user/{os.getuid()}")
    env = dict(os.environ)
    env.update(
        XDG_RUNTIME_DIR=str(host_runtime),
        DBUS_SESSION_BUS_ADDRESS=f"unix:path={host_runtime}/bus",
    )
    env.pop("LD_LIBRARY_PATH", None)
    env.pop("LD_PRELOAD", None)
    command = ["/usr/bin/systemctl", "--user"]
    unit = "frame-niri-desktop.service"

    def state():
        return subprocess.check_output(
            [*command, "show", unit, "-p", "ActiveState", "--value"], env=env, text=True
        ).strip()

    assert state() in ("inactive", "failed"), "A Frame niri desktop is already running"
    process = subprocess.Popen([launcher], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log = b""
    try:
        deadline = time.monotonic() + 30
        match = None
        while match is None and time.monotonic() < deadline:
            assert process.poll() is None, log.decode(errors="replace")
            if select.select([process.stdout], [], [], 1)[0]:
                log += os.read(process.stdout.fileno(), 65536)
            match = re.search(rb"IPC listening on: (\S+/niri\.\S+\.\d+\.sock)", log)
        assert match, log.decode(errors="replace")
        runtime = Path(match[1].decode()).parent
        # Use the running niri executable rather than a potentially different host version.
        niri_pid = int(match[1].decode().rsplit(".", 2)[1])
        niri = str(Path(f"/proc/{niri_pid}/exe").resolve())
        ipc_env = dict(env, NIRI_SOCKET=match[1].decode())
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            layers = subprocess.check_output(
                [niri, "msg", "--json", "layers"], env=ipc_env, text=True
            )
            if '"quickshell"' in layers and '"wallpaper"' in layers:
                break
            select.select([], [], [], 0.1)
        else:
            raise AssertionError(f"Desktop layers did not appear: {layers}")
        group = subprocess.check_output(
            [*command, "show", unit, "-p", "ControlGroup", "--value"], env=env, text=True
        ).strip()
        pids = (Path("/sys/fs/cgroup") / group.lstrip("/") / "cgroup.procs").read_text().split()
        children = Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text().split()
        clients = [
            pid
            for pid in children
            if Path(f"/proc/{pid}/comm").read_text().strip() == "systemd-run"
        ]
        assert len(clients) == 1, children
        os.kill(int(clients[0]), signal.SIGKILL)
        assert process.wait(timeout=25) == 247
        assert state() in ("inactive", "failed")
        assert not runtime.exists(), runtime
        assert all(not Path(f"/proc/{pid}").exists() for pid in pids), pids
        print("PASS: bar and wallpaper loaded; monitor SIGKILL cleaned up desktop and runtime")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=25)
            except subprocess.TimeoutExpired:
                subprocess.run([*command, "stop", unit], env=env, check=True, timeout=20)
                process.kill()
                process.wait(timeout=5)
        process.stdout.close()


if __name__ == "__main__":
    main()
