"""Verify a live nested desktop's host cursor after explicitly focusing its X11 window.

The check briefly changes gamescope focus and restores the previous active window.
Run with python-xlib and the host Xlib libraries available to Python.
"""

import argparse
import ctypes
import select
import time

from Xlib import X, display, protocol


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--window", required=True, type=lambda value: int(value, 0))
    args = parser.parse_args()
    connection = display.Display(":0")
    root = connection.screen().root
    active = connection.intern_atom("_NET_ACTIVE_WINDOW")
    previous = root.get_full_property(active, X.AnyPropertyType)

    def focus(window_id):
        event = protocol.event.ClientMessage(
            window=window_id, client_type=active, data=(32, [2, X.CurrentTime, 0, 0, 0])
        )
        root.send_event(event, event_mask=X.SubstructureRedirectMask | X.SubstructureNotifyMask)
        connection.sync()

    x11 = ctypes.CDLL("/usr/lib/libX11.so.6")
    fixes = ctypes.CDLL("/usr/lib/libXfixes.so.3")

    class Image(ctypes.Structure):
        _fields_ = [
            ("x", ctypes.c_short),
            ("y", ctypes.c_short),
            ("width", ctypes.c_ushort),
            ("height", ctypes.c_ushort),
            ("xhot", ctypes.c_ushort),
            ("yhot", ctypes.c_ushort),
            ("serial", ctypes.c_ulong),
            ("pixels", ctypes.POINTER(ctypes.c_ulong)),
            ("atom", ctypes.c_ulong),
            ("name", ctypes.c_char_p),
        ]

    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XFree.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    fixes.XFixesGetCursorImage.argtypes = [ctypes.c_void_p]
    fixes.XFixesGetCursorImage.restype = ctypes.POINTER(Image)
    inspection = x11.XOpenDisplay(b":0")
    assert inspection
    try:
        focus(args.window)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            current = root.get_full_property(active, X.AnyPropertyType)
            pointer = fixes.XFixesGetCursorImage(inspection)
            assert pointer
            image = pointer.contents
            visible = sum(bool(image.pixels[i] >> 24) for i in range(image.width * image.height))
            x11.XFree(pointer)
            if current is not None and list(current.value) == [args.window] and not visible:
                print("PASS: active nested desktop has a transparent host cursor")
                return
            select.select([], [], [], 0.05)
        raise AssertionError("Nested desktop did not become active with a transparent host cursor")
    finally:
        if previous is not None:
            focus(int(previous.value[0]))
        x11.XCloseDisplay(inspection)
        connection.close()


if __name__ == "__main__":
    main()
