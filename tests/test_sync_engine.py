"""Shared sync scenarios use temporary roots and simulated sudo, never host state."""

from __future__ import annotations

import fcntl
import json
import os
import stat
import subprocess
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import pytest

import sync_engine as engine


def put(path, text="fixture"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


@pytest.fixture
def tree(tmp_path):
    repo, home, system = (tmp_path / name for name in ("repo", "home", "system"))
    for root in (repo, home, system):
        root.mkdir()
    return repo, home, system


def plan(tree, selected=None, **kwargs):
    repo, home, _ = tree
    return engine.plan_links(
        target="machine", home=home, repo=repo, selected=selected or {}, **kwargs
    )


def state(tree, entries, *, path=None, **changes):
    repo, home, _ = tree
    value = {
        "schema_version": 2,
        "mode": "sync",
        "home": str(home),
        "repo": str(repo),
        "roots": [],
        "target": "machine",
        "timestamp": "fixture",
        "symlinks": {str(dest): str(source) for dest, source in entries.items()},
    }
    value.update(changes)
    return put(path or home / ".local/state/nixos-configuration/sync-home.json", json.dumps(value))


def saved(proposal):
    return json.loads(proposal.state_path.read_text())["symlinks"]


def snapshot(root):
    return {
        str(path.relative_to(root)): (
            path.lstat().st_mode,
            os.readlink(path)
            if path.is_symlink()
            else path.read_bytes()
            if path.is_file()
            else None,
        )
        for path in root.rglob("*")
    }


def forbid(*args, **kwargs):
    pytest.fail("Unexpected mutation or subprocess")


def test_plan_and_unconfirmed_application_are_read_only(tree, monkeypatch):
    repo, home, system = tree
    source = put(repo / "source")
    before = snapshot(home), snapshot(system), snapshot(repo)
    monkeypatch.setattr(engine, "_persist", forbid)
    monkeypatch.setattr(engine, "_mutation_lock", forbid)
    monkeypatch.setattr(engine.subprocess, "run", forbid)
    proposal = plan(tree, {home / "tool": source, system / "config": source}, roots=(system,))
    assert proposal.roots == (system,)
    assert len(proposal.symlinks) == 2
    with pytest.raises(ValueError, match="confirmation"):
        engine.apply_sync(proposal)
    assert before == (snapshot(home), snapshot(system), snapshot(repo))


def test_home_and_extra_root_share_one_manifest(tree, monkeypatch):
    repo, home, system = tree
    source = put(repo / "source")
    monkeypatch.setattr(engine.subprocess, "run", forbid)
    proposal = plan(
        tree,
        {home / "tool": source, system / "config": source},
        roots=(system,),
        state_path=repo / ".sync-state.json",
    )
    result = engine.apply_sync(proposal, confirmed=True)
    assert result.ownership == {
        str(home / "tool"): str(source),
        str(system / "config"): str(source),
    }
    metadata = json.loads(proposal.state_path.read_text())
    assert metadata["schema_version"] == 2
    assert metadata["mode"] == "sync"
    assert metadata["roots"] == [str(system)]
    assert proposal.state_path.stat().st_uid == os.getuid()
    assert not plan(tree, {home / "tool": source}, state_path=home / "other-state").conflicts


@pytest.mark.parametrize(
    "changes",
    [
        {"schema_version": True},
        {"schema_version": 3},
        {"mode": "nixos"},
        {"home": "/other"},
        {"repo": "/other"},
        {"roots": ["/etc/nixos"]},
        {"symlinks": []},
        {"symlinks": {"a": None}},
        {"target": "../bad"},
    ],
)
def test_mismatched_metadata_rejected(tree, changes):
    state(tree, {}, **changes)
    with pytest.raises(ValueError, match="metadata"):
        plan(tree)


@pytest.mark.parametrize("raw", ["{", "null", "[]", "{}"])
def test_malformed_state_rejected(tree, raw):
    put(tree[1] / ".local/state/nixos-configuration/sync-home.json", raw)
    with pytest.raises(ValueError):
        plan(tree)


def test_schema_one_migrates_but_cannot_authorize_external_stale_links(tree):
    repo, home, system = tree
    source = put(repo / "source")
    (home / "old").symlink_to(source)
    (system / "old").symlink_to(source)
    state(tree, {home / "old": source, system / "old": source}, schema_version=1, mode="home-only")
    proposal = plan(tree, roots=(system,))
    assert len(proposal.warnings) == 1
    engine.apply_sync(proposal, confirmed=True)
    assert not (home / "old").is_symlink()
    assert (system / "old").is_symlink()
    assert saved(proposal) == {}


def test_legacy_repository_state_is_validated_and_migrated(tree):
    repo, home, system = tree
    source = put(repo / "source")
    (home / "old").symlink_to(source)
    (system / "old").symlink_to(source)
    manifest = put(
        repo / ".sync-state.json",
        json.dumps(
            {
                "machine": "machine",
                "timestamp": "then",
                "symlinks": {
                    str(home / "old"): str(source),
                    str(system / "old"): str(source),
                    "/etc/passwd": str(source),
                    str(home / "bad"): "/etc/passwd",
                },
            }
        ),
    )
    proposal = plan(tree, state_path=manifest, roots=(system,))
    assert len(proposal.warnings) == 2
    engine.apply_sync(proposal, confirmed=True)
    assert not (system / "old").is_symlink()
    assert saved(proposal) == {}
    assert json.loads(manifest.read_text())["mode"] == "sync"
    put(
        home / "legacy.json",
        json.dumps({"machine": "machine", "timestamp": "then", "symlinks": {}}),
    )
    with pytest.raises(ValueError):
        plan(tree, state_path=home / "legacy.json")


def test_root_mismatch_cannot_delete(tree):
    repo, home, system = tree
    source = put(repo / "source")
    (system / "old").symlink_to(source)
    state(tree, {system / "old": source}, roots=[str(system)])
    with pytest.raises(ValueError, match="metadata"):
        plan(tree)
    assert (system / "old").is_symlink()


@pytest.mark.parametrize("location", ["state", "lock", "worker-lock", "worker-request", "parent"])
@pytest.mark.parametrize("in_repo", [False, True])
def test_control_symlinks_rejected(tree, location, in_repo):
    repo, home, system = tree
    root = repo if in_repo else home
    destination = root / "control/state.json"
    destination.parent.mkdir()
    if location == "parent":
        destination.parent.rmdir()
        destination.parent.symlink_to(system)
    else:
        put(system / "foreign", "{}")
        path = (
            destination if location == "state" else destination.with_name("state.json." + location)
        )
        path.symlink_to(system / "foreign")
    with pytest.raises(ValueError):
        plan(tree, state_path=destination)


def test_state_must_be_in_home_or_repository_and_not_hardlinked(tree, tmp_path):
    repo, home, _ = tree
    for path in (tmp_path / "state", Path("state"), home / ".." / "state"):
        with pytest.raises(ValueError):
            plan(tree, state_path=path)
    original = put(repo / "original", "{}")
    os.link(original, repo / "state")
    with pytest.raises(ValueError):
        plan(tree, state_path=repo / "state")


def test_invalid_destinations_and_sources_never_followed(tree):
    repo, home, system = tree
    source = put(repo / "source")
    (home / ".config").symlink_to(system)
    state(
        tree,
        {
            "relative": source,
            str(home) + "/a/../b": source,
            system / "outside": source,
            home / "bad": "/etc/passwd",
            home / ".config/old": source,
        },
    )
    proposal = plan(tree, {home / ".config/tool": source})
    assert len(proposal.warnings) == 5
    assert proposal.operations[-1].protection == "unsafe parent"
    engine.apply_sync(proposal, confirmed=True)
    assert snapshot(system) == {}
    for selected in ({system / "out": source}, {home / "bad": Path("/etc/passwd")}):
        with pytest.raises(ValueError):
            plan(tree, selected)
    (repo / "escape").symlink_to(system)
    with pytest.raises(ValueError):
        plan(tree, {home / "bad": repo / "escape/file"})


def test_protection_applies_to_selection_stale_and_ancestor_cleanup(tree):
    repo, home, _ = tree
    source = put(repo / "source")
    protected = home / ".config/private/file"
    protected.parent.mkdir(parents=True)
    protected.symlink_to(source)
    stale = home / ".config/old"
    stale.symlink_to(source)
    state(tree, {protected: source, stale: source})
    proposal = plan(
        tree,
        {home / ".config": source, protected: source},
        exclusions=(".config/private",),
        force=True,
    )
    engine.apply_sync(proposal, confirmed=True)
    assert protected.is_symlink()
    assert not stale.is_symlink()
    assert (home / ".config").is_dir()
    assert saved(proposal) == {}


def test_control_paths_reserved_even_outside_home(tree):
    repo, _, _ = tree
    source = put(repo / "source")
    manifest = repo / "control/state"
    proposal = plan(
        tree, {repo / "control": source, manifest: source}, state_path=manifest, roots=(repo,)
    )
    assert all(op.action == "protected" for op in proposal.operations)
    engine.apply_sync(proposal, confirmed=True)
    assert manifest.is_file() and not manifest.is_symlink()


def test_control_directory_cleanup_stops_at_repo_state(tree):
    repo, _, _ = tree
    source = put(repo / "source")
    stale = repo / "control/nested/old"
    stale.parent.mkdir(parents=True)
    stale.symlink_to(source)
    manifest = state(tree, {stale: source}, path=repo / "control/state", roots=[str(repo)])
    proposal = plan(tree, state_path=manifest, roots=(repo,))
    engine.apply_sync(proposal, confirmed=True)
    assert not stale.is_symlink()
    assert not stale.parent.exists()
    assert manifest.parent.is_dir() and manifest.is_file()
    # Even an explicitly authorized repository root cannot select its manifest or lock.
    guarded = plan(
        tree,
        dict.fromkeys(engine._control_paths(manifest), source),
        state_path=manifest,
        roots=(repo,),
    )
    assert all(op.action == "protected" for op in guarded.operations)


def test_same_source_kept_owned_replaced_and_dangling_conflicts(tree):
    repo, home, _ = tree
    desired, old = put(repo / "desired"), put(repo / "old")
    for name in ("owned", "unowned", "modified", "dangling", "same"):
        (home / name).symlink_to(
            desired if name == "same" else repo / "missing" if name == "dangling" else old
        )
    state(
        tree, {home / "owned": old, home / "modified": desired, home / "dangling": repo / "missing"}
    )
    proposal = plan(
        tree,
        {home / name: desired for name in ("owned", "unowned", "modified", "dangling", "same")},
    )
    actions = {op.destination.name: op.action for op in proposal.operations}
    assert actions == {
        "owned": "replace",
        "unowned": "skip",
        "modified": "skip",
        "dangling": "skip",
        "same": "keep",
    }
    result = engine.apply_sync(proposal, confirmed=True)
    assert not result.complete
    assert (home / "owned").readlink() == desired
    assert (home / "dangling").readlink() == repo / "missing"
    assert saved(proposal) == {
        str(home / "owned"): str(desired),
        str(home / "same"): str(desired),
        str(home / "dangling"): str(repo / "missing"),
    }


def test_changed_stale_and_unvisited_ownership_partial_progress(tree, monkeypatch):
    repo, home, _ = tree
    desired, old = put(repo / "desired"), put(repo / "old")
    for name in ("stale", "modified", "c"):
        (home / name).symlink_to(old)
    state(tree, {home / name: old for name in ("stale", "modified", "c")})
    (home / "modified").unlink()
    put(home / "modified", "user data")
    proposal = plan(tree, {home / name: desired for name in ("a", "b", "c")})
    original = engine.os.symlink

    def fail_second(source, destination, **kwargs):
        if destination == "b":
            raise OSError("second link failure")
        return original(source, destination, **kwargs)

    monkeypatch.setattr(engine.os, "symlink", fail_second)
    with pytest.raises(OSError, match="second link"):
        engine.apply_sync(proposal, confirmed=True)
    assert not (home / "stale").is_symlink()
    assert (home / "modified").read_text() == "user data"
    assert saved(proposal) == {str(home / "a"): str(desired), str(home / "c"): str(old)}


@pytest.mark.parametrize("symlink", [True, False])
def test_force_backs_up_exact_non_directory(tree, symlink):
    repo, home, _ = tree
    source = put(repo / "source")
    dest = home / "tool"
    if symlink:
        dest.symlink_to("missing-relative")
    else:
        put(dest, "original").chmod(0o640)
    identity = dest.lstat().st_ino
    result = engine.apply_sync(plan(tree, {dest: source}, force=True), confirmed=True)
    assert dest.readlink() == source
    assert result.complete
    (backup,) = result.backups
    assert backup.lstat().st_ino == identity
    if symlink:
        assert backup.readlink() == Path("missing-relative")
    else:
        assert backup.read_text() == "original" and stat.S_IMODE(backup.stat().st_mode) == 0o640


def test_force_directory_and_changed_object_preserved(tree):
    repo, home, _ = tree
    source = put(repo / "source")
    dest = put(home / "directory/keep")
    result = engine.apply_sync(plan(tree, {dest.parent: source}, force=True), confirmed=True)
    assert not result.backups and dest.exists()
    put(home / "file", "before")
    proposal = plan(tree, {home / "file": source}, force=True)
    put(home / "file", "after")
    result = engine.apply_sync(proposal, confirmed=True)
    assert not result.backups and (home / "file").read_text() == "after"


def test_plan_changes_parent_source_and_object_are_rechecked(tree):
    repo, home, system = tree
    source = put(repo / "source")
    proposal = plan(tree, {home / ".config/tool": source, home / "tool": source})
    (home / ".config").symlink_to(system)
    put(home / "tool", "user data")
    result = engine.apply_sync(proposal, confirmed=True)
    assert result.warnings and snapshot(system) == {}
    assert (home / "tool").read_text() == "user data"
    proposal = plan(tree, {home / "unavailable": source})
    source.unlink()
    result = engine.apply_sync(proposal, confirmed=True)
    assert not (home / "unavailable").is_symlink()
    assert any("unavailable" in warning for warning in result.warnings)


def test_state_review_and_lock_are_enforced(tree, monkeypatch):
    proposal = plan(tree)
    state(tree, {})
    with pytest.raises(ValueError, match="changed after planning"):
        engine.apply_sync(proposal, confirmed=True)
    proposal = plan(tree)
    original = engine._persist
    seen = []

    def check_lock(plan, ownership):
        for lock in engine._control_paths(plan.state_path)[1:3]:
            with lock.open("r+") as other:
                with pytest.raises(BlockingIOError):
                    fcntl.flock(other.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        seen.append(True)
        original(plan, ownership)

    monkeypatch.setattr(engine, "_persist", check_lock)
    engine.apply_sync(proposal, confirmed=True)
    assert seen


def test_lock_wait_is_bounded(tree, monkeypatch):
    proposal = plan(tree)
    lock = proposal.state_path.with_name(proposal.state_path.name + ".lock")
    put(lock)
    monkeypatch.setattr(engine, "LOCK_TIMEOUT", 0)
    with lock.open("r+") as holder:
        fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
        with pytest.raises(TimeoutError):
            engine.apply_sync(proposal, confirmed=True)


def test_directory_migration_runs_deep_stale_first(tree):
    repo, home, _ = tree
    old = put(repo / "old/SKILL.md").parent
    desired = put(repo / "desired/SKILL.md").parent
    leaf = home / ".claude/skills/example"
    leaf.parent.mkdir(parents=True)
    leaf.symlink_to(old)
    state(tree, {leaf: old})
    proposal = plan(
        tree,
        {
            home / ".agents/skills/example": desired,
            home / ".claude/skills": home / ".agents/skills",
        },
    )
    assert proposal.operations[0].action == "remove"
    engine.apply_sync(proposal, confirmed=True)
    assert (home / ".claude/skills").readlink() == home / ".agents/skills"
    assert (desired / "SKILL.md").exists()
    poisonous = state(tree, {leaf / "SKILL.md": desired / "SKILL.md"})
    again = plan(tree, {home / ".claude/skills": home / ".agents/skills"})
    engine.apply_sync(again, confirmed=True)
    assert poisonous.exists() and (desired / "SKILL.md").exists()


def test_migration_preserves_unowned_leaf(tree):
    repo, home, _ = tree
    old = put(repo / "old")
    leaf = home / ".claude/skills/owned"
    leaf.parent.mkdir(parents=True)
    leaf.symlink_to(old)
    put(leaf.parent / "unowned")
    state(tree, {leaf: old})
    result = engine.apply_sync(
        plan(tree, {leaf.parent: home / ".agents/skills"}, force=True), confirmed=True
    )
    assert not result.backups and (leaf.parent / "unowned").exists()


def sudo_simulator(monkeypatch, *, failure=None):
    original = engine._mutate_operation
    calls = []

    def denied(op, **kwargs):
        raise PermissionError("simulated destination write denial")

    def runner(argv, **kwargs):
        calls.append((argv, kwargs))
        request = json.loads(kwargs["input"])
        with monkeypatch.context() as patch:
            patch.setattr(engine, "_mutate_operation", original)
            if failure is not None:
                patch.setattr(engine.os, "symlink", failure)
            response = engine._process_worker(request, requester_uid=os.getuid())
        return SimpleNamespace(
            stdout=json.dumps(response), stderr="", returncode=0 if response["ok"] else 1
        )

    monkeypatch.setattr(engine, "_mutate_operation", denied)
    monkeypatch.setattr(engine.subprocess, "run", runner)
    return calls


def test_sudo_runs_only_after_external_permission_error(tree, monkeypatch):
    repo, _, system = tree
    source = put(repo / "source")
    proposal = plan(tree, {system / "config": source}, roots=(system,))
    calls = sudo_simulator(monkeypatch)
    result = engine.apply_sync(proposal, confirmed=True)
    assert result.ownership == {str(system / "config"): str(source)}
    argv, kwargs = calls[0]
    assert argv[:3] == ["sudo", "--", engine.sys.executable]
    assert argv[-1] == "--worker" and "-I" in argv
    assert kwargs["timeout"] == engine.WORKER_TIMEOUT
    assert kwargs.get("shell") is not True
    assert proposal.state_path.stat().st_uid == os.getuid()


def test_home_permission_denied_never_escalates(tree, monkeypatch):
    source = put(tree[0] / "source")
    sudo_simulator(monkeypatch)
    monkeypatch.setattr(engine.subprocess, "run", forbid)
    with pytest.raises(PermissionError):
        engine.apply_sync(plan(tree, {tree[1] / "tool": source}), confirmed=True)


def test_manifest_permission_failure_never_escalates(tree, monkeypatch):
    repo, _, system = tree
    source = put(repo / "source")
    proposal = plan(tree, {system / "config": source}, roots=(system,))
    original = engine._persist
    calls = 0

    def denied(plan, ownership):
        nonlocal calls
        calls += 1
        if calls > 1:
            raise PermissionError("state denied")
        original(plan, ownership)

    monkeypatch.setattr(engine, "_persist", denied)
    monkeypatch.setattr(engine.subprocess, "run", forbid)
    with pytest.raises(engine._PersistenceError):
        engine.apply_sync(proposal, confirmed=True)


def test_worker_failure_after_backup_drops_ownership_and_preserves_backup(tree, monkeypatch):
    repo, _, system = tree
    source = put(repo / "source")
    put(system / "config", "user data")
    proposal = plan(tree, {system / "config": source}, roots=(system,), force=True)

    def fail(*args, **kwargs):
        raise OSError("worker link failed")

    calls = sudo_simulator(monkeypatch, failure=fail)
    with pytest.raises(engine.SyncWorkerError, match="worker link failed"):
        engine.apply_sync(proposal, confirmed=True)
    assert len(calls) == 1 and saved(proposal) == {}
    assert not (system / "config").exists()
    (backup,) = system.glob("config.sync-backup-*")
    assert backup.read_text() == "user data"


@pytest.mark.parametrize("failure", ["timeout", "invalid", "exit"])
def test_worker_unknown_failure_is_explicit(tree, monkeypatch, failure):
    repo, _, system = tree
    source = put(repo / "source")
    proposal = plan(tree, {system / "config": source}, roots=(system,))
    sudo_simulator(monkeypatch)

    def runner(argv, **kwargs):
        if failure == "timeout":
            raise subprocess.TimeoutExpired(argv, kwargs["timeout"])
        return SimpleNamespace(
            stdout="{}" if failure == "invalid" else "", stderr="sudo denied", returncode=1
        )

    monkeypatch.setattr(engine.subprocess, "run", runner)
    with pytest.raises(engine.SyncWorkerError):
        engine.apply_sync(proposal, confirmed=True)
    assert saved(proposal) == {}


@pytest.mark.parametrize("change", ["home", "outside", "source", "uid", "identity", "parent"])
def test_worker_revalidates_structured_request(tree, change):
    repo, home, system = tree
    source = put(repo / "source")
    destination = system / "nested/config"
    proposal = plan(tree, {destination: source}, roots=(system,))
    request = engine._worker_request(proposal, proposal.operations[0])
    if change == "home":
        request["operation"]["destination"] = str(home / "bad")
    elif change == "outside":
        request["operation"]["destination"] = str(system.parent / "bad")
    elif change == "source":
        request["operation"]["desired_source"] = "/etc/passwd"
    elif change == "uid":
        request["uid"] += 1
    elif change == "identity":
        request["operation"]["identity"] = [1, True, 2, 3, 4]
    else:
        (system / "nested").symlink_to(home)
    with engine._mutation_lock(proposal), engine._worker_lease(proposal):
        engine._persist(proposal, {})
        engine._publish_request(proposal, request)
    response = engine._process_worker(request, requester_uid=os.getuid())
    assert not response["ok"]
    assert {
        "home": "cannot modify home destinations",
        "outside": "outside authorized roots",
        "source": "Path is not canonical beneath",
        "uid": "Invalid sync worker request",
        "identity": "Invalid sync worker operation",
        "parent": "Unsafe parent directory",
    }[change] in response["error"]
    assert not response["changed"]
    assert not destination.is_symlink()
    assert not (home / "config").exists()


def test_worker_timeout_after_creation_does_not_claim_ownership(tree, monkeypatch):
    repo, _, system = tree
    source = put(repo / "source")
    destination = system / "config"
    proposal = plan(tree, {destination: source}, roots=(system,))
    sudo_simulator(monkeypatch)

    def runner(argv, **kwargs):
        destination.symlink_to(source)
        raise subprocess.TimeoutExpired(argv, kwargs["timeout"])

    monkeypatch.setattr(engine.subprocess, "run", runner)
    with pytest.raises(engine.SyncWorkerError, match="partially changed"):
        engine.apply_sync(proposal, confirmed=True)
    assert destination.readlink() == source
    assert saved(proposal) == {}


def test_worker_nonzero_after_creation_does_not_claim_ownership(tree, monkeypatch):
    repo, _, system = tree
    source = put(repo / "source")
    proposal = plan(tree, {system / "config": source}, roots=(system,))
    sudo_simulator(monkeypatch)
    original = engine.subprocess.run

    def runner(argv, **kwargs):
        result = original(argv, **kwargs)
        result.returncode = 1
        result.stderr = "injected unsuccessful exit"
        return result

    monkeypatch.setattr(engine.subprocess, "run", runner)
    with pytest.raises(engine.SyncWorkerError, match="unsuccessful exit"):
        engine.apply_sync(proposal, confirmed=True)
    assert (system / "config").is_symlink()
    assert saved(proposal) == {}


def test_unavailable_new_source_retains_previous_ownership(tree):
    repo, home, _ = tree
    old, desired = put(repo / "old"), put(repo / "desired")
    destination = home / "tool"
    destination.symlink_to(old)
    state(tree, {destination: old})
    proposal = plan(tree, {destination: desired})
    desired.unlink()
    result = engine.apply_sync(proposal, confirmed=True)
    assert result.warnings
    assert saved(proposal) == {str(destination): str(old)}


def test_worker_preserves_changed_object_after_planning(tree):
    repo, _, system = tree
    source = put(repo / "source")
    destination = put(system / "config", "before")
    proposal = plan(tree, {destination: source}, roots=(system,), force=True)
    put(destination, "after")
    request = engine._worker_request(proposal, proposal.operations[0])
    with engine._mutation_lock(proposal), engine._worker_lease(proposal):
        engine._persist(proposal, {})
        engine._publish_request(proposal, request)
    response = engine._process_worker(request, requester_uid=os.getuid())
    assert response["ok"] and response["warnings"] and not response["backups"]
    assert destination.read_text() == "after"


def test_root_owned_parent_allowed_only_outside_home(tree, monkeypatch):
    repo, home, system = tree
    source = put(repo / "source")
    (home / "nested").mkdir()
    (system / "nested").mkdir()
    original = Path.lstat
    uid = os.getuid()
    # Simulate a non-root current user when the test suite itself runs as root.
    fake_uid = uid if uid != 0 else 12345

    def info(path, *args, **kwargs):
        result = original(path, *args, **kwargs)
        values = {
            name: getattr(result, name)
            for name in (
                "st_mode",
                "st_uid",
                "st_dev",
                "st_ino",
                "st_size",
                "st_mtime_ns",
                "st_nlink",
            )
        }
        if path.is_relative_to(home) or path.is_relative_to(repo) or path.is_relative_to(system):
            values["st_uid"] = fake_uid
        if path in (home / "nested", system / "nested"):
            values["st_uid"] = 0
        return SimpleNamespace(**values)

    monkeypatch.setattr(engine.os, "getuid", lambda: fake_uid)
    monkeypatch.setattr(Path, "lstat", info)
    engine._check_parents(system / "nested/config", home, roots=(system,))
    with pytest.raises(ValueError, match="Unsafe parent"):
        engine._check_parents(home / "nested/config", home, roots=(home, system))
    monkeypatch.setattr(engine.subprocess, "run", forbid)
    proposal = plan(tree, {home / "nested/tool": source})
    assert proposal.operations[0].action == "skip"


def test_foreign_parent_never_escalates(tree, monkeypatch):
    repo, home, system = tree
    source = put(repo / "source")
    (system / "nested").mkdir()
    proposal = plan(tree, {system / "nested/config": source}, roots=(system,))
    original = engine._safe_directory

    def foreign(info, current, boundary, uid, **kwargs):
        if current == system / "nested":
            raise ValueError("Foreign parent directory")
        return original(info, current, boundary, uid, **kwargs)

    monkeypatch.setattr(engine, "_safe_directory", foreign)
    monkeypatch.setattr(engine.subprocess, "run", forbid)
    result = engine.apply_sync(proposal, confirmed=True)
    assert result.warnings and not (system / "nested/config").exists()


def test_operation_checks_identity_after_opening_parent(tree, monkeypatch):
    repo, home, _ = tree
    source = put(repo / "source")
    destination = put(home / "tool", "before")
    proposal = plan(tree, {destination: source}, force=True)
    changed = replace(proposal.operations[0], identity=(0, 0, 0, 0, 0))
    proposal = replace(proposal, operations=(changed,))
    result = engine.apply_sync(proposal, confirmed=True)
    assert result.warnings and not result.backups
    assert destination.read_text() == "before"


@pytest.mark.parametrize("suffix", ["worker-lock", "worker-request"])
@pytest.mark.parametrize("kind", ["directory", "hardlink", "foreign"])
def test_worker_controls_refuse_unsafe_objects(tree, monkeypatch, suffix, kind):
    proposal = plan(tree)
    path = proposal.state_path.with_name(proposal.state_path.name + "." + suffix)
    path.parent.mkdir(parents=True)
    if kind == "directory":
        path.mkdir()
    else:
        path.write_text("control")
        if kind == "hardlink":
            os.link(path, path.with_name("second-link"))
        else:
            original = Path.lstat

            def foreign(current, *args, **kwargs):
                result = original(current, *args, **kwargs)
                if current == path:
                    return SimpleNamespace(
                        st_mode=result.st_mode, st_uid=os.getuid() + 1, st_nlink=1
                    )
                return result

            monkeypatch.setattr(Path, "lstat", foreign)
    with pytest.raises(ValueError):
        plan(tree)


def test_worker_only_reads_user_created_control_files(tree, monkeypatch):
    repo, _, system = tree
    source = put(repo / "source")
    proposal = plan(tree, {system / "config": source}, roots=(system,))
    request = engine._worker_request(proposal, proposal.operations[0])
    with engine._mutation_lock(proposal), engine._worker_lease(proposal):
        engine._persist(proposal, {})
        engine._publish_request(proposal, request)
    controls = engine._control_paths(proposal.state_path)
    before = {
        path: (path.stat().st_ino, path.stat().st_uid, path.stat().st_mode) for path in controls
    }
    original = os.open
    reads = []

    def readonly(path, flags, *args, **kwargs):
        if str(path) in {item.name for item in controls}:
            assert not flags & (os.O_CREAT | os.O_WRONLY | os.O_RDWR | os.O_TRUNC)
            reads.append(str(path))
        return original(path, flags, *args, **kwargs)

    with monkeypatch.context() as patch:
        patch.setattr(engine.os, "open", readonly)
        for name in ("chmod", "chown", "fchmod", "fchown"):
            patch.setattr(engine.os, name, forbid)
        response = engine._process_worker(request, requester_uid=os.getuid())
    assert response["ok"] and controls[2].name in reads
    assert before == {
        path: (path.stat().st_ino, path.stat().st_uid, path.stat().st_mode) for path in controls
    }


@pytest.mark.parametrize("change", ["epoch", "request", "state", "expired"])
def test_worker_authorization_refuses_stale_request(tree, change):
    repo, _, system = tree
    source = put(repo / "source")
    proposal = plan(tree, {system / "config": source}, roots=(system,))
    request = engine._worker_request(proposal, proposal.operations[0])
    with engine._mutation_lock(proposal), engine._worker_lease(proposal):
        engine._persist(proposal, {})
        engine._publish_request(proposal, request)
        if change == "state":
            engine._persist(proposal, {"changed": "state"})
        elif change == "expired":
            path = engine._control_paths(proposal.state_path)[3]
            record = json.loads(path.read_text())
            record["deadline"] = 0
            engine._request_record(proposal, record)
    if change == "epoch":
        request["epoch"] = "0" * 32
    elif change == "request":
        request["operation"]["destination"] = str(system / "other")
    response = engine._process_worker(request, requester_uid=os.getuid())
    assert not response["ok"] and "Stale sync worker request" in response["error"]
    assert not (system / "config").is_symlink()
