"""Tests for sync.py — pure logic, filesystem helpers, and manifest round-trips."""

from __future__ import annotations

import json
from pathlib import Path

import sync

# ---------------------------------------------------------------------------
# parse_imported_layers — pure function, no I/O
# ---------------------------------------------------------------------------


class TestParseImportedLayers:
    def test_single_layer(self):
        content = """
        { config, pkgs, ... }:
        {
          imports = [
            ../common-all/configuration.nix
          ];
        }
        """
        assert sync.parse_imported_layers(content) == ["common-all"]

    def test_multiple_layers(self):
        content = """
        {
          imports = [
            ../common-all/configuration.nix
            ../common-desktop/configuration.nix
            ../common-dev/programs/development.nix
            ../common-dev-desktop/configuration.nix
          ];
        }
        """
        assert sync.parse_imported_layers(content) == [
            "common-all",
            "common-desktop",
            "common-dev",
            "common-dev-desktop",
        ]

    def test_deduplicates(self):
        content = """
        {
          imports = [
            ../common-all/configuration.nix
            ../common-all/programs/default.nix
            ../common-all/services/ssh.nix
          ];
        }
        """
        assert sync.parse_imported_layers(content) == ["common-all"]

    def test_ignores_non_common_imports(self):
        content = """
        {
          imports = [
            ../common-all/configuration.nix
            ./services/default.nix
            ./programs/default.nix
            <nixos-hardware/lenovo/thinkpad/t480s>
          ];
        }
        """
        assert sync.parse_imported_layers(content) == ["common-all"]

    def test_no_imports(self):
        assert sync.parse_imported_layers("imports = [];") == []

    def test_empty_string(self):
        assert sync.parse_imported_layers("") == []

    def test_real_redline_config(self):
        content = """{ config, lib, pkgs, ... }:

let
  folders = import ./folders.nix;
in {
  imports =
    [
      ../common-all/configuration.nix
      (import ./ai { inherit config pkgs; })
      (import ./services { inherit config lib pkgs; })
      (import ./programs { inherit config pkgs; })
    ];
}
"""
        assert sync.parse_imported_layers(content) == ["common-all"]

    def test_real_paprika_config(self):
        content = """{ config, pkgs, ... }:

{
  imports =
    [
      <nixos-hardware/lenovo/thinkpad/t480s>
      ../common-all/configuration.nix
      ../common-desktop/configuration.nix
      ../common-dev/programs/development.nix
      ../common-dev-desktop/configuration.nix
      ../common-dev-desktop/driftwm.nix
      (import ./services { inherit config pkgs; })
    ];
}
"""
        assert sync.parse_imported_layers(content) == [
            "common-all",
            "common-desktop",
            "common-dev",
            "common-dev-desktop",
        ]


# ---------------------------------------------------------------------------
# compute_stale_symlinks — pure function, no I/O
# ---------------------------------------------------------------------------


class TestComputeStaleSymlinks:
    def test_finds_stale(self):
        previous = {
            "/etc/nixos/common-all/config.nix": "/repo/nixos/common-all/config.nix",
            "/home/user/.config/niri/config.kdl": (
                "/repo/dotfiles/common-dev-desktop/.config/niri/config.kdl"
            ),
        }
        current = [
            (
                Path("/etc/nixos/common-all/config.nix"),
                Path("/repo/nixos/common-all/config.nix"),
            ),
        ]
        stale = sync.compute_stale_symlinks(previous, current)
        assert "/home/user/.config/niri/config.kdl" in stale
        assert "/etc/nixos/common-all/config.nix" not in stale

    def test_no_stale_when_all_present(self):
        previous = {
            "/etc/nixos/common-all/config.nix": "/repo/nixos/common-all/config.nix",
        }
        current = [
            (
                Path("/etc/nixos/common-all/config.nix"),
                Path("/repo/nixos/common-all/config.nix"),
            ),
        ]
        assert sync.compute_stale_symlinks(previous, current) == []

    def test_empty_previous(self):
        previous: dict[str, str] = {}
        current = [
            (
                Path("/etc/nixos/common-all/config.nix"),
                Path("/repo/nixos/common-all/config.nix"),
            ),
        ]
        assert sync.compute_stale_symlinks(previous, current) == []

    def test_machine_switch_detects_stale(self):
        """Switching from paprika (all layers) to redline (common-all only)."""
        previous = {
            "/home/user/.config/niri/config.kdl": (
                "/repo/dotfiles/common-dev-desktop/.config/niri/config.kdl"
            ),
            "/home/user/.config/alacritty/alacritty.toml": (
                "/repo/dotfiles/common-dev-desktop/.config/alacritty/alacritty.toml"
            ),
            "/home/user/.config/fish/config.fish": (
                "/repo/dotfiles/common-all/.config/fish/config.fish"
            ),
        }
        current = [
            (
                Path("/home/user/.config/fish/config.fish"),
                Path("/repo/dotfiles/common-all/.config/fish/config.fish"),
            ),
        ]
        stale = sync.compute_stale_symlinks(previous, current)
        assert len(stale) == 2
        assert "/home/user/.config/niri/config.kdl" in stale
        assert "/home/user/.config/alacritty/alacritty.toml" in stale

    def test_config_dot_nix_not_stale_on_machine_switch(self):
        """configuration.nix target is in both old and new sets — not stale."""
        previous = {
            "/etc/nixos/configuration.nix": "/repo/nixos/paprika/configuration.nix",
        }
        current = [
            (Path("/etc/nixos/configuration.nix"), Path("/repo/nixos/redline/configuration.nix")),
        ]
        assert sync.compute_stale_symlinks(previous, current) == []


