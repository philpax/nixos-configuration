"""Tests for sync.py — pure logic, filesystem helpers, and manifest round-trips."""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

import sync


def _cogs_checked_out() -> bool:
    """True if the steel-cogs submodules are populated (have their cog.scm).

    A fresh clone without `git submodule update --init` leaves them as empty
    directories, in which case the repo-integration tests below can't run.
    """
    if not sync.STEEL_COGS_SOURCE.is_dir():
        return False
    return any((d / "cog.scm").is_file() for d in sync.STEEL_COGS_SOURCE.iterdir() if d.is_dir())


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


class TestGetImportedLayersTransitive:
    """get_imported_layers scans all .nix files in the machine dir, not just
    configuration.nix — so transitive imports (e.g. redline's
    programs/development.nix importing ../../common-dev/...) are detected."""

    def test_finds_transitive_import_in_subdir(self, tmp_path):
        """A layer imported only by a nested .nix file is detected."""
        machine = tmp_path / "my-machine"
        machine.mkdir()
        (machine / "configuration.nix").write_text(
            "{ imports = [ ../common-all/configuration.nix ]; }"
        )
        (machine / "programs").mkdir()
        (machine / "programs" / "development.nix").write_text(
            "{ imports = [ ../../common-dev/programs/development.nix ]; }"
        )

        layers = sync.get_imported_layers(machine / "configuration.nix")
        assert layers == ["common-all", "common-dev"]

    def test_deduplicates_across_files(self, tmp_path):
        """Same layer imported by multiple files is listed once."""
        machine = tmp_path / "my-machine"
        machine.mkdir()
        (machine / "configuration.nix").write_text(
            "{ imports = [ ../common-all/configuration.nix ]; }"
        )
        (machine / "services").mkdir()
        (machine / "services" / "default.nix").write_text(
            "{ imports = [ ../../common-all/services/ssh.nix ]; }"
        )

        layers = sync.get_imported_layers(machine / "configuration.nix")
        assert layers == ["common-all"]

    def test_no_machine_dir_returns_empty(self, tmp_path):
        """Missing configuration.nix returns empty list."""
        assert sync.get_imported_layers(tmp_path / "nonexistent.nix") == []


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

    def test_dotfiles_flow_does_not_walk_agents_skills(self, tmp_path):
        """The dotfiles walk must exclude the per-layer .agents skill sources:
        build_layered_skill_symlinks creates whole-directory symlinks at
        ~/.agents/skills/<name>, and file links at ~/.agents/skills/<name>/…
        would collide with those directory symlinks."""
        source = tmp_path / "dotfiles"
        (source / "common-dev" / ".agents" / "skills" / "committing").mkdir(parents=True)
        (source / "common-dev" / ".agents" / "skills" / "committing" / "SKILL.md").write_text(
            "# committing"
        )
        marker_path = (
            source / "common-dev" / ".agents" / "skills" / "committing" / ".work-compatible"
        )
        marker_path.write_text("marker")
        # A real (non-skill) dotfile in the same layer must still be picked up
        (source / "common-dev" / ".gitconfig").write_text("# git")
        # .claude stays walked — CLAUDE.md is a desired dotfile link
        (source / "common-all" / ".claude").mkdir(parents=True)
        (source / "common-all" / ".claude" / "CLAUDE.md").write_text("@CONTRIBUTING.md")

        home = tmp_path / "home"
        symlinks = sync.build_symlink_list(
            source, home, "redline", ["common-dev", "common-all"], strip_layer_prefix=True
        )
        targets = {str(t) for t, _ in symlinks}
        # Nothing under ~/.agents/skills/ from the dotfiles walk
        assert not any(t.startswith(str(home / ".agents")) for t in targets)
        # .claude dotfile link preserved
        assert str(home / ".claude" / "CLAUDE.md") in targets
        # Non-skill dotfile still walked
        assert str(home / ".gitconfig") in targets


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
# group_by_layer — pure function
# ---------------------------------------------------------------------------


class TestGroupByLayer:
    def test_groups_correctly(self):
        source_dir = Path("/repo/nixos")
        symlinks = [
            (Path("/etc/nixos/common-all/a.nix"), source_dir / "common-all" / "a.nix"),
            (Path("/etc/nixos/common-all/b.nix"), source_dir / "common-all" / "b.nix"),
            (Path("/etc/nixos/redline/c.nix"), source_dir / "redline" / "c.nix"),
        ]
        groups = sync.group_by_layer(symlinks, source_dir)
        assert "common-all" in groups
        assert "redline" in groups
        assert len(groups["common-all"]) == 2
        assert len(groups["redline"]) == 1

    def test_common_sorted_before_machine(self):
        source_dir = Path("/repo")
        symlinks = [
            (Path("/t/z/a.nix"), source_dir / "zebra" / "a.nix"),
            (Path("/t/common-all/b.nix"), source_dir / "common-all" / "b.nix"),
            (Path("/t/common-desktop/c.nix"), source_dir / "common-desktop" / "c.nix"),
        ]
        groups = sync.group_by_layer(symlinks, source_dir)
        keys = list(groups.keys())
        assert keys[0] == "common-all"
        assert keys[1] == "common-desktop"
        assert keys[2] == "zebra"

    def test_empty_input(self):
        assert sync.group_by_layer([], Path("/repo")) == {}


