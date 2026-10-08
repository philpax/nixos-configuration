"""Sync CLI selection, shared planning/application, and compatibility exports."""

from __future__ import annotations

import json
import os

import pytest

import sync
import sync_workflow


def write(path, content="content"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    return path


@pytest.fixture
def tree(tmp_path, monkeypatch):
    repo, home, nixos = tmp_path / "repo", tmp_path / "home", tmp_path / "nixos"
    home.mkdir()
    nixos.mkdir()
    for name in ("common-all", "common-dev", "common-desktop", "aardvark", "redline"):
        imports = "../common-all ../common-dev" if name == "aardvark" else "{}"
        write(repo / name / "configuration.nix", imports)
        write(repo / name / "dotfiles/.tool", name)
    write(repo / "common-all/dotfiles/.gitconfig")
    write(repo / "common-dev/dotfiles/.agents/skills/alpha/SKILL.md")
    write(repo / "common-dev/dotfiles/.agents/skills/alpha/.work-compatible")
    write(repo / "common-dev/dotfiles/.claude-plugins/plugin/.claude-plugin/plugin.json", "{}")
    write(repo / "steel-cogs/forest/cog.scm")
    write(
        repo / "frame/sync.json",
        json.dumps({"schema_version": 1, "layers": ["common-all", "common-dev"], "exclusions": []}),
    )
    write(repo / "frame/dotfiles/.tool", "frame")
    monkeypatch.setattr(sync, "TARGETS_ROOT", repo)
    monkeypatch.setattr(sync, "DOTFILES_TARGET", home)
    monkeypatch.setattr(sync, "NIXOS_TARGET", nixos)
    monkeypatch.setattr(sync, "STATE_FILE", repo / ".sync-state.json")
    monkeypatch.setattr(sync, "confirm", lambda message: True)
    return repo, home, nixos


def main(monkeypatch, *arguments):
    monkeypatch.setattr(sync.sys, "argv", ["sync.py", *arguments])
    try:
        sync.main()
    except SystemExit as exc:
        return exc.code
    return 0


def forbid(*args, **kwargs):
    pytest.fail("Forbidden mutation, runner, or prompt reached")


def legacy_state(repo, links):
    state = {"machine": "aardvark", "timestamp": "2026-01-01T00:00:00+00:00", "symlinks": links}
    return write(repo / ".sync-state.json", json.dumps(state))


@pytest.mark.parametrize(
    "content,expected",
    [
        ("../common-all/configuration.nix", ["common-all"]),
        (
            "../common-dev/x.nix ../common-all/configuration.nix ../common-dev/y.nix",
            ["common-all", "common-dev"],
        ),
        ("../../common-dev/programs/development.nix", ["common-dev"]),
        ("./services/default.nix <nixos-hardware/lenovo> ../redline/x.nix", []),
        ("imports = [];", []),
        ("", []),
    ],
)
def test_parse_imported_layers(content, expected):
    assert sync.parse_imported_layers(content) == expected


def test_imports_include_transitive_submodules_and_deduplicate(tree):
    repo, _, _ = tree
    write(repo / "aardvark/programs/dev.nix", "../../common-desktop ../common-all")
    assert sync.get_imported_layers(repo / "aardvark/configuration.nix") == [
        "common-all",
        "common-desktop",
        "common-dev",
    ]
    assert sync.get_imported_layers(repo / "absent/configuration.nix") == []


def test_discover_targets_and_modes(tree):
    repo, _, _ = tree
    write(repo / ".agents/not-a-target")
    write(repo / "stray.txt")
    (repo / "alias").symlink_to(repo / "aardvark", target_is_directory=True)
    targets = {directory.name for directory in sync.discover_targets()}
    assert targets == {"common-all", "common-dev", "common-desktop", "aardvark", "redline", "frame"}
    listing = sync.list_available_targets()
    assert "aardvark (layers: common-all common-dev)" in listing
    assert "redline (no layers)" in listing
    assert "frame (home deployment; --home-only for dotfiles only)" in listing
    assert sync.target_dir("aardvark") == repo / "aardvark"
    assert not (repo / "nixos").exists() and not (repo / "dotfiles").exists()


@pytest.mark.parametrize(
    "name",
    [
        "build_symlink_list",
        "build_skill_symlinks",
        "build_work_skill_symlinks",
        "build_layered_skill_symlinks",
        "build_layered_plugin_symlinks",
        "build_cog_symlinks",
        "bold",
        "green",
        "yellow",
        "red",
        "cyan",
        "dim",
        "AGENTS_SKILLS_SUBPATH",
        "CLAUDE_PLUGINS_SUBPATH",
        "WORK_COMPATIBLE_MARKER",
    ],
)
def test_compatibility_exports_are_shared(name):
    assert getattr(sync, name) is getattr(sync_workflow, name)


def test_confirmation_uses_shared_reader():
    assert sync.confirm is sync_workflow.ask_confirmation


def test_file_builder_filters_layers_and_dotfiles(tree):
    repo, home, nixos = tree
    write(repo / "common-all/real.nix")
    (repo / "common-all/link.nix").symlink_to(repo / "common-all/real.nix")
    system_links = dict(sync.build_symlink_list(repo, nixos, "aardvark", ["common-all"]))
    assert system_links[nixos / "common-all/real.nix"] == repo / "common-all/real.nix"
    assert nixos / "common-all/link.nix" not in system_links
    assert all("dotfiles" not in destination.parts for destination in system_links)
    assert nixos / "common-desktop/configuration.nix" not in system_links
    dotfiles = dict(sync.build_symlink_list(repo, home, "aardvark", ["common-all"], True))
    assert dotfiles[home / ".tool"] == repo / "aardvark/dotfiles/.tool"
    assert dotfiles[home / ".gitconfig"] == repo / "common-all/dotfiles/.gitconfig"
    assert not any(destination.is_relative_to(home / ".agents") for destination in dotfiles)
    assert sync.build_symlink_list(repo, home, "absent", [], True) == []
    with pytest.raises(FileNotFoundError):
        sync.build_symlink_list(repo / "absent", home, "aardvark", [])


@pytest.mark.parametrize(
    "builder,marker",
    [(sync.build_skill_symlinks, "SKILL.md"), (sync.build_cog_symlinks, "cog.scm")],
)
def test_directory_builders_sort_and_require_marker(tmp_path, builder, marker):
    source, destination = tmp_path / "source", tmp_path / "destination"
    for name in ("zeta", "alpha"):
        write(source / name / marker)
    (source / "unmarked").mkdir()
    write(source / "file")
    assert builder(source, destination) == [
        (destination / "alpha", source / "alpha"),
        (destination / "zeta", source / "zeta"),
    ]
    assert builder(source / "missing", destination) == []


def test_work_skills_follow_winning_personal_skill(tree):
    repo, home, _ = tree
    personal = dict(
        sync.build_layered_skill_symlinks(repo, home / ".agents/skills", "aardvark", ["common-dev"])
    )
    assert (
        personal[home / ".agents/skills/alpha"] == repo / "common-dev/dotfiles/.agents/skills/alpha"
    )
    assert sync.build_work_skill_symlinks(
        repo / "common-dev/dotfiles/.agents/skills", home / "work"
    ) == [(home / "work/alpha", repo / "common-dev/dotfiles/.agents/skills/alpha")]
    write(repo / "aardvark/dotfiles/.agents/skills/alpha/SKILL.md")
    plan = sync._plan_nixos_sync("aardvark")
    assert (
        dict(plan.symlinks)[home / ".agents/skills/alpha"]
        == repo / "aardvark/dotfiles/.agents/skills/alpha"
    )
    assert home / ".claude-work/skills/alpha" not in dict(plan.symlinks)


def test_layered_plugins_require_manifest_and_target_wins(tree):
    repo, home, _ = tree
    write(repo / "aardvark/dotfiles/.claude-plugins/plugin/.claude-plugin/plugin.json", "{}")
    write(repo / "aardvark/dotfiles/.claude-plugins/unmarked/hooks.py")
    links = sync.build_layered_plugin_symlinks(repo, home / "plugins", "aardvark", ["common-dev"])
    assert links == [(home / "plugins/plugin", repo / "aardvark/dotfiles/.claude-plugins/plugin")]


def test_full_plan_uses_one_inventory_and_shared_renderer(tree):
    repo, home, nixos = tree
    plan = sync._plan_nixos_sync("aardvark")
    selected = dict(plan.symlinks)
    assert len(plan.symlinks) == len(selected)
    assert selected[home / ".tool"] == repo / "aardvark/dotfiles/.tool"
    assert selected[nixos / "configuration.nix"] == repo / "aardvark/configuration.nix"
    assert selected[home / ".claude/skills"] == home / ".agents/skills"
    assert (
        selected[home / ".claude-work/skills/alpha"]
        == repo / "common-dev/dotfiles/.agents/skills/alpha"
    )
    assert selected[home / ".config/steel/cogs/forest"] == repo / "steel-cogs/forest"
    assert plan.roots == (nixos,)
    assert plan.layers == ("common-all", "common-dev", "aardvark")
    assert plan.state_path == repo / ".sync-state.json"
    description = sync.describe_sync_plan(plan)
    for heading in (
        "Imported layers: common-all common-dev",
        "NixOS configuration (4):",
        "Dotfiles (2):",
        "Agent skills (personal) (1):",
        "Claude Code personal wiring (1):",
        "Claude Code skills (work) (1):",
        "Claude Code plugins (1):",
        "Steel cogs (1):",
        "Layer overrides (2):",
    ):
        assert heading in description
    assert "~/.tool [create]" in description
    assert str(repo) not in description and str(home) not in description
    assert description.index("common-all (1)") < description.index("aardvark (2)")


def test_main_applies_shared_engine_without_sudo_on_writable_system_root(tree, monkeypatch, capsys):
    repo, home, nixos = tree
    monkeypatch.setattr(sync.sync_engine.subprocess, "run", forbid)
    assert main(monkeypatch, "aardvark") == 0
    assert (home / ".tool").readlink() == repo / "aardvark/dotfiles/.tool"
    assert (nixos / "configuration.nix").readlink() == repo / "aardvark/configuration.nix"
    assert (home / ".agents/skills/alpha").is_symlink()
    assert (home / ".claude/skills").readlink() == home / ".agents/skills"
    state = json.loads((repo / ".sync-state.json").read_text())
    assert state["schema_version"] == 2 and state["mode"] == "sync"
    assert state["roots"] == [str(nixos)] and state["target"] == "aardvark"
    assert sync.read_manifest() == state["symlinks"]
    output = capsys.readouterr().out
    assert output.count("~/.tool [create]") == 1
    assert "Sync result:" in output
    assert "nixos-rebuild" not in output


def test_full_dry_run_never_writes_prompts_or_runs_commands(tree, monkeypatch, capsys):
    repo, home, nixos = tree
    monkeypatch.setattr(sync, "confirm", forbid)
    monkeypatch.setattr(sync.sync_engine, "apply_sync", forbid)
    monkeypatch.setattr(sync.sync_engine.subprocess, "run", forbid)
    assert main(monkeypatch, "aardvark", "--dry-run") == 0
    assert "Dry-run: no changes made." in capsys.readouterr().out
    assert not (repo / ".sync-state.json").exists()
    assert not (repo / ".sync-state.json.lock").exists()
    assert list(home.iterdir()) == [] and list(nixos.iterdir()) == []


def test_cancelled_sync_is_success_and_read_only(tree, monkeypatch, capsys):
    repo, home, nixos = tree
    monkeypatch.setattr(sync, "confirm", lambda message: False)
    monkeypatch.setattr(sync.sync_engine, "apply_sync", forbid)
    assert main(monkeypatch, "aardvark") == 0
    assert "Operation cancelled." in capsys.readouterr().out
    assert not (repo / ".sync-state.json").exists()
    assert list(home.iterdir()) == [] and list(nixos.iterdir()) == []


def test_main_rejects_changed_plan_after_confirmation(tree, monkeypatch, capsys):
    repo, home, _ = tree

    def change(message):
        write(home / ".tool", "changed after display")
        return True

    monkeypatch.setattr(sync, "confirm", change)
    assert main(monkeypatch, "aardvark") == 1
    assert "changed after confirmation" in capsys.readouterr().out
    assert (home / ".tool").read_text() == "changed after display"
    assert not (repo / ".sync-state.json").exists()


@pytest.mark.parametrize("scope", ["home", "system"])
@pytest.mark.parametrize("kind", ["file", "symlink", "directory"])
def test_unowned_conflicts_are_preserved_with_partial_status(tree, monkeypatch, scope, kind):
    repo, home, nixos = tree
    destination = home / ".tool" if scope == "home" else nixos / "configuration.nix"
    source = repo / "redline/configuration.nix"
    if kind == "file":
        write(destination, "mine")
    elif kind == "symlink":
        destination.symlink_to(source)
    else:
        write(destination / "private", "mine")
    status = main(monkeypatch, "aardvark")
    assert str(destination) not in sync.read_manifest()
    if kind == "symlink":
        assert destination.readlink() == source
    else:
        assert (
            destination / "private" if kind == "directory" else destination
        ).read_text() == "mine"
    assert status == 1


@pytest.mark.parametrize("scope", ["home", "system"])
@pytest.mark.parametrize("kind", ["file", "symlink"])
def test_force_backs_up_exact_non_directory_conflict(tree, monkeypatch, scope, kind):
    repo, home, nixos = tree
    destination = home / ".tool" if scope == "home" else nixos / "configuration.nix"
    previous = repo / "redline/configuration.nix"
    if kind == "file":
        write(destination, "mine")
    else:
        destination.symlink_to(previous)
    identity = destination.lstat()
    assert main(monkeypatch, "aardvark", "--force") == 0
    backups = list(destination.parent.glob(destination.name + ".sync-backup-*"))
    assert len(backups) == 1
    assert backups[0].lstat().st_ino == identity.st_ino
    if kind == "file":
        assert backups[0].read_text() == "mine"
    else:
        assert backups[0].readlink() == previous
    desired = repo / (
        "aardvark/dotfiles/.tool" if scope == "home" else "aardvark/configuration.nix"
    )
    assert destination.readlink() == desired


@pytest.mark.parametrize("scope", ["home", "system"])
def test_force_never_deletes_real_directories(tree, monkeypatch, scope):
    _, home, nixos = tree
    destination = home / ".tool" if scope == "home" else nixos / "configuration.nix"
    write(destination / "private", "must survive")
    status = main(monkeypatch, "aardvark", "--force")
    assert destination.is_dir() and not destination.is_symlink()
    assert (destination / "private").read_text() == "must survive"
    assert list(destination.parent.glob(destination.name + ".sync-backup-*")) == []
    assert status == 1


def test_modified_owned_links_are_not_automatically_replaced(tree, monkeypatch):
    repo, home, _ = tree
    assert main(monkeypatch, "aardvark") == 0
    destination = home / ".tool"
    destination.unlink()
    destination.symlink_to(repo / "redline/dotfiles/.tool")
    status = main(monkeypatch, "aardvark")
    assert destination.readlink() == repo / "redline/dotfiles/.tool"
    assert str(destination) not in sync.read_manifest()
    assert status == 1


def test_machine_switch_replaces_owned_entrypoint_and_removes_owned_stale_links(tree, monkeypatch):
    repo, home, nixos = tree
    write(repo / "common-dev/dotfiles/.config/dev/config", "dev")
    assert main(monkeypatch, "aardvark") == 0
    write(repo / "redline/configuration.nix", "../common-all")
    assert main(monkeypatch, "redline") == 0
    assert (nixos / "configuration.nix").readlink() == repo / "redline/configuration.nix"
    assert not (nixos / "aardvark").exists()
    assert not (nixos / "common-dev").exists()
    assert not (home / ".config/dev").exists()
    assert (home / ".gitconfig").readlink() == repo / "common-all/dotfiles/.gitconfig"
    assert (home / ".tool").readlink() == repo / "redline/dotfiles/.tool"


def test_legacy_state_migrates_only_valid_owned_entries(tree, monkeypatch):
    repo, home, nixos = tree
    old = write(repo / "common-desktop/old.nix")
    stale = nixos / "old.nix"
    stale.symlink_to(old)
    modified = home / ".obsolete"
    write(modified, "my replacement")
    outside = write(repo.parent / "outside", "outside")
    legacy_state(
        repo,
        {
            str(stale): str(old),
            str(modified): str(repo / "common-all/dotfiles/.gitconfig"),
            str(outside): str(old),
        },
    )
    status = main(monkeypatch, "aardvark")
    assert not os.path.lexists(stale)
    assert modified.read_text() == "my replacement" and outside.read_text() == "outside"
    state = json.loads((repo / ".sync-state.json").read_text())
    assert state["schema_version"] == 2
    assert str(stale) not in state["symlinks"] and str(modified) not in state["symlinks"]
    assert str(outside) not in state["symlinks"]
    assert status == 0


def test_malformed_legacy_state_never_mutates(tree, monkeypatch, capsys):
    repo, home, nixos = tree
    write(repo / ".sync-state.json", json.dumps({"symlinks": {}}))
    monkeypatch.setattr(sync, "confirm", forbid)
    assert main(monkeypatch, "aardvark") == 1
    assert "Malformed or mismatched" in capsys.readouterr().out
    assert list(home.iterdir()) == [] and list(nixos.iterdir()) == []


def test_old_claude_skill_leaves_are_removed_before_wiring_directory(tree, monkeypatch):
    repo, home, _ = tree
    old_source = repo / "common-dev/dotfiles/.agents/skills/alpha"
    old_leaf = home / ".claude/skills/alpha"
    old_leaf.parent.mkdir(parents=True)
    old_leaf.symlink_to(old_source, target_is_directory=True)
    agents = home / ".agents/skills/alpha"
    agents.parent.mkdir(parents=True)
    agents.symlink_to(old_source, target_is_directory=True)
    legacy_state(repo, {str(old_leaf): str(old_source)})
    assert main(monkeypatch, "aardvark") == 0
    assert (home / ".claude/skills").readlink() == home / ".agents/skills"
    assert agents.readlink() == old_source
    assert old_leaf.resolve() == old_source
    assert (old_source / "SKILL.md").read_text() == "content"


def test_init_state_records_all_layers_but_only_matching_existing_links(tree, monkeypatch, capsys):
    repo, home, nixos = tree
    desktop_source = repo / "common-desktop/configuration.nix"
    desktop = nixos / "common-desktop/configuration.nix"
    desktop.parent.mkdir()
    desktop.symlink_to(desktop_source)
    git = home / ".gitconfig"
    git.symlink_to(repo / "common-all/dotfiles/.gitconfig")
    modified = write(home / ".tool", "mine")
    missing = home / ".agents/skills/alpha"
    before = (desktop.lstat().st_ino, git.lstat().st_ino)
    monkeypatch.setattr(sync.sync_engine.subprocess, "run", forbid)
    assert main(monkeypatch, "redline", "--init-state") == 0
    assert sync.read_manifest() == {
        str(desktop): str(desktop_source),
        str(git): str(repo / "common-all/dotfiles/.gitconfig"),
    }
    assert json.loads((repo / ".sync-state.json").read_text())["schema_version"] == 2
    assert before == (desktop.lstat().st_ino, git.lstat().st_ino)
    assert modified.read_text() == "mine" and not os.path.lexists(missing)
    assert "no symlinks are changed" in capsys.readouterr().out
    write(repo / "redline/configuration.nix", "../common-all")
    assert main(monkeypatch, "redline", "--force") == 0
    assert not os.path.lexists(desktop)
    assert git.is_symlink()


def test_init_state_records_skills_wiring_and_work_only_when_matching(tree, monkeypatch):
    repo, home, _ = tree
    source = repo / "common-dev/dotfiles/.agents/skills/alpha"
    paths = (home / ".agents/skills/alpha", home / ".claude-work/skills/alpha")
    for destination in paths:
        destination.parent.mkdir(parents=True)
        destination.symlink_to(source, target_is_directory=True)
    wiring = home / ".claude/skills"
    wiring.parent.mkdir()
    wiring.symlink_to(home / ".agents/skills", target_is_directory=True)
    assert main(monkeypatch, "redline", "--init-state") == 0
    assert sync.read_manifest() == {
        **{str(destination): str(source) for destination in paths},
        str(wiring): str(home / ".agents/skills"),
    }


def test_init_state_empty_home_writes_empty_ownership_only(tree, monkeypatch):
    repo, home, nixos = tree
    monkeypatch.setattr(sync.sync_engine.subprocess, "run", forbid)
    assert main(monkeypatch, "aardvark", "--init-state") == 0
    assert sync.read_manifest() == {}
    assert list(home.iterdir()) == [] and list(nixos.iterdir()) == []
    assert (repo / ".sync-state.json").exists()


@pytest.mark.parametrize("option", ["--home-only", "--dry-run"])
def test_init_state_rejects_incompatible_modes(tree, monkeypatch, option):
    assert main(monkeypatch, "aardvark", "--init-state", option) == 2
    assert not (tree[0] / ".sync-state.json").exists()


def test_init_state_requires_machine(tree, monkeypatch):
    assert main(monkeypatch, "--init-state") == 2


@pytest.mark.parametrize("target", ["missing", "../aardvark", "/aardvark"])
def test_unknown_or_unsafe_target_is_rejected_without_mutation(tree, monkeypatch, target):
    repo, home, nixos = tree
    assert main(monkeypatch, target) == 1
    assert not (repo / ".sync-state.json").exists()
    assert list(home.iterdir()) == [] and list(nixos.iterdir()) == []


@pytest.mark.parametrize("target", ["../aardvark", "/aardvark"])
def test_unsafe_target_is_rejected_before_import_scanning(tree, monkeypatch, target):
    monkeypatch.setattr(sync, "get_imported_layers", forbid)
    assert main(monkeypatch, target) == 1


def test_read_manifest_missing_and_legacy_compatibility(tree):
    repo, home, _ = tree
    assert sync.read_manifest() is None
    links = {str(home / ".tool"): str(repo / "aardvark/dotfiles/.tool")}
    state = legacy_state(repo, links)
    assert sync.read_manifest(state) == links


def test_home_only_calls_shared_workflow_without_system_or_legacy_state(tree, monkeypatch, capsys):
    repo, home, nixos = tree
    monkeypatch.setattr(sync, "_plan_nixos_sync", forbid)
    monkeypatch.setattr(sync.sync_engine.subprocess, "run", forbid)
    assert main(monkeypatch, "--home-only", "frame") == 0
    assert (home / ".tool").readlink() == repo / "frame/dotfiles/.tool"
    assert not (repo / ".sync-state.json").exists()
    assert list(nixos.iterdir()) == []
    output = capsys.readouterr().out
    assert "Dotfiles (2):" in output and "Sync result:" in output
    assert "NixOS configuration" not in output


def test_home_only_dry_run_is_read_only(tree, monkeypatch, capsys):
    repo, home, nixos = tree
    monkeypatch.setattr(sync, "confirm", forbid)
    monkeypatch.setattr(sync, "apply_home_sync", forbid)
    monkeypatch.setattr(sync.sync_engine.subprocess, "run", forbid)
    assert main(monkeypatch, "--home-only", "frame", "--dry-run") == 0
    assert "Dry-run" in capsys.readouterr().out
    assert list(home.iterdir()) == [] and list(nixos.iterdir()) == []
    assert not (repo / ".sync-state.json").exists()


def test_home_only_force_backs_up_conflict_and_preserves_directory(tree, monkeypatch):
    _, home, _ = tree
    write(home / ".tool", "mine")
    write(home / ".gitconfig/private", "mine")
    status = main(monkeypatch, "--home-only", "frame", "--force")
    assert (home / ".tool").is_symlink()
    assert next(home.glob(".tool.sync-backup-*")).read_text() == "mine"
    assert (home / ".gitconfig/private").read_text() == "mine"
    assert status == 1


def test_home_only_changed_plan_is_rejected(tree, monkeypatch, capsys):
    _, home, _ = tree

    def change(message):
        write(home / ".tool", "new conflict")
        return True

    monkeypatch.setattr(sync, "confirm", change)
    assert main(monkeypatch, "--home-only", "frame") == 1
    assert "changed after confirmation" in capsys.readouterr().out
    assert not (home / ".local/state/nixos-configuration/sync-home.json").exists()


def test_frame_dispatches_with_shared_confirmation_adapter(tree, monkeypatch):
    from frame import deploy as deployment

    repo, home, _ = tree
    captured = []
    monkeypatch.setattr(
        deployment, "deploy", lambda frame, **kwargs: captured.append((frame, kwargs)) or 0
    )
    monkeypatch.setattr(sync, "_plan_nixos_sync", forbid)
    assert main(monkeypatch, "frame", "--dry-run") == 0
    frame, options = captured[0]
    assert frame.home == home and frame.repo == repo
    assert options == {"dry_run": True, "confirm": sync._confirmation}
    assert list(home.iterdir()) == []


@pytest.mark.parametrize("option", ["--force", "--init-state"])
def test_frame_rejects_legacy_mutation_options(tree, monkeypatch, option):
    assert main(monkeypatch, "frame", option) == 2


def test_frame_propagates_partial_status(tree, monkeypatch):
    from frame import deploy as deployment

    monkeypatch.setattr(deployment, "deploy", lambda *args, **kwargs: 1)
    assert main(monkeypatch, "frame") == 1


def test_mode_help_and_no_target_listing(tree, monkeypatch, capsys):
    assert main(monkeypatch, "--help") == 0
    help_text = capsys.readouterr().out
    assert "--home-only" in help_text and "--dry-run" in help_text
    assert "Back up confirmed non-directory" in help_text
    assert main(monkeypatch) == 1
    output = capsys.readouterr().out
    assert "Available targets:" in output
    assert "frame (home deployment; --home-only for dotfiles only)" in output
