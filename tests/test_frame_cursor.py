"""Window selection for Frame's nested KDE host cursor."""

import importlib.util
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import Mock, patch

import pytest


@pytest.fixture
def cursor_module():
    xlib = ModuleType("Xlib")
    xlib.X = SimpleNamespace(AnyPropertyType=0, StructureNotifyMask=131072, DestroyNotify=17)
    xlib.display = SimpleNamespace()
    xlib.error = SimpleNamespace(BadWindow=type("BadWindow", (Exception,), {}))
    path = Path(__file__).resolve().parents[1] / "frame" / "hide-kde-host-cursor.py"
    spec = importlib.util.spec_from_file_location("frame_cursor", path)
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, {"Xlib": xlib}):
        spec.loader.exec_module(module)
    return module


def window(title=b"KDE Wayland Compositor - Press right control key to grab input", pid=123):
    properties = {
        "name": SimpleNamespace(value=title) if title is not None else None,
        "pid": SimpleNamespace(value=[pid]) if pid is not None else None,
    }
    result = Mock()
    result.get_full_property.side_effect = lambda atom, _kind: properties[atom]
    return result


@pytest.mark.parametrize(
    ("title", "pid", "owner", "comm", "expected"),
    [
        (b"KDE Wayland Compositor", 123, 1000, "kwin_wayland\n", True),
        (b"KDE Wayland Compositor - Input grabbed", 123, 1000, "kwin_wayland\n", True),
        (b"Steam", 123, 1000, "kwin_wayland\n", False),
        (b"KDE Wayland Compositor fake", 123, 1000, "kwin_wayland\n", False),
        (None, 123, 1000, "kwin_wayland\n", False),
        (b"KDE Wayland Compositor", None, 1000, "kwin_wayland\n", False),
        (b"KDE Wayland Compositor", 123, 1001, "kwin_wayland\n", False),
        (b"KDE Wayland Compositor", 123, 1000, "plasmashell\n", False),
    ],
)
def test_only_selects_current_users_kwin(cursor_module, title, pid, owner, comm, expected):
    with (
        patch.object(cursor_module.os, "getuid", return_value=1000),
        patch.object(Path, "stat", return_value=SimpleNamespace(st_uid=owner)),
        patch.object(Path, "read_text", return_value=comm),
    ):
        assert cursor_module.is_kwin_window(window(title, pid), "utf8", "name", "pid") == expected


def test_exited_process_is_ignored(cursor_module):
    with patch.object(Path, "stat", side_effect=FileNotFoundError):
        assert not cursor_module.is_kwin_window(window(), "utf8", "name", "pid")


def test_changes_only_matching_windows_and_releases_resources(cursor_module):
    connection = Mock()
    root = connection.screen.return_value.root
    kde, steam, closed = Mock(), Mock(), Mock()
    root.query_tree.return_value.children = [kde, steam, closed]
    kde.id = 42
    connection.next_event.return_value = SimpleNamespace(type=17, window=kde)
    with patch.object(
        cursor_module,
        "is_kwin_window",
        side_effect=[True, False, cursor_module.error.BadWindow()],
    ):
        assert cursor_module.hide_cursor(connection) == 1
    bitmap = root.create_pixmap.return_value
    root.create_pixmap.assert_called_once_with(1, 1, 1)
    bitmap.fill_rectangle.assert_called_once_with(bitmap.create_gc.return_value, 0, 0, 1, 1)
    cursor = bitmap.create_cursor.return_value
    kde.change_attributes.assert_called_once_with(cursor=cursor, event_mask=131072)
    connection.next_event.assert_called_once()
    steam.change_attributes.assert_not_called()
    closed.change_attributes.assert_not_called()
    root.change_attributes.assert_not_called()
    bitmap.create_gc.return_value.free.assert_called_once()
    bitmap.free.assert_called_once()
    cursor.free.assert_called_once()
