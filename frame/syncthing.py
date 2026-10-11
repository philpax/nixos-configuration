from __future__ import annotations

import argparse
import copy
import json
import os
import pwd
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import TYPE_CHECKING

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from frame.paths import FrameError, Paths
else:
    from .paths import FrameError, Paths

if TYPE_CHECKING:
    from .activation import Operation


SERVICE = "frame-syncthing.service"


def _systemd_arg(value):
    value = str(value)
    if "\0" in value:
        raise FrameError("Systemd arguments cannot contain NUL")
    value = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
        .replace("%", "%%")
        .replace("$", "$$")
    )
    return f'"{value}"'


def service_operations(frame) -> list[Operation]:
    from .activation import Operation

    home = Path(frame.home).absolute()
    state = Path(frame.state).absolute()
    wrapper = Path(getattr(getattr(frame, "paths", None), "wrapper", home / ".local/bin/frame-cli"))
    argv = [str(wrapper.absolute()), "--home", str(home), "--state-dir", str(state)]
    pre = " ".join(_systemd_arg(arg) for arg in [*argv, "syncthing", "configure"])
    start = " ".join(
        _systemd_arg(arg)
        for arg in [
            *argv,
            "enter",
            "--",
            "syncthing",
            "serve",
            "--home",
            str(home / ".local/state/frame-syncthing"),
            "--no-browser",
            "--no-restart",
            "--no-upgrade",
            "--gui-address=127.0.0.1:8384",
        ]
    )
    content = (
        "[Unit]\nDescription=Frame Syncthing\n\n"
        "[Service]\nType=exec\n"
        f"ExecStartPre={pre}\nExecStart={start}\n"
        "Restart=on-failure\nRestartSec=5\nSuccessExitStatus=3 4\n"
        "RestartForceExitStatus=3 4\n"
        "UMask=0077\nKillMode=control-group\n\n"
        "[Install]\nWantedBy=default.target\n"
    )
    unit = home / ".config/systemd/user" / SERVICE
    return [
        Operation(unit, "file", content.encode(), SERVICE),
        Operation(unit.parent / "default.target.wants" / SERVICE, "link", f"../{SERVICE}", SERVICE),
    ]


def start_service(frame) -> None:
    account_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
    if Path(frame.home).resolve() != account_home:
        raise FrameError("Syncthing service activation requires the account's actual home directory")
    frame.run(["/usr/bin/systemctl", "--user", "daemon-reload"])
    frame.run(["/usr/bin/systemctl", "--user", "restart", SERVICE])


def configure_service(frame) -> int:
    return frame.enter(
        [
            "/usr/bin/python3",
            str(Path(__file__).resolve()),
            "configure",
            str(frame.home),
            str(Path(frame.profile) / "share/frame-cli/syncthing.json"),
        ]
    )


def _safe_tree(paths, path):
    path = paths.check(path)
    if not path.exists():
        return
    info = path.lstat()
    if stat.S_ISDIR(info.st_mode):
        for child in path.iterdir():
            _safe_tree(paths, child)
    elif not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise FrameError(f"Syncthing state must contain only unlinked regular files: {path}")


def _directory(paths, path):
    path = paths.check(path)
    if path.exists() and not path.is_dir():
        raise FrameError(f"Syncthing directory is not a directory: {path}")
    return path


def _settings(settings_path):
    settings = json.loads(Path(settings_path).read_text())
    if not isinstance(settings, dict):
        raise FrameError("Syncthing settings must be an object")
    devices = settings.get("devices", {})
    folders = settings.get("folders", {})
    if not isinstance(devices, dict) or not isinstance(folders, dict):
        raise FrameError("Syncthing devices and folders must be objects")
    expected = settings.get("deviceID")
    if expected is not None and (not isinstance(expected, str) or not expected.strip()):
        raise FrameError("Syncthing deviceID must be null or a nonempty string")
    for name, device in devices.items():
        if (
            not name
            or not isinstance(device, dict)
            or not isinstance(device.get("id"), str)
            or not device["id"].strip()
        ):
            raise FrameError(f"Invalid Syncthing device: {name}")
    for name, folder in folders.items():
        if not name or name in (".", "..") or "/" in name or "\0" in name:
            raise FrameError(f"Invalid Syncthing folder name: {name}")
        if (
            not isinstance(folder, dict)
            or not isinstance(folder.get("devices"), list)
            or any(not isinstance(peer, str) or peer not in devices for peer in folder["devices"])
        ):
            raise FrameError(f"Invalid Syncthing folder membership: {name}")
    return devices, folders, expected


