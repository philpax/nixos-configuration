from __future__ import annotations

import os
import pwd
from pathlib import Path
from typing import TYPE_CHECKING

from .paths import FrameError
from .syncthing import _systemd_arg

if TYPE_CHECKING:
    from .activation import Operation


SERVICE = "frame-mt2-driver.service"
DRIVER = Path("frame/magic-trackpad-2-linux-userspace/mt2_driver.py")


def driver_path(frame) -> Path:
    return Path(frame.repo).absolute() / DRIVER


def service_operations(frame) -> list[Operation]:
    from .activation import Operation

    home = Path(frame.home).absolute()
    start = " ".join(_systemd_arg(arg) for arg in ["/usr/bin/python3", driver_path(frame)])
    content = (
        "[Unit]\nDescription=Magic Trackpad 2 userspace multitouch driver\n\n"
        "[Service]\nType=exec\n"
        f"ExecStart={start}\n"
        "Restart=on-failure\nRestartSec=5\n\n"
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
        raise FrameError("Trackpad service activation requires the account's actual home directory")
    if not driver_path(frame).is_file():
        raise FrameError(
            f"{driver_path(frame)} is missing; run `git submodule update --init` in the checkout"
        )
    frame.run(["/usr/bin/systemctl", "--user", "daemon-reload"])
    frame.run(["/usr/bin/systemctl", "--user", "restart", SERVICE])
