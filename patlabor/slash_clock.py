#!/usr/bin/env python3
"""BCD clock on the 35-zone Slash Lighting strip of the ROG Zephyrus G14 GU405.

The strip hangs off the ITE 8910 keyboard controller (USB 0b05:19b6) and takes
128-byte HID feature reports with ID 0x5D. In custom mode every frame is one
report with a brightness byte (0-255) per zone, zone 0 at the top of the
diagonal. The packets are the ones G-Helper's SlashDevice sends; asusctl does
not know this board, so this talks to the hidraw node directly.

Layout, top to bottom:

    zones  1-9   hours as two BCD digits, bit 1 at the top, a dim zone between
    zones 10-11  gap
    zones 12-20  minutes, likewise
    zone  21     gap
    zones 22-35  seconds: dim zones fill from the top over the minute while a
                 bright dot bounces in the empty space below, coming to rest on
                 the first empty zone each second. The last empty zone fades up
                 to the fill level as the minute runs out.

Usage (needs write access to the hidraw node):
  slash_clock.py clock      run the clock until interrupted
  slash_clock.py firmware   hand the strip back to its built-in animation
  slash_clock.py off        disable the strip
"""

from __future__ import annotations

import fcntl
import glob
import math
import os
import signal
import sys
import time
from datetime import datetime

ZONES = 35
SECONDS_ZONES = 14
FRAME_INTERVAL = 0.04

ON = 255
DIM = 6  # unlit bit in a digit: just enough to show the digit's extent
FILL = 76  # elapsed seconds
TRAVEL_TIME = 0.9  # seconds the dot spends in flight each second


def bcd_digit(d: int) -> list[int]:
    """4 bits, bit 1 first, as zone levels."""
    return [ON if (d >> i) & 1 else DIM for i in range(4)]


