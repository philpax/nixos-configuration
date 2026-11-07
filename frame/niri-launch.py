#!/usr/bin/env python3
"""Run niri as a separate nested desktop inside Frame's gamescope session."""

import argparse
import fcntl
import os
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

# These must not leak in from a launching KDE/niri desktop or the user manager.
UNSET_ENVIRONMENT = (
    "WAYLAND_DISPLAY",
    "WAYLAND_SOCKET",
    "NIRI_SOCKET",
    "NIRI_CONFIG",
    "DBUS_SESSION_BUS_ADDRESS",
    "DBUS_SESSION_BUS_PID",
    "XDG_DESKTOP_PORTAL_DIR",
    "QT_QPA_PLATFORM",
    "QT_QPA_PLATFORMTHEME",
    "LD_PRELOAD",
)
UNIT = "frame-niri-desktop.service"


def session_environment(parent, runtime):
    env = dict(parent)
    # Always target gamescope rather than the KDE/niri session that launched this app.
    env.update(
        DISPLAY=":0",
        XDG_RUNTIME_DIR=str(runtime),
        XDG_SESSION_TYPE="wayland",
        XDG_CURRENT_DESKTOP="niri",
        XDG_SESSION_DESKTOP="niri",
        XCURSOR_SIZE="24",
        XCURSOR_THEME="volantes_light_cursors",
    )
    for key in UNSET_ENVIRONMENT:
        env.pop(key, None)
    return env


def link_session_sockets(host_runtime, runtime):
    # Share audio and the existing SSH agent, not the host Wayland or D-Bus socket.
    for name in ("pulse", "pipewire-0", "pipewire-0-manager", "ssh-agent"):
        source = host_runtime / name
        if source.exists():
            (runtime / name).symlink_to(source)


def service_command(args, env):
    # systemd stops all descendants, including terminal jobs in separate process groups.
    command = [
        args.systemd_run,
        "--user",
        "--wait",
        "--pipe",
        "--collect",
        f"--unit={UNIT}",
        "--service-type=exec",
        "--property=KillMode=control-group",
        "--property=TimeoutStopSec=10s",
        "--property=UnsetEnvironment=" + " ".join(UNSET_ENVIRONMENT),
    ]
    command.extend(f"--setenv={key}={value}" for key, value in env.items())
    command.extend(["--", args.dbus_run_session, "--", args.niri, "--config", args.config])
    return command


def service_stopped(args, manager_env):
    state = subprocess.run(
        [args.systemctl, "--user", "show", UNIT, "-p", "ActiveState", "--value"],
        env=manager_env,
        capture_output=True,
        text=True,
        timeout=20,
        check=True,
    )
    return state.stdout.strip() in ("inactive", "failed")


def stop_service(args, manager_env):
    if not service_stopped(args, manager_env):
        subprocess.run(
            [args.systemctl, "--user", "stop", UNIT],
            env=manager_env,
            check=True,
            timeout=20,
        )
        if not service_stopped(args, manager_env):
            raise RuntimeError(f"{UNIT} did not stop")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--niri", required=True)
    parser.add_argument("--dbus-run-session", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--systemd-run", default="/usr/bin/systemd-run")
    parser.add_argument("--systemctl", default="/usr/bin/systemctl")
    args = parser.parse_args()
    host_runtime = Path(f"/run/user/{os.getuid()}")
    lock = (host_runtime / "frame-niri.lock").open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.exit(1, "The Frame niri desktop is already running.\n")
    runtime = Path(tempfile.mkdtemp(prefix="frame-niri-", dir=host_runtime))
    link_session_sockets(host_runtime, runtime)
    env = session_environment(os.environ, runtime)
    manager_env = dict(os.environ)
    manager_env.update(
        XDG_RUNTIME_DIR=str(host_runtime),
        DBUS_SESSION_BUS_ADDRESS=f"unix:path={host_runtime}/bus",
    )
    # Host systemd tools must not load libraries from the Nix client environment.
    manager_env.pop("LD_LIBRARY_PATH", None)
    manager_env.pop("LD_PRELOAD", None)
    process = None
    previous = {}
    try:
        if not service_stopped(args, manager_env):
            parser.exit(1, f"{UNIT} is already active; stop it before launching again.\n")
        process = subprocess.Popen(service_command(args, env), env=manager_env)

        def stop(_signum, _frame):
            stop_service(args, manager_env)

        previous = {sig: signal.signal(sig, stop) for sig in (signal.SIGINT, signal.SIGTERM)}
        result = process.wait()
    finally:
        try:
            # The monitoring client can exit while the independent service is still active.
            if process is not None:
                stop_service(args, manager_env)
            shutil.rmtree(runtime)
        except Exception:
            print(
                f"Desktop shutdown is unconfirmed; runtime retained at {runtime}", file=sys.stderr
            )
            raise
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
    raise SystemExit(result)


if __name__ == "__main__":
    main()