# ---------------------------------------------------------------------------
# shorten_path — pure function
# ---------------------------------------------------------------------------


class TestShortenPath:
    def test_home_prefix(self):
        home = Path("/home/user")
        assert sync.shorten_path("/home/user/.config/fish", home) == "~/.config/fish"

    def test_non_home_path(self):
        home = Path("/home/user")
        assert sync.shorten_path("/etc/nixos/config.nix", home) == "/etc/nixos/config.nix"

    def test_path_object(self):
        home = Path("/home/user")
        assert sync.shorten_path(Path("/home/user/.gitconfig"), home) == "~/.gitconfig"

    def test_default_home(self):
        result = sync.shorten_path(str(Path.home() / ".gitconfig"))
        assert result == "~/.gitconfig"


# ---------------------------------------------------------------------------
# Integration: build_symlink_list with real repo structure
# ---------------------------------------------------------------------------


class TestRepoIntegration:
    """Smoke tests against the real repo to catch structural regressions."""

    def test_redline_gets_common_all_and_dev_dotfiles(self):
        """redline imports common-all directly and common-dev transitively
        (via programs/development.nix) — but not common-desktop or common-dev-desktop."""
        config = sync.NIXOS_SOURCE / "redline" / "configuration.nix"
        layers = sync.get_imported_layers(config)
        assert layers == ["common-all", "common-dev"]

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
        # common-dev dotfiles should be present (transitive import)
        assert any("fish/functions/vrchat-transcode.fish" in t for t in targets)
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


# ---------------------------------------------------------------------------
# _init_state — generates a manifest for old (all common-*) sync behavior
# ---------------------------------------------------------------------------


class TestInitState:
    def test_includes_all_common_layers(self, tmp_path, monkeypatch):
        """Init state should include all common-* dirs, not just imported ones."""
        source = tmp_path / "nixos"
        for layer in ["common-all", "common-desktop", "common-dev", "common-dev-desktop"]:
            (source / layer).mkdir(parents=True)
            (source / layer / "config.nix").write_text("# config")
        (source / "redline").mkdir()
        (source / "redline" / "configuration.nix").write_text(
            "{ imports = [ ../common-all/configuration.nix ]; }"
        )

        dotfiles = tmp_path / "dotfiles"
        (dotfiles / "common-all").mkdir(parents=True)
        (dotfiles / "common-all" / ".gitconfig").write_text("# git")
        (dotfiles / "common-dev-desktop").mkdir(parents=True)
        (dotfiles / "common-dev-desktop" / ".config" / "niri").mkdir(parents=True)
        (dotfiles / "common-dev-desktop" / ".config" / "niri" / "config.kdl").write_text("# niri")

        state_file = tmp_path / ".sync-state.json"

        monkeypatch.setattr(sync, "NIXOS_SOURCE", source)
        monkeypatch.setattr(sync, "NIXOS_TARGET", tmp_path / "etc-nixos")
        monkeypatch.setattr(sync, "DOTFILES_SOURCE", dotfiles)
        monkeypatch.setattr(sync, "DOTFILES_TARGET", tmp_path / "home")
        monkeypatch.setattr(sync, "STATE_FILE", state_file)

        sync._init_state("redline")

        manifest = sync.read_manifest(state_file)
        assert manifest is not None

        # redline only imports common-all, but init-state includes all layers
        targets = set(manifest.keys())
        assert str(tmp_path / "etc-nixos" / "common-all" / "config.nix") in targets
        assert str(tmp_path / "etc-nixos" / "common-desktop" / "config.nix") in targets
        assert str(tmp_path / "etc-nixos" / "common-dev-desktop" / "config.nix") in targets
        assert str(tmp_path / "home" / ".gitconfig") in targets
        assert str(tmp_path / "home" / ".config" / "niri" / "config.kdl") in targets

        # Subsequent layer-aware sync should detect the extra layers as stale
        imported = sync.parse_imported_layers(
            (source / "redline" / "configuration.nix").read_text()
        )
        new_symlinks = sync.build_symlink_list(
            dotfiles, tmp_path / "home", "redline", imported, strip_layer_prefix=True
        )
        stale = sync.compute_stale_symlinks(manifest, new_symlinks)
        # niri config should be stale (common-dev-desktop not imported by redline)
        assert any("niri" in s for s in stale)
        # git config should NOT be stale (common-all is imported)
        assert not any("gitconfig" in s for s in stale)

    def test_init_state_includes_agents_tree_in_manifest(self, tmp_path, monkeypatch):
        """Init-state manifest must reflect the new layout: per-skill symlinks
        under ~/.agents/skills/, the ~/.claude/skills -> ~/.agents/skills dir
        symlink, and work skills sourced from the shared dev skills tree."""
        source = tmp_path / "nixos"
        (source / "common-all").mkdir(parents=True)
        (source / "common-all" / "config.nix").write_text("# config")
        (source / "common-dev").mkdir(parents=True)
        (source / "common-dev" / "config.nix").write_text("# config")
        (source / "redline").mkdir()
        (source / "redline" / "configuration.nix").write_text(
            "{ imports = [ ../common-all/configuration.nix ]; }"
        )

        dotfiles = tmp_path / "dotfiles"
        (dotfiles / "common-dev").mkdir(parents=True)
        (dotfiles / "common-dev" / ".agents" / "skills" / "committing").mkdir(parents=True)
        (dotfiles / "common-dev" / ".agents" / "skills" / "committing" / "SKILL.md").write_text(
            "# committing"
        )
        (dotfiles / "common-dev" / ".agents" / "skills" / "github-issue").mkdir(parents=True)
        (dotfiles / "common-dev" / ".agents" / "skills" / "github-issue" / "SKILL.md").write_text(
            "# github-issue"
        )

        state_file = tmp_path / ".sync-state.json"
        home = tmp_path / "home"

        monkeypatch.setattr(sync, "NIXOS_SOURCE", source)
        monkeypatch.setattr(sync, "NIXOS_TARGET", tmp_path / "etc-nixos")
        monkeypatch.setattr(sync, "DOTFILES_SOURCE", dotfiles)
        monkeypatch.setattr(sync, "DOTFILES_TARGET", home)
        monkeypatch.setattr(sync, "STATE_FILE", state_file)
        monkeypatch.setattr(sync, "AGENTS_SKILLS_TARGET", home / ".agents" / "skills")
        monkeypatch.setattr(sync, "CC_SKILLS_TARGET", home / ".claude" / "skills")

        sync._init_state("redline")

        manifest = sync.read_manifest(state_file)
        assert manifest is not None
        targets = set(manifest.keys())
        # New-layout personal targets (per-skill leaves under ~/.agents/skills)
        assert str(home / ".agents" / "skills" / "committing") in targets
        assert str(home / ".agents" / "skills" / "github-issue") in targets
        # The ~/.claude/skills -> ~/.agents/skills directory symlink
        assert str(home / ".claude" / "skills") in targets
        # No legacy ~/.claude/skills/<name> leaves in the new-layout manifest
        assert str(home / ".claude" / "skills" / "committing") not in targets


