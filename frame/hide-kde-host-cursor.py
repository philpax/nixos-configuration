#!/usr/bin/env python3
"""Hide the host cursor on KWin's nested X11 output windows only."""

import argparse
import os
from pathlib import Path

from Xlib import X, display, error

WINDOW_TITLE = "KDE Wayland Compositor"


def is_kwin_window(window, utf8_string, net_wm_name, net_wm_pid):
    """Require both KWin's output title and a local, same-user KWin process."""
    title = window.get_full_property(net_wm_name, utf8_string)
    if title is None:
        return False
    name = title.value.decode("utf-8", errors="replace")
    if name != WINDOW_TITLE and not name.startswith(WINDOW_TITLE + " - "):
        return False
    pid = window.get_full_property(net_wm_pid, X.AnyPropertyType)
    if pid is None or len(pid.value) != 1:
        return False
    process = Path("/proc") / str(pid.value[0])
    try:
        return (
            process.stat().st_uid == os.getuid()
            and (process / "comm").read_text().strip() == "kwin_wayland"
        )
    except (OSError, ValueError):
        return False


def hide_cursor(connection, *, wait=True):
    root = connection.screen().root
    utf8_string = connection.intern_atom("UTF8_STRING")
    net_wm_name = connection.intern_atom("_NET_WM_NAME")
    net_wm_pid = connection.intern_atom("_NET_WM_PID")
    bitmap = root.create_pixmap(1, 1, 1)
    gc = bitmap.create_gc(foreground=0)
    bitmap.fill_rectangle(gc, 0, 0, 1, 1)
    cursor = bitmap.create_cursor(bitmap, (0, 0, 0), (0, 0, 0), 0, 0)
    gc.free()
    bitmap.free()
    windows = set()
    try:
        for window in root.query_tree().children:
            try:
                if is_kwin_window(window, utf8_string, net_wm_name, net_wm_pid):
                    window.change_attributes(cursor=cursor, event_mask=X.StructureNotifyMask)
                    connection.sync()
                    windows.add(window.id)
            except error.BadWindow:
                continue
        count = len(windows)
        print(f"Set a transparent host cursor on {count} nested KWin output window(s).", flush=True)
        # Keep the resource ID valid so gamescope can read the cursor through XFixes.
        while wait and windows:
            event = connection.next_event()
            if event.type == X.DestroyNotify:
                windows.discard(event.window.id)
    finally:
        cursor.free()
        connection.sync()
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--display", default=":0", help="gamescope's outer X11 display")
    args = parser.parse_args()
    connection = display.Display(args.display)
    try:
        count = hide_cursor(connection)
    finally:
        connection.close()
    if not count:
        parser.exit(1, "No nested KWin output window found; no window cursor changed.\n")


if __name__ == "__main__":
    main()