# ---------------------------------------------------------------------------
# split_by_target — pure function, no I/O
# ---------------------------------------------------------------------------


class TestSplitByTarget:
    def test_splits_correctly(self):
        nixos_target = Path("/etc/nixos")
        dotfiles_target = Path("/home/user")
        paths = [
            "/etc/nixos/common-all/config.nix",
            "/home/user/.config/fish/config.fish",
            "/etc/nixos/redline/configuration.nix",
            "/home/user/.gitconfig",
        ]
        nixos, dotfiles = sync.split_by_target(paths, nixos_target, dotfiles_target)
        assert "/etc/nixos/common-all/config.nix" in nixos
        assert "/etc/nixos/redline/configuration.nix" in nixos
        assert "/home/user/.config/fish/config.fish" in dotfiles
        assert "/home/user/.gitconfig" in dotfiles

    def test_empty_input(self):
        nixos, dotfiles = sync.split_by_target([], Path("/etc/nixos"), Path("/home/user"))
        assert nixos == []
        assert dotfiles == []

    def test_path_outside_both_targets(self):
        nixos, dotfiles = sync.split_by_target(
            ["/opt/random/path"], Path("/etc/nixos"), Path("/home/user")
        )
        assert nixos == []
        assert dotfiles == ["/opt/random/path"]


# ---------------------------------------------------------------------------
# build_symlink_list — filesystem-reading, testable with tmp_path
# ---------------------------------------------------------------------------