# ---------------------------------------------------------------------------
# build_skill_symlinks — filesystem-reading, testable with tmp_path
# ---------------------------------------------------------------------------


class TestBuildSkillSymlinks:
    def test_builds_symlinks_for_skill_dirs(self, tmp_path):
        source = tmp_path / "skills"
        (source / "committing").mkdir(parents=True)
        (source / "committing" / "SKILL.md").write_text("# committing")
        (source / "github-issue").mkdir(parents=True)
        (source / "github-issue" / "SKILL.md").write_text("# github-issue")

        target = tmp_path / "target"
        symlinks = sync.build_skill_symlinks(source, target)

        targets = {t.name for t, s in symlinks}
        assert targets == {"committing", "github-issue"}
        for t, s in symlinks:
            assert t.parent == target
            assert s == source / t.name

    def test_skips_dirs_without_skill_md(self, tmp_path):
        source = tmp_path / "skills"
        (source / "has-skill").mkdir(parents=True)
        (source / "has-skill" / "SKILL.md").write_text("# skill")
        (source / "no-skill").mkdir(parents=True)
        (source / "no-skill" / "other.md").write_text("# other")

        symlinks = sync.build_skill_symlinks(source, tmp_path / "target")
        targets = {t.name for t, s in symlinks}
        assert targets == {"has-skill"}

    def test_skips_files_in_source_dir(self, tmp_path):
        source = tmp_path / "skills"
        source.mkdir(parents=True)
        (source / "README.md").write_text("# readme")
        (source / "committing").mkdir()
        (source / "committing" / "SKILL.md").write_text("# skill")

        symlinks = sync.build_skill_symlinks(source, tmp_path / "target")
        targets = {t.name for t, s in symlinks}
        assert targets == {"committing"}

    def test_missing_source_returns_empty(self, tmp_path):
        symlinks = sync.build_skill_symlinks(tmp_path / "nonexistent", tmp_path / "target")
        assert symlinks == []

    def test_empty_source_returns_empty(self, tmp_path):
        source = tmp_path / "skills"
        source.mkdir()
        symlinks = sync.build_skill_symlinks(source, tmp_path / "target")
        assert symlinks == []

    def test_results_sorted(self, tmp_path):
        source = tmp_path / "skills"
        for name in ["zebra", "alpha", "mango"]:
            (source / name).mkdir(parents=True)
            (source / name / "SKILL.md").write_text("# skill")

        symlinks = sync.build_skill_symlinks(source, tmp_path / "target")
        names = [t.name for t, s in symlinks]
        assert names == ["alpha", "mango", "zebra"]


# ---------------------------------------------------------------------------
# build_work_skill_symlinks — filesystem-reading, testable with tmp_path
# ---------------------------------------------------------------------------


