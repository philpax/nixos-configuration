import json
import os
import shutil
import socket
import subprocess
import sys
from pathlib import Path

import pytest

FISH = shutil.which("fish")
FUNCTION = (
    Path(__file__).resolve().parents[1] / "common-all/dotfiles/.config/fish/functions/zellij.fish"
)
pytestmark = pytest.mark.skipif(FISH is None, reason="fish is not installed")


@pytest.fixture
def launch(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    host_runtime = tmp_path / "host"
    host_runtime.mkdir()
    host_bus = socket.socket(socket.AF_UNIX)
    host_bus.bind(str(host_runtime / "bus"))
    helper = tmp_path / "zellij.fish"
    helper.write_text(FUNCTION.read_text().replace("/run/user/(id -u)", '"$TEST_HOST_RUNTIME"'))
    stub = (
        f"#!{sys.executable}\n"
        + """
import json
import os
import sys
from pathlib import Path

name = Path(sys.argv[0]).name
keys = ('XDG_RUNTIME_DIR', 'ZELLIJ_SOCKET_DIR', 'DBUS_SESSION_BUS_ADDRESS', 'WAYLAND_DISPLAY')
record = dict(args=sys.argv[1:], cwd=os.getcwd(), env={k: os.environ.get(k) for k in keys})
Path(os.environ['RECORD_DIR'], name + '.json').write_text(json.dumps(record))
if name == 'systemd-run':
    if os.environ.get('FAIL_SCOPE'):
        sys.exit(42)
    args = sys.argv[sys.argv.index('--') + 1:]
    os.execvp(args[0], args)
sys.exit(7)
"""
    )
    for name in ("zellij", "systemd-run"):
        executable = bin_dir / name
        executable.write_text(stub)
        executable.chmod(0o755)

    def run(*args, runtime="/run/user/4242/nested", bus="unix:path=/nested/bus", **extra):
        env = dict(os.environ)
        for key in ("ZELLIJ_SOCKET_DIR", "DBUS_SESSION_BUS_ADDRESS"):
            env.pop(key, None)
        env.update(
            PATH=f"{bin_dir}:{env['PATH']}",
            RECORD_DIR=str(tmp_path),
            XDG_RUNTIME_DIR=runtime,
            WAYLAND_DISPLAY="wayland-9",
            TEST_HOST_RUNTIME=str(host_runtime),
        )
        if bus is not None:
            env["DBUS_SESSION_BUS_ADDRESS"] = bus
        env.update(extra)
        if extra.get("NO_HOST_BUS"):
            (host_runtime / "bus").unlink()
        script = "source $argv[1]; zellij $argv[2..]"
        result = subprocess.run(
            [FISH, "--no-config", "-c", script, str(helper), *args],
            cwd=tmp_path,
            env=env,
            capture_output=True,
            text=True,
        )
        records = {path.stem: json.loads(path.read_text()) for path in tmp_path.glob("*.json")}
        return result, records

    yield run
    host_bus.close()


@pytest.mark.parametrize(
    "runtime", ["/run/user/4242", "/run/user/4242/nested_plasma", "/run/user/4242/frame-niri-abcd"]
)
@pytest.mark.parametrize("bus", [None, "unix:path=/nested/bus"])
def test_shared_socket_and_scope_preserve_compositor_environment(launch, tmp_path, runtime, bus):
    args = ("attach", "session with spaces", "--", "printf", "$HOME")
    result, records = launch(*args, runtime=runtime, bus=bus)
    assert result.returncode == 7, result.stderr
    client = records["zellij"]
    assert client["args"] == list(args)
    assert client["env"] == {
        "XDG_RUNTIME_DIR": runtime,
        "ZELLIJ_SOCKET_DIR": str(tmp_path / "host/zellij"),
        "DBUS_SESSION_BUS_ADDRESS": bus,
        "WAYLAND_DISPLAY": "wayland-9",
    }
    scope = records["systemd-run"]
    assert scope["env"]["DBUS_SESSION_BUS_ADDRESS"] == f"unix:path={tmp_path}/host/bus"
    assert scope["env"]["XDG_RUNTIME_DIR"] == str(tmp_path / "host")
    assert scope["args"][:6] == [
        "--user",
        "--scope",
        "--quiet",
        "--collect",
        "--expand-environment=no",
        "--",
    ]
    assert scope["cwd"] == client["cwd"]


def test_custom_socket_directory_is_respected(launch):
    result, records = launch("list-sessions", ZELLIJ_SOCKET_DIR="/custom/socket directory")
    assert result.returncode == 7, result.stderr
    assert records["zellij"]["env"]["ZELLIJ_SOCKET_DIR"] == "/custom/socket directory"


def test_without_user_bus_runs_directly(launch, tmp_path):
    result, records = launch("--version", NO_HOST_BUS="1")
    assert result.returncode == 7, result.stderr
    assert set(records) == {"zellij"}
    assert records["zellij"]["args"] == ["--version"]
    assert records["zellij"]["env"]["ZELLIJ_SOCKET_DIR"] == str(tmp_path / "host/zellij")


def test_scope_failure_does_not_silently_start_unprotected_server(launch):
    result, records = launch("attach", "work", FAIL_SCOPE="1")
    assert result.returncode == 42, result.stderr
    assert set(records) == {"systemd-run"}