class TestBuildSymlinkList:
    def test_filters_by_allowed_layers(self, tmp_path):
        source = tmp_path / "source"
        (source / "common-all" / "config").mkdir(parents=True)
        (source / "common-all" / "config" / "app.nix").write_text("# app")
        (source / "common-desktop" / "config").mkdir(parents=True)
        (source / "common-desktop" / "config" / "gui.nix").write_text("# gui")
        (source / "my-machine").mkdir()
        (source / "my-machine" / "machine.nix").write_text("# machine")

        target = tmp_path / "target"
        symlinks = sync.build_symlink_list(
            source,
            target,
            "my-machine",
            allowed_layers=["common-all"],
            strip_layer_prefix=False,
        )

        targets = {t for t, s in symlinks}
        assert target / "common-all" / "config" / "app.nix" in targets
        assert target / "my-machine" / "machine.nix" in targets
        assert target / "common-desktop" / "config" / "gui.nix" not in targets

    def test_strip_layer_prefix(self, tmp_path):
        source = tmp_path / "dotfiles"
        (source / "common-all" / ".config" / "fish").mkdir(parents=True)
        (source / "common-all" / ".config" / "fish" / "config.fish").write_text("# fish")
        (source / "common-all" / ".gitconfig").write_text("# git")

        target = tmp_path / "home"
        symlinks = sync.build_symlink_list(
            source,
            target,
            "my-machine",
            allowed_layers=["common-all"],
            strip_layer_prefix=True,
        )

        targets = {str(t) for t, s in symlinks}
        assert str(target / ".config" / "fish" / "config.fish") in targets
        assert str(target / ".gitconfig") in targets
        assert not any("common-all" in str(t) for t, s in symlinks)

    def test_no_strip_preserves_full_path(self, tmp_path):
        source = tmp_path / "nixos"
        (source / "common-all").mkdir(parents=True)
        (source / "common-all" / "configuration.nix").write_text("# config")

        target = tmp_path / "target"
        symlinks = sync.build_symlink_list(
            source,
            target,
            "my-machine",
            allowed_layers=["common-all"],
            strip_layer_prefix=False,
        )

        targets = {str(t) for t, s in symlinks}
        assert str(target / "common-all" / "configuration.nix") in targets

    def test_empty_source(self, tmp_path):
        source = tmp_path / "empty"
        source.mkdir()
        symlinks = sync.build_symlink_list(
            source,
            tmp_path / "target",
            "my-machine",
            allowed_layers=["common-all"],
        )
        assert symlinks == []

    def test_missing_source_raises(self, tmp_path):
        import pytest

        with pytest.raises(FileNotFoundError):
            sync.build_symlink_list(
                tmp_path / "nonexistent",
                tmp_path / "target",
                "machine",
                allowed_layers=[],
            )

    def test_skips_symlinks_in_source(self, tmp_path):
        source = tmp_path / "source"
        (source / "common-all").mkdir(parents=True)
        real_file = source / "common-all" / "real.nix"
        real_file.write_text("# real")
        link_file = source / "common-all" / "link.nix"
        link_file.symlink_to(real_file)

        symlinks = sync.build_symlink_list(
            source,
            tmp_path / "target",
            "machine",
            allowed_layers=["common-all"],
        )
        sources = {str(s) for t, s in symlinks}
        assert str(real_file) in sources
        assert str(link_file) not in sources

    def test_file_directly_under_layer_dir(self, tmp_path):
        """File with no subdirectory after the layer name (e.g. .gitconfig)."""
        source = tmp_path / "dotfiles"
        (source / "common-all").mkdir(parents=True)
        (source / "common-all" / ".gitconfig").write_text("# git")

        symlinks = sync.build_symlink_list(
            source,
            tmp_path / "home",
            "machine",
            allowed_layers=["common-all"],
            strip_layer_prefix=True,
        )
        assert len(symlinks) == 1
        assert symlinks[0][0] == tmp_path / "home" / ".gitconfig"

    def test_multiple_allowed_layers(self, tmp_path):
        source = tmp_path / "source"
        (source / "common-all").mkdir(parents=True)
        (source / "common-all" / "a.nix").write_text("a")
        (source / "common-desktop").mkdir(parents=True)
        (source / "common-desktop" / "b.nix").write_text("b")
        (source / "common-dev").mkdir(parents=True)
        (source / "common-dev" / "c.nix").write_text("c")

        symlinks = sync.build_symlink_list(
            source,
            tmp_path / "target",
            "machine",
            allowed_layers=["common-all", "common-desktop"],
        )
        targets = {t.name for t, s in symlinks}
        assert "a.nix" in targets
        assert "b.nix" in targets
        assert "c.nix" not in targets


# ---------------------------------------------------------------------------
# find_conflicts — filesystem-reading
# ---------------------------------------------------------------------------


class TestFindConflicts:
    def test_finds_non_symlink_files(self, tmp_path):
        existing = tmp_path / "existing.txt"
        existing.write_text("content")
        symlinks = [(existing, Path("/source/existing.txt"))]
        assert existing in sync.find_conflicts(symlinks)

    def test_no_conflict_for_symlinks(self, tmp_path):
        link = tmp_path / "link.txt"
        target = tmp_path / "target.txt"
        target.write_text("content")
        link.symlink_to(target)
        symlinks = [(link, Path("/source/link.txt"))]
        assert sync.find_conflicts(symlinks) == []

    def test_no_conflict_for_missing(self, tmp_path):
        symlinks = [(tmp_path / "nonexistent.txt", Path("/source/nonexistent.txt"))]
        assert sync.find_conflicts(symlinks) == []


# ---------------------------------------------------------------------------
# Manifest read/write round-trip
# ---------------------------------------------------------------------------


class TestManifest:
    def test_round_trip(self, tmp_path):
        state_file = tmp_path / ".sync-state.json"
        symlinks = [
            (Path("/etc/nixos/config.nix"), Path("/repo/nixos/config.nix")),
            (Path("/home/user/.gitconfig"), Path("/repo/dotfiles/common-all/.gitconfig")),
        ]
        sync.write_manifest("redline", symlinks, state_file)
        result = sync.read_manifest(state_file)
        assert result is not None
        assert result["/etc/nixos/config.nix"] == "/repo/nixos/config.nix"
        assert result["/home/user/.gitconfig"] == "/repo/dotfiles/common-all/.gitconfig"

    def test_read_missing_manifest(self, tmp_path):
        assert sync.read_manifest(tmp_path / ".sync-state.json") is None

    def test_manifest_includes_machine_and_timestamp(self, tmp_path):
        state_file = tmp_path / ".sync-state.json"
        sync.write_manifest("paprika", [], state_file)
        state = json.loads(state_file.read_text())
        assert state["machine"] == "paprika"
        assert "timestamp" in state
        assert "+" in state["timestamp"]  # timezone-aware