class TestBuildWorkSkillSymlinks:
    def _make_skill(self, source, name, work_compatible=False):
        skill = source / name
        skill.mkdir(parents=True)
        (skill / "SKILL.md").write_text(f"# {name}")
        if work_compatible:
            (skill / sync.WORK_COMPATIBLE_MARKER).write_text("work-compatible")

    def test_builds_symlinks_only_for_marked_skills(self, tmp_path):
        source = tmp_path / "skills"
        self._make_skill(source, "alpha", work_compatible=True)
        self._make_skill(source, "beta")
        self._make_skill(source, "gamma", work_compatible=True)

        target = tmp_path / "target"
        symlinks = sync.build_work_skill_symlinks(source, target)

        targets = {t.name for t, s in symlinks}
        assert targets == {"alpha", "gamma"}
        for t, s in symlinks:
            assert t.parent == target
            assert s == source / t.name

    def test_skips_dirs_without_skill_md(self, tmp_path):
        source = tmp_path / "skills"
        self._make_skill(source, "alpha", work_compatible=True)
        (source / "no-skill").mkdir()
        (source / "no-skill" / sync.WORK_COMPATIBLE_MARKER).write_text("work-compatible")

        symlinks = sync.build_work_skill_symlinks(source, tmp_path / "target")
        targets = {t.name for t, s in symlinks}
        assert targets == {"alpha"}

    def test_skips_files_in_source_dir(self, tmp_path):
        source = tmp_path / "skills"
        source.mkdir(parents=True)
        (source / sync.WORK_COMPATIBLE_MARKER).write_text("work-compatible")

        symlinks = sync.build_work_skill_symlinks(source, tmp_path / "target")
        assert symlinks == []

    def test_missing_source_returns_empty(self, tmp_path):
        symlinks = sync.build_work_skill_symlinks(tmp_path / "nonexistent", tmp_path / "target")
        assert symlinks == []

    def test_empty_source_returns_empty(self, tmp_path):
        source = tmp_path / "skills"
        source.mkdir()
        symlinks = sync.build_work_skill_symlinks(source, tmp_path / "target")
        assert symlinks == []

    def test_results_sorted(self, tmp_path):
        source = tmp_path / "skills"
        for name in ["zebra", "alpha", "mango"]:
            self._make_skill(source, name, work_compatible=True)

        symlinks = sync.build_work_skill_symlinks(source, tmp_path / "target")
        names = [t.name for t, s in symlinks]
        assert names == ["alpha", "mango", "zebra"]


# ---------------------------------------------------------------------------
# build_layered_skill_symlinks — filesystem-reading, testable with tmp_path
# ---------------------------------------------------------------------------


class TestBuildLayeredSkillSymlinks:
    def _make_skill(self, dotfiles, layer, name):
        skill = dotfiles / layer / ".agents" / "skills" / name
        skill.mkdir(parents=True)
        (skill / "SKILL.md").write_text(f"# {name}")

    def test_collects_across_layers(self, tmp_path):
        dotfiles = tmp_path / "dotfiles"
        self._make_skill(dotfiles, "common-dev", "committing")
        self._make_skill(dotfiles, "redline", "llama-cpp-model-tuning")
        target = tmp_path / "target"

        symlinks = sync.build_layered_skill_symlinks(dotfiles, target, "redline", ["common-dev"])
        targets = {t.name for t, s in symlinks}
        assert targets == {"committing", "llama-cpp-model-tuning"}

    def test_only_included_layers(self, tmp_path):
        dotfiles = tmp_path / "dotfiles"
        self._make_skill(dotfiles, "common-dev", "committing")
        self._make_skill(dotfiles, "redline", "llama-cpp-model-tuning")
        target = tmp_path / "target"

        # jinroh doesn't include the redline or common-dev layers, so it shouldn't get the skills.
        symlinks = sync.build_layered_skill_symlinks(dotfiles, target, "jinroh", [])
        targets = {t.name for t, s in symlinks}
        assert targets == set()

    def test_machine_layer_overrides_common(self, tmp_path):
        dotfiles = tmp_path / "dotfiles"
        self._make_skill(dotfiles, "common-dev", "shared")
        self._make_skill(dotfiles, "redline", "shared")
        target = tmp_path / "target"

        symlinks = sync.build_layered_skill_symlinks(dotfiles, target, "redline", ["common-dev"])
        assert len(symlinks) == 1
        target_path, source = symlinks[0]
        assert target_path.name == "shared"
        assert "redline" in source.parts and "common-dev" not in source.parts

    def test_no_skills_returns_empty(self, tmp_path):
        dotfiles = tmp_path / "dotfiles"
        (dotfiles / "common-dev").mkdir(parents=True)
        symlinks = sync.build_layered_skill_symlinks(
            dotfiles, tmp_path / "target", "redline", ["common-dev"]
        )
        assert symlinks == []


# ---------------------------------------------------------------------------
# copy mode (AGENT_SKILLS_COPY_MODE) — working around Polytoken skipping
# skill directory symlinks
# ---------------------------------------------------------------------------


