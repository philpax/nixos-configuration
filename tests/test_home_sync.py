"""Home-only sync scenarios use temporary repositories and homes, never host state."""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

import home_sync
import sync
import sync_engine

FRAME_EXCLUSIONS = tuple(
    json.loads((Path(__file__).resolve().parents[1] / "frame/sync.json").read_text())["exclusions"]
)


def put(path, text="fixture"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


@pytest.fixture
def tree(tmp_path):
    repo, home = tmp_path / "repo", tmp_path / "home"
    repo.mkdir()
    home.mkdir()
    for layer in ("common-all", "common-dev", "common-desktop", "common-dev-desktop"):
        put(repo / layer / "configuration.nix", "{}")
        (repo / layer / "dotfiles").mkdir()
    put(
        repo / "frame/sync.json",
        json.dumps(
            {
                "schema_version": 1,
                "layers": ["common-all", "common-dev", "common-desktop", "common-dev-desktop"],
                "exclusions": [*FRAME_EXCLUSIONS, ".excluded"],
            }
        ),
    )
    return repo, home


def plan(tree, **kwargs):
    repo, home = tree
    return home_sync.plan_home_sync(target="frame", repo=repo, home=home, **kwargs)


def write_state(tree, entries, **changes):
    repo, home = tree
    state = {
        "schema_version": 1,
        "mode": "home-only",
        "home": str(home.resolve()),
        "repo": str(repo.resolve()),
        "target": "frame",
        "symlinks": {str(k): str(v) for k, v in entries.items()},
    }
    state.update(changes)
    return put(home / ".local/state/nixos-configuration/sync-home.json", json.dumps(state))


def snapshot(root):
    result = {}
    for path in sorted(root.rglob("*")):
        rel = str(path.relative_to(root))
        info = path.lstat()
        result[rel] = (
            info.st_mode,
            os.readlink(path)
            if path.is_symlink()
            else path.read_bytes()
            if path.is_file()
            else None,
        )
    return result


def forbid(*args, **kwargs):
    pytest.fail("Forbidden mutation/runner/prompt reached")


def main_home(tree, monkeypatch, *arguments, confirm=True):
    repo, home = tree
    monkeypatch.setattr(sync, "TARGETS_ROOT", repo)
    monkeypatch.setattr(sync, "DOTFILES_TARGET", home)
    monkeypatch.setattr(sync, "confirm", confirm if callable(confirm) else lambda message: confirm)
    for name in ("_init_state", "get_imported_layers"):
        monkeypatch.setattr(sync, name, forbid)
    monkeypatch.setattr(sync_engine.subprocess, "Popen", forbid)
    monkeypatch.setattr(sync.sys, "argv", ["sync.py", "--home-only", "frame", *arguments])
    sync.main()


@pytest.mark.parametrize(
    "changes",
    [
        {"schema_version": 2},
        {"schema_version": True},
        {"layers": ["common-all", "common-all"]},
        {"layers": ["frame"]},
        {"layers": ["unknown"]},
        {"layers": ["../common-all"]},
        {"layers": ["/common-all"]},
        {"layers": [12]},
        {"exclusions": ["../escape"]},
        {"exclusions": ["/absolute"]},
        {"exclusions": ["a/../b"]},
        {"exclusions": ["a//b"]},
        {"exclusions": [None]},
        {"extra": True},
        {"layers": "common-all"},
    ],
)
def test_home_target_validation(tree, changes):
    path = tree[0] / "frame/sync.json"
    selection = json.loads(path.read_text())
    selection.update(changes)
    path.write_text(json.dumps(selection))
    before = snapshot(tree[1])
    with pytest.raises(ValueError):
        plan(tree)
    assert snapshot(tree[1]) == before


def test_home_target_requires_manifest_not_nixos(tree):
    path = tree[0] / "frame/sync.json"
    path.unlink()
    put(path.parent / "configuration.nix", "{}")
    with pytest.raises(ValueError, match="requires sync.json"):
        plan(tree)
    for target in ("../frame", "/frame", "FRAME", "missing"):
        with pytest.raises(ValueError):
            home_sync.plan_home_sync(target=target, repo=tree[0], home=tree[1])


def test_home_sync_selection_and_overrides(tree, monkeypatch, capsys):
    repo, home = tree
    put(repo / "common-all/dotfiles/.config/tool", "all")
    put(repo / "common-dev-desktop/dotfiles/.config/tool", "desktop")
    winner = put(repo / "frame/dotfiles/.config/tool", "frame")
    key = put(repo / "frame/dotfiles/.ssh/key", "synthetic-key")
    put(repo / "frame/dotfiles/.excluded/child", "never")
    put(repo / "common-dev/dotfiles/.agents/skills/skill/SKILL.md")
    put(repo / "common-dev/dotfiles/.agents/skills/skill/.work-compatible")
    put(repo / "common-dev/dotfiles/.claude-plugins/plugin/.claude-plugin/plugin.json", "{}")
    put(repo / "steel-cogs/forest/cog.scm")
    put(repo / "steel-cogs/uninitialized/README")
    proposal = plan(tree)
    assert proposal.layers[-1] == "frame"
    assert dict(proposal.symlinks)[home / ".config/tool"] == winner
    assert len([dest for dest, _ in proposal.symlinks if dest == home / ".config/tool"]) == 1
    assert len(proposal.overrides) == 2
    main_home(tree, monkeypatch)
    assert (home / ".config/tool").read_text() == "frame"
    assert (home / ".ssh/key").readlink() == key
    assert not (home / ".excluded").exists()
    assert (home / ".agents/skills/skill").is_symlink()
    assert (home / ".claude/skills").readlink() == home / ".agents/skills"
    assert (home / ".claude-work/skills/skill").is_symlink()
    assert (home / ".local/share/claude-plugins/plugin").is_symlink()
    assert (home / ".config/steel/cogs/forest").is_symlink()
    assert not (home / ".config/steel/cogs/uninitialized").exists()
    assert "Layer overrides" in capsys.readouterr().out
    assert not (repo / ".sync-state.json").exists()


def test_frame_passive_desktop_selection(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    repo = Path(__file__).resolve().parents[1]
    proposal = home_sync.plan_home_sync(target="frame", repo=repo, home=home)
    selected = {str(dest.relative_to(home)) for dest, _ in proposal.symlinks}
    for path in (
        ".config/fish/config.fish",
        ".config/fish/functions/refresh-display-env.fish",
        ".config/ghostty/config",
        ".config/alacritty/alacritty.toml",
        ".config/niri/config.kdl",
        ".config/quickshell/shell.qml",
        ".config/swaylock/config",
        ".local/bin/record-screen.sh",
        ".ssh/authorized_keys",
        ".local/state/makima/auth/ananke-mindgame.json",
        ".local/state/makima/auth/ananke-redline.json",
    ):
        assert path in selected
    for path in FRAME_EXCLUSIONS:
        assert not any(dest == path or dest.startswith(path + "/") for dest in selected)
    assert snapshot(home) == {}


@pytest.mark.parametrize("relative", FRAME_EXCLUSIONS)
def test_home_sync_protected_paths(tree, monkeypatch, relative):
    repo, home = tree
    source = put(repo / "common-all/dotfiles" / relative)
    destination = home / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.symlink_to(source)
    state = write_state(tree, {destination: source})
    # Protection applies to selected and stale destinations, even with force.
    main_home(tree, monkeypatch, "--force")
    assert destination.is_symlink()
    assert destination.readlink() == source
    assert str(destination) not in sync.read_manifest(state)
    source.unlink()
    main_home(tree, monkeypatch)
    assert destination.is_symlink()


def test_home_exclusions_come_only_from_declaration_and_control_paths(tree):
    repo, home = tree
    declaration = repo / "frame/sync.json"
    selection = json.loads(declaration.read_text())
    selection["exclusions"] = []
    declaration.write_text(json.dumps(selection))
    sources = {
        home / relative: put(repo / "common-all/dotfiles" / relative)
        for relative in (".bashrc", ".config/mimeapps.list", "nixos-clean.sh")
    }
    proposal = plan(tree)
    assert dict(proposal.symlinks) == {
        **sources,
        home / ".claude/skills": home / ".agents/skills",
    }
    assert set(proposal.exclusions) == {
        ".local/state/nixos-configuration/sync-home.json" + suffix
        for suffix in ("", ".lock", ".worker-lock", ".worker-request")
    }
    selection["exclusions"] = ["nixos-clean.sh", "nixos-clean.sh"]
    declaration.write_text(json.dumps(selection))
    revised = plan(tree)
    assert (home / "nixos-clean.sh", sources[home / "nixos-clean.sh"]) not in revised.symlinks
    assert revised.exclusions.count("nixos-clean.sh") == 1
    assert (home / ".bashrc", sources[home / ".bashrc"]) in revised.symlinks
    assert snapshot(home) == {}


@pytest.mark.parametrize(
    "relative", (".ssh/authorized_keys", ".local/state/makima/auth/account.json")
)
def test_declared_credentials_follow_shared_ownership_rules(tree, relative):
    repo, home = tree
    source = put(repo / "common-all/dotfiles" / relative, "synthetic-repository-credential")
    destination = home / relative
    first = plan(tree)
    assert dict(first.symlinks)[destination] == source
    assert next(op.action for op in first.operations if op.destination == destination) == "create"
    result = home_sync.apply_home_sync(first, confirmed=True)
    assert result.complete and not result.warnings
    assert destination.readlink() == source
    assert sync.read_manifest(first.state_path)[str(destination)] == str(source)
    assert (
        next(op.action for op in plan(tree).operations if op.destination == destination) == "keep"
    )

    replacement = put(repo / "frame/dotfiles" / relative, "synthetic-frame-override")
    update = plan(tree)
    assert next(op.action for op in update.operations if op.destination == destination) == "replace"
    home_sync.apply_home_sync(update, confirmed=True)
    assert destination.readlink() == replacement

    modified = put(home / "user-credential", "synthetic-user-credential")
    destination.unlink()
    destination.symlink_to(modified)
    conflict = plan(tree)
    assert next(op.action for op in conflict.operations if op.destination == destination) == "skip"
    home_sync.apply_home_sync(conflict, confirmed=True)
    assert destination.readlink() == modified
    assert str(destination) not in sync.read_manifest(first.state_path)


@pytest.mark.parametrize(
    "relative", (".ssh/authorized_keys", ".local/state/makima/auth/account.json")
)
def test_declared_credentials_preserve_existing_unowned_files(tree, relative):
    repo, home = tree
    put(repo / "common-all/dotfiles" / relative, "synthetic-repository-credential")
    destination = put(home / relative, "synthetic-existing-credential")
    proposal = plan(tree)
    operation = next(op for op in proposal.operations if op.destination == destination)
    assert operation.action == "skip" and operation.conflict
    home_sync.apply_home_sync(proposal, confirmed=True)
    assert not destination.is_symlink()
    assert destination.read_text() == "synthetic-existing-credential"


def test_additional_kde_autostart_descendant_excluded(tree):
    repo, home = tree
    source = put(repo / "common-desktop/dotfiles/.config/autostart-scripts/session.sh")
    assert (home / ".config/autostart-scripts/session.sh", source) not in plan(tree).symlinks
    destination = home / ".config/autostart-scripts/session.sh"
    destination.parent.mkdir(parents=True)
    destination.symlink_to(source)
    write_state(tree, {destination: source})
    source.unlink()
    home_sync.apply_home_sync(plan(tree), confirmed=True)
    assert destination.is_symlink()


def test_home_sync_state_isolation(tree):
    repo, home = tree
    put(
        repo / ".sync-state.json",
        json.dumps({"symlinks": {"/etc/nixos/configuration.nix": "poison"}}),
    )
    legacy = (repo / ".sync-state.json").read_bytes()
    home_sync.apply_home_sync(plan(tree), confirmed=True)
    state_path = home / ".local/state/nixos-configuration/sync-home.json"
    full, _ = home_sync.read_home_state(state_path, home=home, repo=repo)
    assert full["mode"] == "sync"
    assert full["schema_version"] == 2
    assert full["roots"] == []
    assert full["home"] == str(home)
    assert full["repo"] == str(repo)
    assert sync.read_manifest(state_path) == full["symlinks"]
    assert (repo / ".sync-state.json").read_bytes() == legacy
    custom = home / "custom/state.json"
    custom_plan = plan(tree, state_path=custom)
    assert custom_plan.state_path == custom
    home_sync.apply_home_sync(custom_plan, confirmed=True)
    assert custom.exists()


@pytest.mark.parametrize(
    "changes",
    [
        {"mode": "nixos"},
        {"home": "/other/home"},
        {"repo": "/other/repo"},
        {"schema_version": 0},
        {"schema_version": True},
        {"symlinks": []},
        {"symlinks": {"key": None}},
        {"target": "../frame"},
    ],
)
def test_malformed_or_mismatched_metadata_rejected(tree, changes):
    write_state(tree, {}, **changes)
    before = snapshot(tree[1])
    with pytest.raises(ValueError, match="metadata"):
        plan(tree)
    assert snapshot(tree[1]) == before


@pytest.mark.parametrize("raw", ["{", "null", "{}", "[]"])
def test_malformed_state_is_not_empty_ownership(tree, raw):
    put(tree[1] / ".local/state/nixos-configuration/sync-home.json", raw)
    with pytest.raises(ValueError):
        plan(tree)


def test_home_sync_rejects_outside_and_symlink_escape(tree, tmp_path):
    repo, home = tree
    source = put(repo / "common-all/dotfiles/.config/tool")
    outside = tmp_path / "outside"
    outside.mkdir()
    escaped = put(outside / "keep", "keep")
    (home / ".config").symlink_to(outside, target_is_directory=True)
    state = write_state(
        tree,
        {
            "/etc/nixos/configuration.nix": source,
            "relative": source,
            str(home) + "/x/../unsafe": source,
            str(home) + "/.config/keep": source,
            str(home / "bad-source"): "/etc/passwd",
        },
    )
    proposal = plan(tree)
    assert len(proposal.warnings) == 5
    assert any(op.protection == "unsafe parent" for op in proposal.operations)
    home_sync.apply_home_sync(proposal, confirmed=True)
    assert escaped.read_text() == "keep"
    assert not (outside / "tool").exists()
    assert sync.read_manifest(state) == {str(home / ".claude/skills"): str(home / ".agents/skills")}


@pytest.mark.parametrize("kind", ["state-parent", "state-file", "lock-file"])
def test_control_symlink_escape_rejected(tree, tmp_path, kind):
    repo, home = tree
    outside = put(tmp_path / "outside", "{}")
    state = home / ".local/state/nixos-configuration/sync-home.json"
    state.parent.mkdir(parents=True)
    if kind == "state-parent":
        state.parent.rmdir()
        state.parent.symlink_to(tmp_path)
    else:
        path = state if kind == "state-file" else state.with_name(state.name + ".lock")
        path.symlink_to(outside)
    with pytest.raises(ValueError):
        plan(tree)
    assert outside.read_text() == "{}"


def test_state_outside_home_rejected(tree, tmp_path):
    for path in (tmp_path / "state.json", Path("state.json"), tree[1] / ".." / "state.json"):
        with pytest.raises(ValueError):
            plan(tree, state_path=path)


def test_home_dry_run_no_mutation(tree, monkeypatch, capsys):
    repo, home = tree
    put(repo / "common-all/dotfiles/.config/tool")
    put(home / ".config/tool", "conflict")
    before = snapshot(home)
    monkeypatch.setattr(sync, "confirm", forbid)
    # main_home sets confirmation, so replace it with a sentinel that fails only on invocation.
    main_home(tree, monkeypatch, "--dry-run", confirm=forbid)
    assert snapshot(home) == before
    assert "unowned or modified object" in capsys.readouterr().out
    assert not (home / ".local").exists()


def test_home_dry_run_existing_state_is_read_only(tree, monkeypatch):
    repo, home = tree
    source = put(repo / "stale")
    (home / "stale").symlink_to(source)
    write_state(tree, {home / "stale": source})
    before = snapshot(home)
    monkeypatch.setattr(sync_engine, "_persist", forbid)
    monkeypatch.setattr(sync_engine, "_mutation_lock", forbid)
    main_home(tree, monkeypatch, "--dry-run")
    assert snapshot(home) == before


def test_confirmation_required_and_decline_writes_nothing(tree, monkeypatch):
    with pytest.raises(ValueError, match="confirmation"):
        home_sync.apply_home_sync(plan(tree))
    main_home(tree, monkeypatch, confirm=False)
    assert snapshot(tree[1]) == {}


def test_home_sync_never_calls_sudo(tree, monkeypatch):
    put(tree[0] / "common-all/dotfiles/.config/tool")
    main_home(tree, monkeypatch)
    assert (tree[1] / ".config/tool").is_symlink()


def test_home_resync_owned_stale_only(tree):
    repo, home = tree
    source = put(repo / "old-source")
    old, changed, real = home / "old", home / "changed", home / "real"
    for destination in (old, changed, real):
        destination.symlink_to(source)
    write_state(tree, dict.fromkeys((old, changed, real), source))
    changed.unlink()
    changed.symlink_to(repo / "different")
    real.unlink()
    real.write_text("user data")
    proposal = plan(tree)
    home_sync.apply_home_sync(proposal, confirmed=True)
    assert not old.is_symlink()
    assert changed.readlink() == repo / "different"
    assert real.read_text() == "user data"
    assert str(changed) not in sync.read_manifest(proposal.state_path)
    assert str(real) not in sync.read_manifest(proposal.state_path)


@pytest.mark.parametrize("owned", [False, True])
def test_home_selected_modified_or_unowned_symlink_survives(tree, owned):
    repo, home = tree
    desired = put(repo / "common-all/dotfiles/tool")
    old = put(repo / "old")
    destination = home / "tool"
    destination.symlink_to(old)
    if owned:
        write_state(tree, {destination: desired})
    proposal = plan(tree)
    assert next(op for op in proposal.operations if op.destination == destination).conflict
    home_sync.apply_home_sync(proposal, confirmed=True)
    assert destination.readlink() == old
    assert str(destination) not in sync.read_manifest(proposal.state_path)


def test_owned_source_change_and_desired_noop(tree):
    repo, home = tree
    old = put(repo / "old")
    desired = put(repo / "common-all/dotfiles/tool")
    destination = home / "tool"
    destination.symlink_to(old)
    write_state(tree, {destination: old})
    proposal = plan(tree)
    assert (
        next(op for op in proposal.operations if op.destination == destination).action == "replace"
    )
    home_sync.apply_home_sync(proposal, confirmed=True)
    assert destination.readlink() == desired
    again = plan(tree)
    assert next(op for op in again.operations if op.destination == destination).action == "keep"
    home_sync.apply_home_sync(again, confirmed=True)
    assert sync.read_manifest(again.state_path)[str(destination)] == str(desired)


def test_selected_dangling_owned_link_is_conflict(tree):
    repo, home = tree
    put(repo / "common-all/dotfiles/tool")
    old = repo / "missing"
    (home / "tool").symlink_to(old)
    write_state(tree, {home / "tool": old})
    proposal = plan(tree)
    assert next(op for op in proposal.operations if op.destination == home / "tool").conflict
    home_sync.apply_home_sync(proposal, confirmed=True)
    assert (home / "tool").readlink() == old


def test_home_failure_second_link_records_progress_and_retains_unvisited(tree, monkeypatch):
    repo, home = tree
    # Paths sort after the personal wiring, and the injected failure selects tool links only.
    for name in ("a", "b", "c"):
        put(repo / "common-all/dotfiles" / name)
    old = put(repo / "old-c")
    (home / "c").symlink_to(old)
    write_state(tree, {home / "c": old})
    proposal = plan(tree)
    original = sync_engine.os.symlink

    def fail_second(source, destination, **kwargs):
        if destination == "b":
            raise OSError("injected second link failure")
        return original(source, destination, **kwargs)

    with monkeypatch.context() as patch:
        patch.setattr(sync_engine.os, "symlink", fail_second)
        with pytest.raises(OSError, match="second link"):
            home_sync.apply_home_sync(proposal, confirmed=True)
    manifest = sync.read_manifest(proposal.state_path)
    assert manifest[str(home / "a")] == str(repo / "common-all/dotfiles/a")
    assert manifest[str(home / "c")] == str(old)
    assert str(home / "b") not in manifest
    home_sync.apply_home_sync(plan(tree), confirmed=True)
    assert (home / "b").is_symlink()
    assert (home / "c").readlink() == repo / "common-all/dotfiles/c"


def test_changed_object_and_parent_after_plan_preserved(tree, tmp_path):
    repo, home = tree
    put(repo / "common-all/dotfiles/.config/tool")
    proposal = plan(tree)
    outside = tmp_path / "outside"
    outside.mkdir()
    (home / ".config").symlink_to(outside)
    home_sync.apply_home_sync(proposal, confirmed=True)
    assert snapshot(outside) == {}
    (home / ".config").unlink()
    proposal = plan(tree)
    put(home / ".config/tool", "user data")
    result = home_sync.apply_home_sync(proposal, confirmed=True)
    assert (home / ".config/tool").read_text() == "user data"
    assert result.warnings


@pytest.mark.parametrize("symlink", [False, True])
def test_force_requires_confirmation_and_exact_backup(tree, symlink):
    repo, home = tree
    desired = put(repo / "common-all/dotfiles/tool")
    destination = home / "tool"
    if symlink:
        destination.symlink_to("missing-relative-target")
    else:
        put(destination, "original bytes")
        destination.chmod(0o640)
    proposal = plan(tree, force=True)
    before = snapshot(home)
    with pytest.raises(ValueError):
        home_sync.apply_home_sync(proposal)
    assert snapshot(home) == before
    result = home_sync.apply_home_sync(proposal, confirmed=True)
    assert destination.readlink() == desired
    assert len(result.backups) == 1
    backup = result.backups[0]
    if symlink:
        assert os.readlink(backup) == "missing-relative-target"
    else:
        assert backup.read_bytes() == b"original bytes"
        assert backup.stat().st_mode & 0o777 == 0o640


def test_force_never_replaces_directory_or_changed_object(tree):
    repo, home = tree
    put(repo / "common-all/dotfiles/tool")
    put(home / "tool/keep", "keep")
    result = home_sync.apply_home_sync(plan(tree, force=True), confirmed=True)
    assert (home / "tool/keep").read_text() == "keep"
    assert not result.backups
    (home / "tool/keep").unlink()
    (home / "tool").rmdir()
    put(home / "tool", "before")
    proposal = plan(tree, force=True)
    (home / "tool").write_text("after planning")
    result = home_sync.apply_home_sync(proposal, confirmed=True)
    assert (home / "tool").read_text() == "after planning"
    assert not result.backups


def test_empty_selected_set_still_removes_stale_and_saves_state(tree):
    repo, home = tree
    selection = repo / "frame/sync.json"
    data = json.loads(selection.read_text())
    data["layers"] = []
    data["exclusions"] += [".claude/skills"]
    selection.write_text(json.dumps(data))
    source = put(repo / "old")
    (home / "old").symlink_to(source)
    write_state(tree, {home / "old": source})
    proposal = plan(tree)
    assert proposal.symlinks == []
    home_sync.apply_home_sync(proposal, confirmed=True)
    assert not (home / "old").exists()
    assert sync.read_manifest(proposal.state_path) == {}


def test_first_sync_removes_old_cc_leaves_without_touching_agents_tree(tree):
    repo, home = tree
    source = put(repo / "common-dev/dotfiles/.agents/skills/example/SKILL.md").parent
    old_source = put(repo / "old-skills/example/SKILL.md").parent
    old = home / ".claude/skills/example"
    old.parent.mkdir(parents=True)
    old.symlink_to(old_source)
    write_state(tree, {old: old_source})
    proposal = plan(tree)
    assert proposal.operations[0].action == "remove"
    home_sync.apply_home_sync(proposal, confirmed=True)
    assert (home / ".claude/skills").readlink() == home / ".agents/skills"
    assert (home / ".agents/skills/example").readlink() == source
    assert (source / "SKILL.md").read_text() == "fixture"
    # A poisonous old leaf beneath the new wiring cannot resolve into the repository.
    state = sync.read_manifest(proposal.state_path)
    state[str(old / "SKILL.md")] = str(source / "SKILL.md")
    write_state(tree, state)
    home_sync.apply_home_sync(plan(tree), confirmed=True)
    assert (source / "SKILL.md").exists()
    assert (home / ".agents/skills/example").is_symlink()


def test_skill_migration_keeps_unowned_leaves_and_directory(tree):
    repo, home = tree
    source = put(repo / "old")
    old = home / ".claude/skills/owned"
    old.parent.mkdir(parents=True)
    old.symlink_to(source)
    put(old.parent / "unowned", "keep")
    write_state(tree, {old: source})
    home_sync.apply_home_sync(plan(tree, force=True), confirmed=True)
    assert old.parent.is_dir() and not old.parent.is_symlink()
    assert (old.parent / "unowned").read_text() == "keep"


def test_state_changed_after_review_requires_new_plan(tree):
    proposal = plan(tree)
    write_state(tree, {})
    with pytest.raises(ValueError, match="changed after planning"):
        home_sync.apply_home_sync(proposal, confirmed=True)
    assert not (tree[1] / ".claude").exists()


def test_home_mutation_holds_lock(tree, monkeypatch):
    import fcntl

    proposal = plan(tree)
    original = sync_engine._persist
    seen = []

    def persist_with_check(plan, ownership):
        lock = plan.state_path.with_name(plan.state_path.name + ".lock")
        with lock.open("r+") as other:
            with pytest.raises(BlockingIOError):
                fcntl.flock(other.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        seen.append(True)
        original(plan, ownership)

    monkeypatch.setattr(sync_engine, "_persist", persist_with_check)
    home_sync.apply_home_sync(proposal, confirmed=True)
    assert seen


def test_work_account_follows_winning_skill_marker(tree):
    repo, home = tree
    base = put(repo / "common-dev/dotfiles/.agents/skills/skill/SKILL.md").parent
    put(base / ".work-compatible")
    override = put(repo / "frame/dotfiles/.agents/skills/skill/SKILL.md").parent
    proposal = plan(tree)
    assert dict(proposal.symlinks)[home / ".agents/skills/skill"] == override
    assert home / ".claude-work/skills/skill" not in dict(proposal.symlinks)
    put(override / ".work-compatible")
    assert dict(plan(tree).symlinks)[home / ".claude-work/skills/skill"] == override


def test_control_paths_cannot_occupy_protected_destinations(tree):
    for path in (".bashrc", ".tokens/state.json", ".local/share/frame-cli/sync.json"):
        with pytest.raises(ValueError, match="protected destinations"):
            plan(tree, state_path=tree[1] / path)
    assert snapshot(tree[1]) == {}


def test_activation_custom_paths_excluded_from_create_and_stale_cleanup(tree):
    repo, home = tree
    source = put(repo / "common-all/dotfiles/custom/assets/font")
    destination = home / "custom/assets/font"
    destination.parent.mkdir(parents=True)
    destination.symlink_to(source)
    write_state(tree, {destination: source})
    proposal = plan(tree, extra_exclusions=("custom/assets",))
    assert destination not in dict(proposal.symlinks)
    home_sync.apply_home_sync(proposal, confirmed=True)
    assert destination.is_symlink()
    source.unlink()
    home_sync.apply_home_sync(plan(tree, extra_exclusions=("custom/assets",)), confirmed=True)
    assert destination.is_symlink()


def test_explicit_home_layer_order_wins_before_machine(tree):
    repo, home = tree
    first = put(repo / "common-dev/dotfiles/tool", "first")
    last = put(repo / "common-all/dotfiles/tool", "last")
    selection = repo / "frame/sync.json"
    data = json.loads(selection.read_text())
    data["layers"] = ["common-dev", "common-all"]
    selection.write_text(json.dumps(data))
    proposal = plan(tree)
    assert dict(proposal.symlinks)[home / "tool"] == last
    assert proposal.overrides == ((home / "tool", first, last),)


def test_full_main_invalid_home_selection_writes_nothing(tree, monkeypatch):
    path = tree[0] / "frame/sync.json"
    path.write_text("{}")
    with pytest.raises(SystemExit) as exc:
        main_home(tree, monkeypatch)
    assert exc.value.code == 1
    assert snapshot(tree[1]) == {}


def test_home_init_state_rejected_before_mutation(tree, monkeypatch):
    with pytest.raises(SystemExit) as exc:
        main_home(tree, monkeypatch, "--init-state")
    assert exc.value.code == 2
    assert snapshot(tree[1]) == {}
