"""Tests for Frame's nested niri session and host cursor matching."""

import importlib.util
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import Mock, patch

import pytest

ROOT = Path(__file__).resolve().parents[1]


def load_module(name, path, modules=None):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, modules or {}):
        spec.loader.exec_module(module)
    return module


@pytest.fixture
def niri_launch():
    return load_module("frame_niri_launch", ROOT / "frame" / "niri-launch.py")


@pytest.fixture
def niri_cursor():
    xlib = ModuleType("Xlib")
    xlib.X = SimpleNamespace(AnyPropertyType=0)
    xlib.display = SimpleNamespace()
    xlib.error = SimpleNamespace(BadWindow=type("BadWindow", (Exception,), {}))
    return load_module(
        "frame_niri_host_cursor",
        ROOT / "frame" / "niri-host-cursor.py",
        {"Xlib": xlib},
    )


def test_session_environment_targets_nested_niri_and_cleans_inherited_session(
    niri_launch, tmp_path
):
    parent = {
        "DISPLAY": ":42",
        "XDG_RUNTIME_DIR": "/run/user/999",
        "XDG_SESSION_TYPE": "x11",
        "XDG_CURRENT_DESKTOP": "KDE",
        "XDG_SESSION_DESKTOP": "plasma",
        "WAYLAND_DISPLAY": "wayland-9",
        "WAYLAND_SOCKET": "8",
        "NIRI_SOCKET": "/run/user/999/niri.1234.sock",
        "NIRI_CONFIG": "/home/user/niri.kdl",
        "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/999/bus",
        "DBUS_SESSION_BUS_PID": "999",
        "XDG_DESKTOP_PORTAL_DIR": "/run/user/999/xdg-desktop-portal",
        "LD_PRELOAD": "/tmp/injected.so",
        "QT_QPA_PLATFORM": "wayland",
        "QT_QPA_PLATFORMTHEME": "qt5ct",
        "PULSE_SERVER": "unix:/run/user/999/pulse/native",
        "PIPEWIRE_REMOTE": "pipewire-9",
        "UNRELATED_VALUE": "keep me",
    }

    env = niri_launch.session_environment(parent, tmp_path / "nested-runtime")

    assert env["DISPLAY"] == ":0"
    assert env["XDG_RUNTIME_DIR"] == str(tmp_path / "nested-runtime")
    assert env["XDG_SESSION_TYPE"] == "wayland"
    assert env["XDG_CURRENT_DESKTOP"] == "niri"
    assert env["XDG_SESSION_DESKTOP"] == "niri"
    assert env["XCURSOR_SIZE"] == "24"
    assert env["XCURSOR_THEME"] == "volantes_light_cursors"
    for key in (
        "WAYLAND_DISPLAY",
        "WAYLAND_SOCKET",
        "NIRI_SOCKET",
        "NIRI_CONFIG",
        "DBUS_SESSION_BUS_ADDRESS",
        "DBUS_SESSION_BUS_PID",
        "XDG_DESKTOP_PORTAL_DIR",
        "LD_PRELOAD",
        "QT_QPA_PLATFORM",
        "QT_QPA_PLATFORMTHEME",
    ):
        assert key not in env
    assert env["PULSE_SERVER"] == parent["PULSE_SERVER"]
    assert env["PIPEWIRE_REMOTE"] == parent["PIPEWIRE_REMOTE"]
    assert env["UNRELATED_VALUE"] == parent["UNRELATED_VALUE"]
    assert parent["DISPLAY"] == ":42"
    assert parent["NIRI_SOCKET"] == "/run/user/999/niri.1234.sock"


def test_link_session_sockets_links_only_existing_allowed_host_sockets(niri_launch, tmp_path):
    host_runtime = tmp_path / "host-runtime"
    runtime = tmp_path / "nested-runtime"
    host_runtime.mkdir()
    runtime.mkdir()
    existing = ("pulse", "pipewire-0", "ssh-agent")
    for name in (*existing, "wayland-0", "bus"):
        (host_runtime / name).touch()

    niri_launch.link_session_sockets(host_runtime, runtime)

    assert {path.name for path in runtime.iterdir()} == set(existing)
    for name in existing:
        linked = runtime / name
        assert linked.is_symlink()
        assert linked.resolve() == host_runtime / name
    assert not (runtime / "pipewire-0-manager").exists()
    assert not (runtime / "wayland-0").exists()
    assert not (runtime / "bus").exists()