class TestCopyMode:
    def _make_source_skill(self, root, name):
        skill = root / name
        (skill / "SKILL.md").parent.mkdir(parents=True, exist_ok=True)
        (skill / "SKILL.md").write_text(f"---\ndescription: {name}\n---\n")
        return skill

    def test_layered_builder_returns_same_pairs_in_copy_mode(self, tmp_path):
        dotfiles = tmp_path / "dotfiles"
        self._make_source_skill(dotfiles / "common-dev" / ".agents" / "skills", "alpha")
        target = tmp_path / "target"
        symlinks = sync.build_layered_skill_symlinks(
            dotfiles, target, "redline", ["common-dev"], copy_mode=True
        )
        assert symlinks == [
            (target / "alpha", dotfiles / "common-dev" / ".agents" / "skills" / "alpha")
        ]

    def test_copy_skill_tree_makes_real_dir_with_all_files(self, tmp_path):
        source = tmp_path / "src" / "alpha"
        (source / "SKILL.md").parent.mkdir(parents=True)
        (source / "SKILL.md").write_text("---\ndescription: alpha\n---\n")
        (source / "companion.py").write_text("print('x')")
        target = tmp_path / "agents" / "alpha"

        sync.copy_skill_tree(source, target)

        assert target.is_dir() and not target.is_symlink()
        assert (target / "SKILL.md").read_text() == "---\ndescription: alpha\n---\n"
        assert (target / "companion.py").read_text() == "print('x')"

    def test_apply_sync_changes_copies_in_copy_mode(self, tmp_path):
        agents = tmp_path / "agents"
        source = tmp_path / "src" / "alpha"
        (source / "SKILL.md").parent.mkdir(parents=True)
        (source / "SKILL.md").write_text("---\ndescription: alpha\n---\n")

        created = sync.apply_sync_changes(
            nixos_symlinks=[],
            dotfiles_symlinks=[],
            skill_symlinks=[(agents / "alpha", source)],
            cc_personal_symlink=[],
            work_skill_symlinks=[],
            cog_symlinks=[],
            stale=[],
            force=False,
            nixos_target=tmp_path / "etc-nixos",
            dotfiles_target=tmp_path / "home",
            cc_skills_target=tmp_path / ".claude" / "skills",
            agents_skills_target=agents,
            work_skills_target=tmp_path / ".claude-work" / "skills",
            copy_mode=True,
            machine=None,
        )
        assert created == [(agents / "alpha", source)]
        assert (agents / "alpha").is_dir() and not (agents / "alpha").is_symlink()
        assert (agents / "alpha" / "SKILL.md").read_text() == "---\ndescription: alpha\n---\n"

    def test_copy_mode_expiry_raises(self, tmp_path, monkeypatch):
        agents = tmp_path / "agents"
        source = tmp_path / "src" / "alpha"
        (source / "SKILL.md").parent.mkdir(parents=True)
        (source / "SKILL.md").write_text("---\ndescription: alpha\n---\n")

        # Force the timebomb to have tripped
        monkeypatch.setattr(sync, "AGENT_SKILLS_COPY_MODE_EXPIRY", sync.date(2020, 1, 1))
        with pytest.raises(SystemExit):
            sync.apply_sync_changes(
                nixos_symlinks=[],
                dotfiles_symlinks=[],
                skill_symlinks=[(agents / "alpha", source)],
                cc_personal_symlink=[],
                work_skill_symlinks=[],
                cog_symlinks=[],
                stale=[],
                force=False,
                nixos_target=tmp_path / "etc-nixos",
                dotfiles_target=tmp_path / "home",
                cc_skills_target=tmp_path / ".claude" / "skills",
                agents_skills_target=agents,
                work_skills_target=tmp_path / ".claude-work" / "skills",
                copy_mode=True,
                machine=None,
            )

    def test_find_conflicts_exempts_agents_tree(self, tmp_path):
        agents = tmp_path / "agents"
        (agents / "alpha").mkdir(parents=True)
        conflicts = sync.find_conflicts(
            [(agents / "alpha", tmp_path / "src" / "alpha")],
            exempt_targets=[agents],
        )
        assert conflicts == []

    def test_find_conflicts_reports_without_exemption(self, tmp_path):
        agents = tmp_path / "agents"
        (agents / "alpha").mkdir(parents=True)
        conflicts = sync.find_conflicts(
            [(agents / "alpha", tmp_path / "src" / "alpha")],
            exempt_targets=None,
        )
        assert conflicts == [agents / "alpha"]


# ---------------------------------------------------------------------------
# build_cc_personal_wiring — pure function, no I/O
# ---------------------------------------------------------------------------


class TestCcPersonalWiring:
    def test_returns_single_dir_symlink(self):
        """CC personal wiring is exactly one directory symlink:
        ~/.claude/skills -> ~/.agents/skills."""
        agents_target = Path.home() / ".agents" / "skills"
        wiring = sync.build_cc_personal_wiring(agents_target)
        assert wiring == [(Path.home() / ".claude" / "skills", agents_target)]

    def test_created_link_points_at_agents_skills(self, tmp_path):
        """Creating the wiring symlink via create_or_update_symlinks produces
        a link whose readlink resolves to the agents-skills target."""
        agents_target = tmp_path / ".agents" / "skills"
        agents_target.mkdir(parents=True)
        cc_target = tmp_path / ".claude" / "skills"

        wiring = [(cc_target, agents_target)]
        created = sync.create_or_update_symlinks(wiring, use_sudo=False, force=False)
        assert created == wiring
        assert cc_target.is_symlink()
        assert os.readlink(cc_target) == str(agents_target)

    def test_included_in_main_flow_created_set(self):
        """The dir symlink must be part of the combined new-symlink set that
        main() passes to apply_sync_changes (and hence the created set)."""
        agents_target = Path.home() / ".agents" / "skills"
        wiring = sync.build_cc_personal_wiring(agents_target)
        all_new = [
            (Path.home() / ".claude" / "skills" / "committing", Path("/src") / "committing"),
        ]
        all_new += wiring
        assert (Path.home() / ".claude" / "skills", agents_target) in all_new


