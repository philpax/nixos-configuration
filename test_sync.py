"""Tests for sync.py — pure logic, filesystem helpers, and manifest round-trips."""

from __future__ import annotations

import json
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
# build_layered_skill_symlinks — filesystem-reading, testable with tmp_path
# ---------------------------------------------------------------------------


class TestBuildLayeredSkillSymlinks:
    def _make_skill(self, dotfiles, layer, name):
        skill = dotfiles / layer / ".config" / "polytoken" / "skills" / name
        skill.mkdir(parents=True)
        (skill / "SKILL.md").write_text(f"# {name}")

    def test_collects_across_layers(self, tmp_path):
        dotfiles = tmp_path / "dotfiles"
        self._make_skill(dotfiles, "common-all", "committing")
        self._make_skill(dotfiles, "redline", "llama-cpp-model-tuning")
        target = tmp_path / "target"

        symlinks = sync.build_layered_skill_symlinks(dotfiles, target, "redline", ["common-all"])
        targets = {t.name for t, s in symlinks}
        assert targets == {"committing", "llama-cpp-model-tuning"}

    def test_only_included_layers(self, tmp_path):
        dotfiles = tmp_path / "dotfiles"
        self._make_skill(dotfiles, "common-all", "committing")
        self._make_skill(dotfiles, "redline", "llama-cpp-model-tuning")
        target = tmp_path / "target"

        # jinroh doesn't include the redline layer, so it shouldn't get the skill.
        symlinks = sync.build_layered_skill_symlinks(dotfiles, target, "jinroh", ["common-all"])
        targets = {t.name for t, s in symlinks}
        assert targets == {"committing"}

    def test_machine_layer_overrides_common(self, tmp_path):
        dotfiles = tmp_path / "dotfiles"
        self._make_skill(dotfiles, "common-all", "shared")
        self._make_skill(dotfiles, "redline", "shared")
        target = tmp_path / "target"

        symlinks = sync.build_layered_skill_symlinks(dotfiles, target, "redline", ["common-all"])
        assert len(symlinks) == 1
        target_path, source = symlinks[0]
        assert target_path.name == "shared"
        assert "redline" in source.parts and "common-all" not in source.parts

    def test_no_skills_returns_empty(self, tmp_path):
        dotfiles = tmp_path / "dotfiles"
        (dotfiles / "common-all").mkdir(parents=True)
        symlinks = sync.build_layered_skill_symlinks(
            dotfiles, tmp_path / "target", "redline", ["common-all"]
        )
        assert symlinks == []


# ---------------------------------------------------------------------------
# build_skill_symlinks — integration with real repo
# ---------------------------------------------------------------------------


class TestSkillSymlinksRepoIntegration:
    """Smoke tests against the real repo's polytoken skills directory."""

    def test_finds_real_skills(self):
        symlinks = sync.build_skill_symlinks(sync.POLYTOKEN_SKILLS_SOURCE, sync.CC_SKILLS_TARGET)
        names = {t.name for t, s in symlinks}
        assert "committing" in names
        assert "github-issue" in names

    def test_targets_under_cc_skills_dir(self):
        symlinks = sync.build_skill_symlinks(sync.POLYTOKEN_SKILLS_SOURCE, sync.CC_SKILLS_TARGET)
        for target, _ in symlinks:
            assert target.parent == sync.CC_SKILLS_TARGET

    def test_sources_point_to_polytoken_skills(self):
        symlinks = sync.build_skill_symlinks(sync.POLYTOKEN_SKILLS_SOURCE, sync.CC_SKILLS_TARGET)
        for _, source in symlinks:
            assert source.parent == sync.POLYTOKEN_SKILLS_SOURCE
            assert (source / "SKILL.md").is_file()


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