def _element(parent, name):
    found = parent.find(name)
    return found if found is not None else ET.SubElement(parent, name)


def _default(root, name):
    default = root.find(f"defaults/{name}")
    return copy.deepcopy(default) if default is not None else ET.Element(name)


def configure(home, settings_path) -> None:
    devices, folders, expected = _settings(settings_path)
    paths = Paths(home)
    state = paths.home / ".local/state/frame-syncthing"
    _directory(paths, state)
    _safe_tree(paths, state)
    for name in ("config.xml", "cert.pem", "key.pem", "https-cert.pem", "https-key.pem"):
        file = paths.check(state / name)
        if file.exists() and not file.is_file():
            raise FrameError(f"Syncthing identity/configuration is not a regular file: {file}")
    if (state / "cert.pem").exists() != (state / "key.pem").exists():
        raise FrameError("Syncthing certificate and key must both exist or both be absent")
    folder_paths = {name: _directory(paths, paths.home / "notes" / name) for name in folders}
    for path in folder_paths.values():
        paths.check(path / ".stfolder")
    for path in (paths.home / ".local", paths.home / ".local/state", state):
        paths.mkdir(path)
    state.chmod(0o700)
    previous_umask = os.umask(0o077)
    try:
        subprocess.run(
            ["syncthing", "generate", f"--home={state}", "--no-port-probing"], check=True
        )
    finally:
        os.umask(previous_umask)
    _safe_tree(paths, state)
    own_id = subprocess.run(
        ["syncthing", "device-id", f"--home={state}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if not own_id or (expected is not None and expected != own_id):
        raise FrameError("Syncthing certificate device ID does not match the expected deviceID")
    config_path = paths.check(state / "config.xml")
    root = ET.parse(config_path).getroot()
    if root.tag != "configuration":
        raise FrameError("Invalid Syncthing configuration XML")
    own_device = next(
        (device for device in root.findall("device") if device.get("id") == own_id), None
    )
    if own_device is None:
        raise FrameError("Syncthing configuration is missing the certificate's own device")
    for node in root.findall("device") + root.findall("folder"):
        root.remove(node)
    root.append(own_device)
    seen = {own_id}
    for name, settings in devices.items():
        device_id = settings["id"]
        if device_id in seen:
            continue
        seen.add(device_id)
        device = _default(root, "device")
        device.set("id", device_id)
        device.set("name", name)
        root.append(device)
    for name, settings in folders.items():
        folder = _default(root, "folder")
        folder.attrib.update(id=name, label=name, path=str(folder_paths[name]))
        for peer in folder.findall("device"):
            folder.remove(peer)
        for device_id in dict.fromkeys(
            [own_id, *(devices[peer]["id"] for peer in settings["devices"])]
        ):
            ET.SubElement(folder, "device", id=device_id)
        root.append(folder)
    gui = _element(root, "gui")
    gui.set("enabled", "true")
    _element(gui, "address").text = "127.0.0.1:8384"
    options = _element(root, "options")
    minimum = _element(options, "minHomeDiskFree")
    minimum.set("unit", "GB")
    minimum.text = "1"
    _element(options, "startBrowser").text = "false"
    _element(options, "autoUpgradeIntervalH").text = "0"
    if folder_paths:
        paths.mkdir(paths.home / "notes")
    for path in folder_paths.values():
        paths.mkdir(path)
    paths.atomic_bytes(
        config_path, ET.tostring(root, encoding="utf-8", xml_declaration=True), 0o600
    )


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("configure",))
    parser.add_argument("home")
    parser.add_argument("settings_path")
    args = parser.parse_args(argv)
    try:
        configure(args.home, args.settings_path)
    except (FrameError, OSError, ValueError, ET.ParseError, subprocess.CalledProcessError) as exc:
        print(f"frame-syncthing: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