# ---------------------------------------------------------------------------
# classify_stale — pure function, no I/O
# ---------------------------------------------------------------------------


class TestClassifyStale:
    def test_empty_inputs_all_empty(self):
        cc, work, remaining = sync.classify_stale([], [], [])
        assert cc == [] and work == [] and remaining == []

    def test_cc_dir_symlink_target_lands_in_cc_bucket(self):
        cc_skills = Path.home() / ".claude" / "skills"
        agents_skills = Path.home() / ".agents" / "skills"
        stale = [
            str(cc_skills),
            str(agents_skills),
            str(cc_skills / "committing"),
            str(agents_skills / "committing"),
        ]
        cc, work, remaining = sync.classify_stale(
            stale, cc_targets=[cc_skills, agents_skills], work_targets=[]
        )
        # The dir symlink target and old leaves land in cc_stale — never remaining
        assert set(cc) == set(stale)
        assert work == [] and remaining == []

    def test_work_leaves_land_in_work_bucket(self):
        work_target = Path.home() / ".claude-work" / "skills"
        stale = [str(work_target / "committing"), str(work_target / "github-issue")]
        cc, work, remaining = sync.classify_stale(stale, cc_targets=[], work_targets=[work_target])
        assert cc == []
        assert set(work) == set(stale)
        assert remaining == []

    def test_dotfile_entries_stay_in_remaining(self):
        home = Path.home() / ".config" / "foo"
        stale = [str(home / "bar")]
        cc, work, remaining = sync.classify_stale(
            stale,
            cc_targets=[Path.home() / ".claude" / "skills"],
            work_targets=[Path.home() / ".claude-work" / "skills"],
        )
        assert cc == [] and work == []
        assert remaining == stale

    def test_mixed_classification(self):
        cc_skills = Path.home() / ".claude" / "skills"
        agents_skills = Path.home() / ".agents" / "skills"
        work_target = Path.home() / ".claude-work" / "skills"
        other = Path.home() / ".config" / "other"
        stale = [
            str(agents_skills / "committing"),
            str(cc_skills / "committing"),
            str(work_target / "committing"),
            str(other / "file"),
        ]
        cc, work, remaining = sync.classify_stale(
            stale,
            cc_targets=[cc_skills, agents_skills],
            work_targets=[work_target],
        )
        assert set(cc) == {str(agents_skills / "committing"), str(cc_skills / "committing")}
        assert work == [str(work_target / "committing")]
        assert remaining == [str(other / "file")]


# ---------------------------------------------------------------------------
# build_skill_symlinks — integration with real repo
# ---------------------------------------------------------------------------


class TestSkillSymlinksRepoIntegration:
    """Smoke tests against the real repo's shared skills directory."""

    def test_finds_real_skills(self):
        symlinks = sync.build_skill_symlinks(sync.SHARED_SKILLS_SOURCE, sync.AGENTS_SKILLS_TARGET)
        names = {t.name for t, s in symlinks}
        assert "committing" in names
        assert "github-issue" in names

    def test_targets_under_agents_skills_dir(self):
        symlinks = sync.build_skill_symlinks(sync.SHARED_SKILLS_SOURCE, sync.AGENTS_SKILLS_TARGET)
        for target, _ in symlinks:
            assert target.parent == sync.AGENTS_SKILLS_TARGET

    def test_sources_point_to_shared_skills(self):
        symlinks = sync.build_skill_symlinks(sync.SHARED_SKILLS_SOURCE, sync.AGENTS_SKILLS_TARGET)
        names = {t.name for t, s in symlinks}
        assert names == {
            "committing",
            "contributing-init",
            "contributing-update",
            "github-issue",
            "github-issue-simple",
            "plain-technical-prose",
        }
        for _, source in symlinks:
            assert source.parent == sync.SHARED_SKILLS_SOURCE
            assert (source / "SKILL.md").is_file()


# ---------------------------------------------------------------------------
# build_work_skill_symlinks — integration with real repo
# ---------------------------------------------------------------------------


class TestWorkSkillSymlinksRepoIntegration:
    """Smoke tests for the work-account Claude Code sync — skills present in
    the real repo that carry the .work-compatible marker, synced into
    ~/.claude-work/skills/."""

    def test_finds_marked_skills(self):
        symlinks = sync.build_work_skill_symlinks(
            sync.SHARED_SKILLS_SOURCE, sync.CLAUDE_WORK_SKILLS_TARGET
        )
        marked = {t.name for t, s in symlinks}
        # Pinned: these four skills carry the .work-compatible marker in the
        # shared dev skills tree. Pinning guards against an accidentally-empty
        # or accidentally-different work set.
        assert marked == {
            "committing",
            "github-issue",
            "github-issue-simple",
            "plain-technical-prose",
        }

    def test_targets_under_claude_work_dir(self):
        symlinks = sync.build_work_skill_symlinks(
            sync.SHARED_SKILLS_SOURCE, sync.CLAUDE_WORK_SKILLS_TARGET
        )
        for target, _ in symlinks:
            assert target.parent == sync.CLAUDE_WORK_SKILLS_TARGET

    def test_sources_have_marker_and_skill_md(self):
        symlinks = sync.build_work_skill_symlinks(
            sync.SHARED_SKILLS_SOURCE, sync.CLAUDE_WORK_SKILLS_TARGET
        )
        for _, source in symlinks:
            assert (source / "SKILL.md").is_file()
            assert (source / sync.WORK_COMPATIBLE_MARKER).is_file()

    def test_marked_skills_are_subset_of_cc_skills(self):
        # Personal skills are built layer-aware; redline imports common-dev
        # (via programs/development.nix), so it gets the shared dev skills.
        cc_symlinks = sync.build_layered_skill_symlinks(
            sync.DOTFILES_SOURCE, sync.AGENTS_SKILLS_TARGET, "redline", ["common-dev"]
        )
        cc_names = {t.name for t, s in cc_symlinks}
        work_symlinks = sync.build_work_skill_symlinks(
            sync.SHARED_SKILLS_SOURCE, sync.CLAUDE_WORK_SKILLS_TARGET
        )
        work_names = {t.name for t, s in work_symlinks}
        assert work_names <= cc_names