def bcd_pair(value: int) -> list[int]:
    """Tens and units digits with a dark zone between them: 9 zones."""
    return bcd_digit(value // 10) + [0] + bcd_digit(value % 10)


def seconds_region(second: int, subsecond: float) -> list[int]:
    width = SECONDS_ZONES
    filled = second * width // 60  # never reaches `width`
    cells = [FILL if i < filled else 0 for i in range(width)]
    runway = width - 1 - filled  # zones the dot can travel over
    if runway == 0:
        # Last empty zone: no dot; it fades up to the fill level as the minute runs out.
        fade_start = filled * 60 / width
        cells[filled] = round(FILL * (second + subsecond - fade_start) / (60 - fade_start))
        return cells
    u = min(subsecond / TRAVEL_TIME, 1.0)
    ease = (1 - math.cos(math.pi * u)) / 2
    x = filled + runway * (1 - abs(2 * ease - 1))  # out to the bottom wall and back
    lo = math.floor(x)
    frac = x - lo
    cells[lo] = max(cells[lo], round(ON * (1 - frac)))
    if frac:
        cells[lo + 1] = max(cells[lo + 1], round(ON * frac))
    return cells


def frame_for(now: datetime) -> list[int]:
    frame = bcd_pair(now.hour) + [0, 0] + bcd_pair(now.minute) + [0]
    frame += seconds_region(now.second, now.microsecond / 1e6)
    assert len(frame) == ZONES
    return frame


class Slash:
    """The strip's HID protocol, as reverse-engineered by G-Helper (SlashDevice.cs).

    Every packet is a 128-byte feature report: report ID, a command byte, then
    the command's arguments. Settings live in "records" selected by a region
    byte: the firmware-animation record and the custom-frame record.
    """

    REPORT_ID = 0x5D
    PACKET_LEN = 128
    HIDIOCSFEATURE = (3 << 30) | (PACKET_LEN << 16) | (ord("H") << 8) | 0x06

    CMD_SELECT = 0xD2  # select a record for the writes that follow
    CMD_WRITE = 0xD3  # write record fields, or push frame data
    CMD_COMMIT = 0xD4  # persist the selected record
    CMD_RESET = 0xD7  # sent before switching animation
    CMD_FLAG = 0xD8  # set a device flag on (0x00) or off (0x80)

    RECORD_ANIMATION = 0xAB
    RECORD_CUSTOM = 0xAC
    FLAG_ENABLED = 0x02
    MODE_BOUNCE = 0x10  # the default firmware animation

    @staticmethod
    def find() -> str | None:
        for path in glob.glob("/sys/class/hidraw/hidraw*"):
            with open(os.path.join(path, "device", "uevent")) as f:
                if "HID_ID=0003:00000B05:000019B6" in f.read():
                    return "/dev/" + os.path.basename(path)
        return None

    def __init__(self, path: str):
        self.fd = os.open(path, os.O_RDWR)

    def close(self) -> None:
        os.close(self.fd)

    def send(self, *cmd: int) -> None:
        buf = bytearray(self.PACKET_LEN)
        buf[0] = self.REPORT_ID
        buf[1 : 1 + len(cmd)] = bytes(cmd)
        fcntl.ioctl(self.fd, self.HIDIOCSFEATURE, buf)

    # Building blocks.

    def select(self, record: int) -> None:
        self.send(self.CMD_SELECT, 0x02, 0x01, 0x08, record)

    def write(self, record: int, *fields: int) -> None:
        self.send(self.CMD_WRITE, 0x03, 0x01, 0x08, record, *fields)

    def commit(self, record: int) -> None:
        self.send(self.CMD_COMMIT, 0x00, 0x00, 0x01, record)

    def set_flag(self, flag: int, on: bool) -> None:
        self.send(self.CMD_FLAG, flag, 0x00, 0x01, 0x00 if on else 0x80)

    # Operations.

    def enable(self, on: bool) -> None:
        self.set_flag(self.FLAG_ENABLED, on)

    def custom_begin(self) -> None:
        """Switch to custom mode. Once, then frame() as often as you like."""
        self.select(self.RECORD_CUSTOM)
        self.write(
            self.RECORD_CUSTOM, 0xFF, 0xFF, 0x01, 0x05, 0xFF, 0xFF
        )  # G-Helper's static preset
        self.commit(self.RECORD_CUSTOM)

    def frame(self, zones: list[int]) -> None:
        self.send(self.CMD_WRITE, 0x00, 0x00, ZONES, *zones)

    def firmware(self, mode: int = MODE_BOUNCE, brightness: int = 0xFF, interval: int = 0) -> None:
        """Back to a built-in animation, saved so it survives a reboot."""
        self.send(self.CMD_RESET, 0x00, 0x00, 0x01, self.RECORD_CUSTOM)
        self.select(self.RECORD_ANIMATION)
        # Key/value pairs; key 1 is the animation, the rest are G-Helper's defaults.
        self.send(
            self.CMD_WRITE, 0x04, 0x00, 0x0C, 1, mode, 2, 0x42, 3, 0x13, 4, 0x11, 5, 0x12, 6, 0x13
        )
        enabled = 0x01
        self.write(self.RECORD_ANIMATION, 0xFF, 0x01, enabled, 0x06, brightness, 0xFF, interval)
        self.commit(self.RECORD_ANIMATION)


def run_clock() -> None:
    """Drive the clock forever. The device comes and goes across sleep, so reopen on error."""
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    dev = None
    try:
        while True:
            try:
                if dev is None:
                    path = Slash.find()
                    if path is None:
                        time.sleep(1)
                        continue
                    dev = Slash(path)
                    dev.enable(True)
                    dev.custom_begin()
                dev.frame(frame_for(datetime.now()))
                time.sleep(FRAME_INTERVAL - time.time() % FRAME_INTERVAL)
            except OSError as e:
                print(f"device error, reopening: {e}", file=sys.stderr, flush=True)
                if dev is not None:
                    dev.close()
                    dev = None
                time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        if dev is not None:
            dev.frame([0] * ZONES)
            dev.close()


def main(argv: list[str]) -> None:
    cmd = argv[0] if argv else None
    if cmd == "clock":
        run_clock()
        return
    if cmd not in ("firmware", "off"):
        sys.exit(__doc__)
    path = Slash.find()
    if path is None:
        sys.exit("no 0b05:19b6 hidraw device found")
    dev = Slash(path)
    if cmd == "firmware":
        dev.enable(True)
        dev.firmware()
    else:
        dev.enable(False)


if __name__ == "__main__":
    main(sys.argv[1:])