# ---------------------------------------------------------------------------
# cleanup_empty_dirs — filesystem side-effect
# ---------------------------------------------------------------------------


class TestCleanupEmptyDirs:
    def test_removes_empty_parents(self, tmp_path):
        deep = tmp_path / "a" / "b" / "c"
        deep.mkdir(parents=True)
        file = deep / "file.txt"
        file.write_text("content")
        file.unlink()

        sync.cleanup_empty_dirs(deep / "file.txt", tmp_path)

        assert not (tmp_path / "a" / "b" / "c").exists()
        assert not (tmp_path / "a" / "b").exists()
        assert not (tmp_path / "a").exists()
        assert tmp_path.exists()

    def test_stops_at_non_empty(self, tmp_path):
        keep = tmp_path / "keep"
        keep.mkdir()
        (keep / "file.txt").write_text("content")
        empty = keep / "empty"
        empty.mkdir()
        file = empty / "removed.txt"
        file.write_text("content")
        file.unlink()

        sync.cleanup_empty_dirs(file, tmp_path)

        assert not empty.exists()
        assert keep.exists()

    def test_stops_at_boundary(self, tmp_path):
        deep = tmp_path / "a" / "b"
        deep.mkdir(parents=True)

        sync.cleanup_empty_dirs(deep / "file.txt", tmp_path)

        assert not (tmp_path / "a" / "b").exists()
        assert not (tmp_path / "a").exists()
        assert tmp_path.exists()


# ---------------------------------------------------------------------------
# is_common_dir — pure function
# ---------------------------------------------------------------------------


class TestIsCommonDir:
    def test_common_all(self):
        assert sync.is_common_dir("common-all") is True

    def test_common_dev_desktop(self):
        assert sync.is_common_dir("common-dev-desktop") is True

    def test_non_common(self):
        assert sync.is_common_dir("redline") is False

    def test_bare_common_no_hyphen(self):
        assert sync.is_common_dir("common") is False


# ---------------------------------------------------------------------------
# Integration: build_symlink_list with real repo structure
# ---------------------------------------------------------------------------


class TestRepoIntegration:
    """Smoke tests against the real repo to catch structural regressions."""

    def test_redline_only_gets_common_all_dotfiles(self):
        """redline imports only common-all — must not get common-dev-desktop dotfiles."""
        config = sync.NIXOS_SOURCE / "redline" / "configuration.nix"
        layers = sync.get_imported_layers(config)
        assert layers == ["common-all"]

        dotfiles = sync.build_symlink_list(
            sync.DOTFILES_SOURCE,
            sync.DOTFILES_TARGET,
            "redline",
            allowed_layers=layers,
            strip_layer_prefix=True,
        )
        targets = {str(t) for t, s in dotfiles}
        # common-all dotfiles should be present
        assert any("fish/config.fish" in t for t in targets)
        assert any(".gitconfig" in t for t in targets)
        # common-dev-desktop dotfiles should NOT be present
        assert not any("niri/config.kdl" in t for t in targets)
        assert not any("alacritty" in t for t in targets)
        assert not any("quickshell" in t for t in targets)

    def test_paprika_gets_all_layers(self):
        """paprika imports all four layers — should get common-dev-desktop dotfiles."""
        config = sync.NIXOS_SOURCE / "paprika" / "configuration.nix"
        layers = sync.get_imported_layers(config)
        assert "common-all" in layers
        assert "common-desktop" in layers
        assert "common-dev" in layers
        assert "common-dev-desktop" in layers

        dotfiles = sync.build_symlink_list(
            sync.DOTFILES_SOURCE,
            sync.DOTFILES_TARGET,
            "paprika",
            allowed_layers=layers,
            strip_layer_prefix=True,
        )
        targets = {str(t) for t, s in dotfiles}
        assert any("niri/config.kdl" in t for t in targets)
        assert any("alacritty" in t for t in targets)

    def test_all_machines_parse_successfully(self):
        """Every machine directory should have a parseable configuration.nix."""
        for entry in sorted(sync.NIXOS_SOURCE.iterdir()):
            if not entry.is_dir() or entry.name.startswith("common"):
                continue
            config = entry / "configuration.nix"
            assert config.is_file(), f"{entry.name} has no configuration.nix"
            layers = sync.get_imported_layers(config)
            assert len(layers) > 0, f"{entry.name} has no common-* imports"