# ---------------------------------------------------------------------------
# build_cog_symlinks — filesystem-reading, testable with tmp_path
# ---------------------------------------------------------------------------


class TestBuildCogSymlinks:
    def test_builds_symlinks_for_cog_dirs(self, tmp_path):
        source = tmp_path / "steel-cogs"
        (source / "forest").mkdir(parents=True)
        (source / "forest" / "cog.scm").write_text("(define package-name 'forest)")
        (source / "notify").mkdir(parents=True)
        (source / "notify" / "cog.scm").write_text("(define package-name 'notify)")

        target = tmp_path / "target"
        symlinks = sync.build_cog_symlinks(source, target)

        targets = {t.name for t, s in symlinks}
        assert targets == {"forest", "notify"}
        for t, s in symlinks:
            assert t.parent == target
            assert s == source / t.name

    def test_skips_dirs_without_cog_scm(self, tmp_path):
        source = tmp_path / "steel-cogs"
        (source / "has-cog").mkdir(parents=True)
        (source / "has-cog" / "cog.scm").write_text("(define package-name 'has-cog)")
        # An un-checked-out submodule is an empty directory: no cog.scm.
        (source / "empty-submodule").mkdir(parents=True)

        symlinks = sync.build_cog_symlinks(source, tmp_path / "target")
        targets = {t.name for t, s in symlinks}
        assert targets == {"has-cog"}

    def test_skips_files_in_source_dir(self, tmp_path):
        source = tmp_path / "steel-cogs"
        source.mkdir(parents=True)
        (source / "README.md").write_text("# readme")
        (source / "forest").mkdir()
        (source / "forest" / "cog.scm").write_text("(define package-name 'forest)")

        symlinks = sync.build_cog_symlinks(source, tmp_path / "target")
        targets = {t.name for t, s in symlinks}
        assert targets == {"forest"}

    def test_missing_source_returns_empty(self, tmp_path):
        symlinks = sync.build_cog_symlinks(tmp_path / "nonexistent", tmp_path / "target")
        assert symlinks == []

    def test_empty_source_returns_empty(self, tmp_path):
        source = tmp_path / "steel-cogs"
        source.mkdir()
        symlinks = sync.build_cog_symlinks(source, tmp_path / "target")
        assert symlinks == []

    def test_results_sorted(self, tmp_path):
        source = tmp_path / "steel-cogs"
        for name in ["zebra", "alpha", "mango"]:
            (source / name).mkdir(parents=True)
            (source / name / "cog.scm").write_text(f"(define package-name '{name})")

        symlinks = sync.build_cog_symlinks(source, tmp_path / "target")
        names = [t.name for t, s in symlinks]
        assert names == ["alpha", "mango", "zebra"]


# ---------------------------------------------------------------------------
# build_cog_symlinks — integration with real repo
# ---------------------------------------------------------------------------


@pytest.mark.skipif(
    not _cogs_checked_out(),
    reason="steel-cogs submodules not checked out (run `git submodule update --init`)",
)
class TestCogSymlinksRepoIntegration:
    """Smoke tests against the real repo's steel-cogs submodules."""

    def test_finds_real_cogs(self):
        symlinks = sync.build_cog_symlinks(sync.STEEL_COGS_SOURCE, sync.STEEL_COGS_TARGET)
        names = {t.name for t, s in symlinks}
        # forest.hx's dependencies resolve by cog package-name, so the dirs are
        # named forest/notify/glyph regardless of repo name.
        assert names == {"forest", "notify", "glyph"}

    def test_targets_under_steel_cogs_dir(self):
        symlinks = sync.build_cog_symlinks(sync.STEEL_COGS_SOURCE, sync.STEEL_COGS_TARGET)
        for target, _ in symlinks:
            assert target.parent == sync.STEEL_COGS_TARGET

    def test_sources_have_cog_scm(self):
        symlinks = sync.build_cog_symlinks(sync.STEEL_COGS_SOURCE, sync.STEEL_COGS_TARGET)
        for _, source in symlinks:
            assert source.parent == sync.STEEL_COGS_SOURCE
            assert (source / "cog.scm").is_file()


# ---------------------------------------------------------------------------
# apply_sync_changes — stale-removal ordering (regression guard for AC.4)
# ---------------------------------------------------------------------------