def test_service_command_cleans_entire_desktop_without_importing_global_environment(niri_launch):
    args = SimpleNamespace(
        systemd_run="/usr/bin/systemd-run",
        dbus_run_session="/nix/dbus-run-session",
        niri="/nix/niri",
        config="/nix/frame-config.kdl",
    )
    command = niri_launch.service_command(args, {"DISPLAY": ":0", "XDG_RUNTIME_DIR": "/private"})
    assert "--property=KillMode=control-group" in command
    assert "--property=TimeoutStopSec=10s" in command
    assert "--unit=frame-niri-desktop.service" in command
    assert "--setenv=DISPLAY=:0" in command
    assert "--setenv=XDG_RUNTIME_DIR=/private" in command
    assert "--property=UnsetEnvironment=" + " ".join(niri_launch.UNSET_ENVIRONMENT) in command
    assert "--session" not in command
    assert command[-6:] == [
        "--",
        "/nix/dbus-run-session",
        "--",
        "/nix/niri",
        "--config",
        "/nix/frame-config.kdl",
    ]


@pytest.mark.parametrize("state", ["inactive", "failed"])
def test_stop_service_accepts_collected_or_inactive_unit(niri_launch, state):
    args = SimpleNamespace(systemctl="/usr/bin/systemctl")
    with patch.object(
        niri_launch.subprocess, "run", return_value=SimpleNamespace(stdout=state)
    ) as run:
        niri_launch.stop_service(args, {"XDG_RUNTIME_DIR": "/host"})
    assert run.call_count == 1
    assert run.call_args.kwargs["check"] is True


def test_stop_service_stops_active_unit_and_confirms_shutdown(niri_launch):
    args = SimpleNamespace(systemctl="/usr/bin/systemctl")
    with patch.object(niri_launch.subprocess, "run") as run:
        run.side_effect = [
            SimpleNamespace(stdout="active"),
            None,
            SimpleNamespace(stdout="inactive"),
        ]
        niri_launch.stop_service(args, {})
    assert run.call_count == 3
    assert run.call_args_list[1].args[0] == [
        "/usr/bin/systemctl",
        "--user",
        "stop",
        niri_launch.UNIT,
    ]
    assert run.call_args_list[1].kwargs["check"] is True


def test_stop_service_rejects_unconfirmed_shutdown(niri_launch):
    args = SimpleNamespace(systemctl="/usr/bin/systemctl")
    with patch.object(niri_launch.subprocess, "run") as run:
        run.side_effect = [SimpleNamespace(stdout="active"), None, SimpleNamespace(stdout="active")]
        with pytest.raises(RuntimeError, match="did not stop"):
            niri_launch.stop_service(args, {})


@pytest.mark.parametrize("shutdown_fails", [False, True])
def test_main_confirms_shutdown_after_monitor_client_exits(niri_launch, tmp_path, shutdown_fails):
    host = tmp_path / "host"
    host.mkdir()
    runtime = tmp_path / "private"
    runtime.mkdir()
    monitor = Mock()
    monitor.wait.return_value = -15
    with (
        patch.object(
            sys,
            "argv",
            ["frame-niri", "--niri", "/niri", "--dbus-run-session", "/dbus", "--config", "/config"],
        ),
        patch.object(niri_launch, "Path", side_effect=[host, runtime]),
        patch.object(niri_launch.tempfile, "mkdtemp", return_value=str(runtime)),
        patch.object(niri_launch.subprocess, "Popen", return_value=monitor),
        patch.object(niri_launch, "service_stopped", return_value=True),
        patch.object(niri_launch, "stop_service") as stop,
    ):
        if shutdown_fails:
            stop.side_effect = RuntimeError("shutdown failed")
            with pytest.raises(RuntimeError, match="shutdown failed"):
                niri_launch.main()
        else:
            with pytest.raises(SystemExit) as result:
                niri_launch.main()
            assert result.value.code == -15
    stop.assert_called_once()
    assert runtime.exists() is shutdown_fails
    monitor.poll.assert_not_called()


def niri_window(title=b"niri", pid=123):
    properties = {
        "name": SimpleNamespace(value=title) if title is not None else None,
        "pid": SimpleNamespace(value=[pid]) if pid is not None else None,
    }
    result = Mock()
    result.get_full_property.side_effect = lambda atom, _kind: properties[atom]
    return result


@pytest.mark.parametrize(
    ("title", "pid", "expected"),
    [
        (b"niri", 123, True),
        (b"Niri", 123, False),
        (b"niri window", 123, False),
        (b"other", 123, False),
        (b"niri", 124, False),
        (b"niri", None, False),
        (None, 123, False),
        (None, None, False),
    ],
)
def test_is_niri_window_requires_exact_title_and_pid(niri_cursor, title, pid, expected):
    window = niri_window(title, pid)

    assert niri_cursor.is_niri_window(window, 123, "name", "pid") is expected
    assert [call.args for call in window.get_full_property.call_args_list] == [
        ("name", niri_cursor.X.AnyPropertyType),
        ("pid", niri_cursor.X.AnyPropertyType),
    ]
