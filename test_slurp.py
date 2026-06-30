"""Tests for the slurp script — pure logic and the transactional move."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

import slurp

# ---------------------------------------------------------------------------
# Pure functions
# ---------------------------------------------------------------------------


class TestRelativePlacement:
    def test_under_home(self):
        home = Path("/home/u")
        rel, under = slurp.relative_placement(home / ".config/nvim", home, Path("/tmp"))
        assert rel == Path(".config/nvim")
        assert under is True

    def test_under_cwd_not_home(self):
        home = Path("/home/u")
        cwd = Path("/srv/work")
        rel, under = slurp.relative_placement(cwd / "thing", home, cwd)
        assert rel == Path("thing")
        assert under is False

    def test_outside_everything_uses_name(self):
        rel, under = slurp.relative_placement(Path("/etc/foo/bar"), Path("/home/u"), Path("/srv"))
        assert rel == Path("bar")
        assert under is False


class TestSymlinkTargetFor:
    def test_relative_when_under_home(self):
        dest = Path("/home/u/cfg/dotfiles/common-all/.config/nvim")
        link = Path("/home/u/.config/nvim")
        target = slurp.symlink_target_for(dest, link, under_home=True)
        assert not os.path.isabs(target)
        assert (link.parent / target).resolve() == dest.resolve()

    def test_absolute_when_outside_home(self):
        dest = Path("/repo/dotfiles/x/thing")
        link = Path("/srv/thing")
        assert slurp.symlink_target_for(dest, link, under_home=False) == str(dest)


class TestShortenPath:
    def test_home_becomes_tilde(self):
        assert slurp.shorten_path("/home/u/.bashrc", Path("/home/u")) == "~/.bashrc"

    def test_outside_home_unchanged(self):
        assert slurp.shorten_path("/etc/x", Path("/home/u")) == "/etc/x"


class TestResolveInput:
    def test_expands_tilde(self, monkeypatch):
        monkeypatch.setenv("HOME", "/home/u")
        assert slurp.resolve_input("~/x", Path("/home/u"), Path("/tmp")) == Path("/home/u/x")

    def test_relative_against_cwd(self):
        assert slurp.resolve_input("a/b", Path("/home/u"), Path("/work")) == Path("/work/a/b")

    def test_normalizes(self):
        assert slurp.resolve_input("/a/./b/../c", Path("/h"), Path("/w")) == Path("/a/c")


class TestPointsAt:
    def test_relative_symlink(self, tmp_path):
        dest = tmp_path / "dest"
        dest.write_text("x")
        link = tmp_path / "link"
        link.symlink_to(os.path.relpath(dest, link.parent))
        assert slurp.points_at(link, dest) is True

    def test_non_symlink(self, tmp_path):
        f = tmp_path / "f"
        f.write_text("x")
        assert slurp.points_at(f, f) is False

    def test_wrong_target(self, tmp_path):
        other = tmp_path / "other"
        other.write_text("x")
        link = tmp_path / "link"
        link.symlink_to(other)
        assert slurp.points_at(link, tmp_path / "dest") is False


# ---------------------------------------------------------------------------
# Transactional moves
# ---------------------------------------------------------------------------


class TestPerformSlurp:
    def test_file(self, tmp_path):
        src = tmp_path / "src"
        src.write_text("hello")
        dest = tmp_path / "dots" / "src"
        slurp.perform_slurp(src, dest, str(dest))
        assert dest.read_text() == "hello"
        assert src.is_symlink()
        assert src.read_text() == "hello"

    def test_directory(self, tmp_path):
        src = tmp_path / "dir"
        (src / "sub").mkdir(parents=True)
        (src / "sub" / "f").write_text("x")
        dest = tmp_path / "dots" / "dir"
        slurp.perform_slurp(src, dest, str(dest))
        assert (dest / "sub" / "f").read_text() == "x"
        assert src.is_symlink()
        assert (src / "sub" / "f").read_text() == "x"

    def test_rollback_when_symlink_fails(self, tmp_path, monkeypatch):
        src = tmp_path / "src"
        src.write_text("data")
        dest = tmp_path / "dots" / "src"

        def boom(*a, **k):
            raise OSError("nope")

        monkeypatch.setattr(slurp.os, "symlink", boom)
        with pytest.raises(OSError):
            slurp.perform_slurp(src, dest, str(dest))
        # Original restored, dotfiles copy gone.
        assert src.read_text() == "data"
        assert not src.is_symlink()
        assert not dest.exists()


class TestOverwriteSlurp:
    def test_replaces_existing(self, tmp_path):
        src = tmp_path / "src"
        src.write_text("new")
        dest = tmp_path / "dots" / "src"
        dest.parent.mkdir(parents=True)
        dest.write_text("old")
        slurp.overwrite_slurp(src, dest, str(dest))
        assert dest.read_text() == "new"
        assert src.read_text() == "new"
        # No backup left behind.
        assert list(dest.parent.glob("*.slurp-bak*")) == []

    def test_restores_backup_on_failure(self, tmp_path, monkeypatch):
        src = tmp_path / "src"
        src.write_text("new")
        dest = tmp_path / "dots" / "src"
        dest.parent.mkdir(parents=True)
        dest.write_text("old")

        def boom(*a, **k):
            raise OSError("nope")

        monkeypatch.setattr(slurp.os, "symlink", boom)
        with pytest.raises(OSError):
            slurp.overwrite_slurp(src, dest, str(dest))
        # Old dotfiles copy restored, source untouched, no stray backup.
        assert dest.read_text() == "old"
        assert src.read_text() == "new"
        assert list(dest.parent.glob("*.slurp-bak*")) == []


class TestRelinkOnly:
    def test_discards_source(self, tmp_path):
        src = tmp_path / "src"
        src.write_text("source")
        dest = tmp_path / "dots" / "src"
        dest.parent.mkdir(parents=True)
        dest.write_text("kept")
        slurp.relink_only(src, dest, str(dest))
        assert src.is_symlink()
        assert src.read_text() == "kept"
        assert dest.read_text() == "kept"


class TestShowDiff:
    def test_reports_differences(self, tmp_path, capsys):
        existing = tmp_path / "old"
        existing.write_text("alpha\nbeta\n")
        incoming = tmp_path / "new"
        incoming.write_text("alpha\ngamma\n")
        slurp.show_diff(existing, incoming)
        out = capsys.readouterr().out
        assert "beta" in out
        assert "gamma" in out

    def test_identical_files(self, tmp_path, capsys):
        existing = tmp_path / "old"
        existing.write_text("same\n")
        incoming = tmp_path / "new"
        incoming.write_text("same\n")
        slurp.show_diff(existing, incoming)
        assert "identical" in capsys.readouterr().out


# ---------------------------------------------------------------------------
# slurp_item — end to end with a non-interactive stdin
# ---------------------------------------------------------------------------


class TestSlurpItem:
    def _run(self, path, target_dir, home, cwd, force=False, dry_run=False):
        return slurp.slurp_item(str(path), target_dir, home, cwd, force=force, dry_run=dry_run)

    def test_basic_move(self, tmp_path):
        home = tmp_path / "home"
        (home / ".config").mkdir(parents=True)
        item = home / ".config" / "app"
        item.write_text("cfg")
        target = tmp_path / "dots" / "common-all"
        ok = self._run(item, target, home, tmp_path)
        assert ok is True
        dest = target / ".config" / "app"
        assert dest.read_text() == "cfg"
        assert item.is_symlink()

    def test_missing_path_errors(self, tmp_path):
        home = tmp_path / "home"
        home.mkdir()
        target = tmp_path / "dots" / "t"
        assert self._run(home / "nope", target, home, tmp_path) is False

    def test_idempotent_already_linked(self, tmp_path, capsys):
        home = tmp_path / "home"
        (home / ".config").mkdir(parents=True)
        item = home / ".config" / "app"
        item.write_text("cfg")
        target = tmp_path / "dots" / "common-all"
        assert self._run(item, target, home, tmp_path) is True
        # Second run is a clean no-op skip.
        assert self._run(item, target, home, tmp_path) is True
        assert "already symlinked" in capsys.readouterr().out

    def test_conflict_non_tty_without_force_fails(self, tmp_path, monkeypatch):
        home = tmp_path / "home"
        (home / ".config").mkdir(parents=True)
        item = home / ".config" / "app"
        item.write_text("cfg")
        target = tmp_path / "dots" / "common-all"
        (target / ".config").mkdir(parents=True)
        (target / ".config" / "app").write_text("existing")
        monkeypatch.setattr(slurp.sys.stdin, "isatty", lambda: False)
        assert self._run(item, target, home, tmp_path) is False
        # Source left in place.
        assert item.read_text() == "cfg"

    def test_dry_run_changes_nothing(self, tmp_path):
        home = tmp_path / "home"
        (home / ".config").mkdir(parents=True)
        item = home / ".config" / "app"
        item.write_text("cfg")
        target = tmp_path / "dots" / "common-all"
        assert self._run(item, target, home, tmp_path, dry_run=True) is True
        assert item.read_text() == "cfg"
        assert not item.is_symlink()
        assert not (target / ".config" / "app").exists()