class TestFirstSyncStaleRemovalOrdering:
    """First sync after the skills-layout change must remove the old
    ~/.claude/skills/<name> leaf symlinks BEFORE creating the
    ~/.claude/skills -> ~/.agents/skills directory symlink, so the fresh
    ~/.agents/skills/<name> targets are never unlinked through the dir link."""

    def test_first_sync_removes_old_cc_leaves_without_touching_agents_tree(self, tmp_path):
        home = tmp_path / "home"
        agents_skills = home / ".agents" / "skills"
        claude_skills = home / ".claude" / "skills"
        work_skills = home / ".claude-work" / "skills"

        # Pre-seed the OLD layout: ~/.claude/skills is a REAL directory holding
        # per-skill leaf symlinks, and ~/.claude-work/skills holds work leaves.
        claude_skills.mkdir(parents=True)
        old_src = tmp_path / "old-source" / "skills"
        (old_src / "committing").mkdir(parents=True)
        (old_src / "committing" / "SKILL.md").write_text("# committing")
        (old_src / "github-issue").mkdir(parents=True)
        (old_src / "github-issue" / "SKILL.md").write_text("# github-issue")
        for name in ("committing", "github-issue"):
            (claude_skills / name).symlink_to(old_src / name, target_is_directory=True)
        work_skills.mkdir(parents=True)
        (work_skills / "committing").symlink_to(old_src / "committing", target_is_directory=True)

        # The staging area for the new per-skill targets: previously-synced
        # ~/.agents/skills/<name> directory symlinks (from a partial earlier
        # run) that must survive the migration intact.
        new_agents_src = tmp_path / "new-source" / "skills"
        (new_agents_src / "committing").mkdir(parents=True)
        (new_agents_src / "committing" / "SKILL.md").write_text("# committing (new)")
        (new_agents_src / "github-issue").mkdir(parents=True)
        (new_agents_src / "github-issue" / "SKILL.md").write_text("# github-issue (new)")
        agents_skills.mkdir(parents=True)
        (agents_skills / "committing").symlink_to(
            new_agents_src / "committing", target_is_directory=True
        )
        (agents_skills / "github-issue").symlink_to(
            new_agents_src / "github-issue", target_is_directory=True
        )

        # Old manifest already holds the leaf targets, which are now stale
        # relative to the new sync-set (which uses ~/.agents/skills leaves +
        # the dir symlink instead). Per AC.4 the stale list exercises the old
        # ~/.claude/skills/<name> leaves, the ~/.claude/skills target itself,
        # and the ~/.agents/skills targets.
        stale = [
            str(claude_skills),
            str(claude_skills / "committing"),
            str(claude_skills / "github-issue"),
            str(agents_skills),
            str(agents_skills / "committing"),
            str(agents_skills / "github-issue"),
            str(work_skills / "committing"),
        ]

        # New sync-set: per-skill dir symlinks under ~/.agents/skills, the
        # ~/.claude/skills dir symlink, plus a work leaf.
        skill_symlinks = [
            (agents_skills / "committing", new_agents_src / "committing"),
            (agents_skills / "github-issue", new_agents_src / "github-issue"),
        ]
        cc_personal = [(claude_skills, agents_skills)]
        work_symlinks = [(work_skills / "committing", new_agents_src / "committing")]

        created = sync.apply_sync_changes(
            nixos_symlinks=[],  # nixos
            dotfiles_symlinks=[],  # dotfiles
            skill_symlinks=skill_symlinks,
            cc_personal_symlink=cc_personal,
            work_skill_symlinks=work_symlinks,
            cog_symlinks=[],  # cogs
            stale=stale,
            force=False,
            nixos_target=home / "etc-nixos",
            dotfiles_target=home,
            cc_skills_target=claude_skills,
            agents_skills_target=agents_skills,
            work_skills_target=work_skills,
            copy_mode=False,
        )

        # The fresh ~/.agents/skills targets survive (never unlinked through
        # the dir symlink — stale removal ran before dir-symlink creation).
        assert (agents_skills / "committing").is_symlink()
        assert (agents_skills / "github-issue").is_symlink()
        assert os.readlink(agents_skills / "committing") == str(new_agents_src / "committing")
        # ~/.claude/skills ended up as the dir symlink to ~/.agents/skills
        assert claude_skills.is_symlink()
        assert os.readlink(claude_skills) == str(agents_skills)
        # The old leaves are gone: resolution through the dir symlink lands in
        # the NEW agents tree, not the OLD source.
        assert (claude_skills / "committing").resolve() == (new_agents_src / "committing").resolve()
        assert (claude_skills / "github-issue").resolve() == (
            new_agents_src / "github-issue"
        ).resolve()
        # The work leaf is re-pointed at the new source
        assert (work_skills / "committing").is_symlink()
        assert os.readlink(work_skills / "committing") == str(new_agents_src / "committing")
        # The new skill sources' contents are intact
        assert (new_agents_src / "committing" / "SKILL.md").read_text() == "# committing (new)"
        assert (new_agents_src / "github-issue" / "SKILL.md").read_text() == "# github-issue (new)"
        # The combined created set includes the personal dir symlink
        assert (claude_skills, agents_skills) in created
