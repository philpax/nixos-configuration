#!/usr/bin/env python3
"""Keep the gamescope cursor transparent over this nested niri process only."""

import argparse
import os
import select
import time
from pathlib import Path

from Xlib import X, display, error


def is_niri_window(window, pid, name_atom, pid_atom):
    name = window.get_full_property(name_atom, X.AnyPropertyType)
    process = window.get_full_property(pid_atom, X.AnyPropertyType)
    return (
        name is not None
        and name.value == b"niri"
        and process is not None
        and list(process.value) == [pid]
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, help="niri PID; defaults to NIRI_SOCKET's PID")
    parser.add_argument("--display", default=":0")
    args = parser.parse_args()
    if args.pid is None:
        try:
            args.pid = int(Path(os.environ["NIRI_SOCKET"]).name.rsplit(".", 2)[1])
        except (KeyError, ValueError, IndexError):
            parser.error("NIRI_SOCKET must identify the nested niri instance")
    process_path = Path("/proc") / str(args.pid)
    if (
        process_path.stat().st_uid != os.getuid()
        or (process_path / "comm").read_text().strip() != "niri"
    ):
        parser.exit(1, "Refusing to change cursors for a process other than same-user niri.\n")
    process_fd = os.pidfd_open(args.pid)
    connection = display.Display(args.display)
    root = connection.screen().root
    connection.xfixes_query_version()
    name_atom = connection.intern_atom("_NET_WM_NAME")
    pid_atom = connection.intern_atom("_NET_WM_PID")
    bitmap = root.create_pixmap(1, 1, 1)
    gc = bitmap.create_gc(foreground=0)
    bitmap.fill_rectangle(gc, 0, 0, 1, 1)
    cursor = bitmap.create_cursor(bitmap, (0, 0, 0), (0, 0, 0), 0, 0)
    gc.free()
    bitmap.free()
    try:
        # Niri's startup command can run before the host window's properties arrive.
        deadline = time.monotonic() + 15
        selected = None
        while selected is None:
            for window in root.query_tree().children:
                try:
                    if is_niri_window(window, args.pid, name_atom, pid_atom):
                        window.change_attributes(cursor=cursor, event_mask=X.StructureNotifyMask)
                        connection.sync()
                        selected = window.id
                        print(f"Hid host cursor on niri window {selected:#x}.", flush=True)
                        break
                except error.BadWindow:
                    continue
            if selected is None:
                if time.monotonic() >= deadline:
                    parser.exit(1, "No nested niri X11 window found within 15 seconds.\n")
                if select.select([process_fd], [], [], 0.1)[0]:
                    return
        connection.xfixes_select_cursor_input(root, 1)
        connection.flush()
        while True:
            while connection.pending_events():
                event = connection.next_event()
                if event.type == X.DestroyNotify and event.window.id == selected:
                    return
            # Reapplying the same cursor is a no-op; react to Winit's cursor updates.
            window.change_attributes(cursor=cursor)
            connection.sync()
            if connection.pending_events():
                continue
            ready, _, _ = select.select([connection.fileno(), process_fd], [], [])
            if process_fd in ready:
                return
    finally:
        cursor.free()
        connection.close()
        os.close(process_fd)


if __name__ == "__main__":
    main()
