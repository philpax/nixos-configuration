"""Check window-scoped cursor hiding on a disposable X server, never the live desktop.

Run with the helper's python-xlib environment and an existing test X server:
    python3 tests/check_frame_cursor_x11.py --display :97
"""

import argparse
import os
import selectors
import subprocess
import sys
from pathlib import Path

from Xlib import X, display
from Xlib.ext import xfixes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--display", required=True)
    args = parser.parse_args()
    helper = Path(__file__).resolve().parents[1] / "frame" / "hide-kde-host-cursor.py"
    connection = display.Display(args.display)
    assert connection.has_extension("XFIXES")
    connection.xfixes_query_version()
    root = connection.screen().root
    net_wm_name = connection.intern_atom("_NET_WM_NAME")
    net_wm_pid = connection.intern_atom("_NET_WM_PID")
    utf8_string = connection.intern_atom("UTF8_STRING")
    cardinal = connection.intern_atom("CARDINAL")

    def make_window(x, title):
        window = root.create_window(x, 0, 150, 200, 0, X.CopyFromParent, X.InputOutput)
        window.change_property(net_wm_name, utf8_string, 8, title.encode())
        window.change_property(net_wm_pid, cardinal, 32, [os.getpid()])
        window.map()
        return window

    def pixels_at(window):
        window.warp_pointer(30, 30)
        connection.sync()
        image = xfixes.GetCursorImage(
            display=connection.display,
            opcode=connection.display.get_extension_major("XFIXES"),
        )
        return tuple(image.cursor_image)

    original_comm = Path("/proc/self/comm").read_text().strip()
    try:
        Path("/proc/self/comm").write_text("kwin_wayland")
        kde = make_window(0, "KDE Wayland Compositor - Input grabbed")
        sibling = make_window(160, "Unrelated application")
        connection.sync()
        sibling_before = pixels_at(sibling)
        assert any(sibling_before), "Expected a visible baseline cursor"
        process = subprocess.Popen(
            [sys.executable, str(helper), "--display", args.display],
            stdout=subprocess.PIPE,
            text=True,
        )
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                assert selector.select(timeout=5), "Helper did not become ready"
                assert "1 nested KWin" in process.stdout.readline()
            assert not any(pixels_at(kde)), "KDE host cursor is not transparent"
            assert pixels_at(sibling) == sibling_before, "Sibling cursor changed"
            kde.destroy()
            connection.sync()
            assert process.wait(timeout=5) == 0
            assert pixels_at(sibling) == sibling_before, "Sibling cursor changed after KDE exit"
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        print("PASS: transparent only over KDE; sibling cursor unchanged; helper exits with KDE")
    finally:
        Path("/proc/self/comm").write_text(original_comm)
        connection.close()


if __name__ == "__main__":
    main()
