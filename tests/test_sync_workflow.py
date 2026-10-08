from contextlib import contextmanager
from dataclasses import dataclass, replace
from pathlib import Path
from types import SimpleNamespace

import pytest

import sync_workflow as workflow


def write(path, content="fixture"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    return path


@pytest.fixture
def tree(tmp_path):
    repo, home, system = tmp_path / "repo", tmp_path / "home", tmp_path / "system"
    home.mkdir()
    for layer in ("common-z", "common-a", "machine"):
        write(repo / layer / "configuration.nix")
        write(repo / layer / "dotfiles/.config/tool", layer)
    write(repo / "common-z/dotfiles/.agents/skills/shared/SKILL.md")
    write(repo / "common-z/dotfiles/.agents/skills/shared/.work-compatible")
    write(repo / "common-z/dotfiles/.agents/skills/work/SKILL.md")
    write(repo / "common-z/dotfiles/.agents/skills/work/.work-compatible")
    write(repo / "machine/dotfiles/.agents/skills/shared/SKILL.md")
    write(repo / "machine/dotfiles/.agents/skills/machine/SKILL.md")
    write(repo / "machine/dotfiles/.agents/skills/machine/.work-compatible")
    write(repo / "common-z/dotfiles/.claude-plugins/plugin/.claude-plugin/plugin.json", "{}")
    write(repo / "machine/dotfiles/.claude-plugins/plugin/.claude-plugin/plugin.json", "{}")
    write(repo / "steel-cogs/forest/cog.scm")
    write(repo / "steel-cogs/incomplete/README.md")
    write(repo / "common-z/dotfiles/.claude/CLAUDE.md")
    return repo, home, system


def test_optional_system_extension_preserves_identical_home_inventory(tree):
    repo, home, system = tree
    layers = ("common-z", "common-a", "machine")
    personal, overrides = workflow.collect_links(repo, home, layers)
    combined, combined_overrides = workflow.collect_links(repo, home, layers, nixos_root=system)
    assert {
        path: source for path, source in combined.items() if path.is_relative_to(home)
    } == personal
    assert combined_overrides == overrides
    assert combined[system / "configuration.nix"] == repo / "machine/configuration.nix"
    for layer in layers:
        assert combined[system / layer / "configuration.nix"] == repo / layer / "configuration.nix"
    assert not any(
        "dotfiles" in path.relative_to(system).parts
        for path in combined
        if path.is_relative_to(system)
    )
    assert personal[home / ".config/tool"] == repo / "machine/dotfiles/.config/tool"
    assert personal[home / ".claude/skills"] == home / ".agents/skills"
    assert (
        personal[home / ".agents/skills/shared"] == repo / "machine/dotfiles/.agents/skills/shared"
    )
    assert home / ".claude-work/skills/shared" not in personal
    for name, layer in (("work", "common-z"), ("machine", "machine")):
        assert (
            personal[home / ".claude-work/skills" / name]
            == repo / layer / "dotfiles/.agents/skills" / name
        )
    assert (
        personal[home / ".local/share/claude-plugins/plugin"]
        == repo / "machine/dotfiles/.claude-plugins/plugin"
    )
    assert personal[home / ".config/steel/cogs/forest"] == repo / "steel-cogs/forest"
    assert not any(
        path.name in {"SKILL.md", ".work-compatible", "plugin.json"} for path in personal
    )
    assert not any("incomplete" in path.parts for path in personal)
    assert list(personal) == sorted(personal)


def test_ordered_layers_are_not_resorted_and_machine_is_applied_once(tree):
    repo, home, _ = tree
    links, overrides = workflow.collect_links(
        repo, home, ("machine", "common-z", "common-a", "machine")
    )
    tool_overrides = [item for item in overrides if item[0] == home / ".config/tool"]
    assert [(old.parts[-4], new.parts[-4]) for _, old, new in tool_overrides] == [
        ("common-z", "common-a"),
        ("common-a", "machine"),
    ]
    assert links[home / ".config/tool"] == repo / "machine/dotfiles/.config/tool"


def test_legacy_file_builder_retains_sorted_allowed_layers_and_missing_machine(tree):
    repo, home, _ = tree
    links = dict(workflow.build_symlink_list(repo, home, "missing", ["common-z", "common-a"], True))
    assert links[home / ".config/tool"] == repo / "common-z/dotfiles/.config/tool"
    assert home / ".claude/CLAUDE.md" in links
    assert not any(".agents" in path.parts or ".claude-plugins" in path.parts for path in links)
    assert (
        dict(workflow.build_symlink_list(repo, home, "machine", ["machine", "common-z"], True))[
            home / ".config/tool"
        ]
        == repo / "machine/dotfiles/.config/tool"
    )
    with pytest.raises(FileNotFoundError):
        workflow.build_symlink_list(repo / "absent", home, "machine", [])


@pytest.mark.parametrize(
    "builder,marker",
    [
        (workflow.build_skill_symlinks, "SKILL.md"),
        (workflow.build_work_skill_symlinks, "SKILL.md"),
        (workflow.build_cog_symlinks, "cog.scm"),
    ],
)
def test_directory_builders_are_sorted_and_skip_incomplete(tmp_path, builder, marker):
    source, target = tmp_path / "source", tmp_path / "target"
    for name in ("z", "a"):
        write(source / name / marker)
        write(source / name / ".work-compatible")
    write(source / "incomplete/readme")
    assert builder(source, target) == [(target / name, source / name) for name in ("a", "z")]
    assert builder(source / "absent", target) == []


@pytest.mark.parametrize(
    "builder,subpath,marker",
    [
        (workflow.build_layered_skill_symlinks, ".agents/skills", "SKILL.md"),
        (workflow.build_layered_plugin_symlinks, ".claude-plugins", ".claude-plugin/plugin.json"),
    ],
)
def test_layered_directory_builders_machine_last(tmp_path, builder, subpath, marker):
    repo, target = tmp_path / "repo", tmp_path / "target"
    for layer in ("machine", "common-z", "common-a"):
        write(repo / layer / "dotfiles" / subpath / "same" / marker)
    assert builder(repo, target, "machine", ["machine", "common-z", "common-a", "common-z"]) == [
        (target / "same", repo / "machine/dotfiles" / subpath / "same")
    ]


@pytest.mark.parametrize("name", ["../machine", "/machine", "machine/child", "", "machine\x00"])
def test_selection_rejects_unsafe_names(tree, name):
    repo, home, _ = tree
    with pytest.raises(ValueError, match="Unsafe sync layer"):
        workflow.collect_links(repo, home, (name,))


def test_selection_accepts_dotfiles_only_and_json_only_targets(tree):
    repo, home, _ = tree
    write(repo / "dotfile/dotfiles/.tool")
    write(repo / "manifest/sync.json", "{}")
    links, _ = workflow.collect_links(repo, home, ("dotfile", "manifest"))
    assert home / ".tool" in links
    with pytest.raises(ValueError, match="Unknown sync layer"):
        workflow.collect_links(repo, home, ("steel-cogs",))
    with pytest.raises(ValueError, match="at least one"):
        workflow.collect_links(repo, home, ())
    with pytest.raises(FileNotFoundError, match="Configuration file"):
        workflow.collect_links(repo, home, ("manifest",), nixos_root=tree[2])
    with pytest.raises(ValueError, match="must not overlap"):
        workflow.collect_links(repo, home, ("machine",), nixos_root=home / "system")


def test_sources_are_canonical_and_cannot_escape_repo(tree, tmp_path):
    repo, home, _ = tree
    outside = write(tmp_path / "outside/SKILL.md").parent
    skill = repo / "machine/dotfiles/.agents/skills/escape"
    skill.symlink_to(outside, target_is_directory=True)
    with pytest.raises(ValueError, match="Source escapes repository"):
        workflow.collect_links(repo, home, ("machine",))
    skill.unlink()
    skill.symlink_to(repo / "common-z/dotfiles/.agents/skills/work", target_is_directory=True)
    alias = tmp_path / "repo-alias"
    alias.symlink_to(repo, target_is_directory=True)
    links, _ = workflow.collect_links(alias, home, ("machine",))
    assert links[home / ".agents/skills/escape"] == repo / "common-z/dotfiles/.agents/skills/work"
    assert all(
        source == source.resolve()
        for destination, source in links.items()
        if destination != home / ".claude/skills"
    )
    (repo / "layer-alias").symlink_to(repo / "machine", target_is_directory=True)
    with pytest.raises(ValueError, match="Unknown sync layer"):
        workflow.collect_links(repo, home, ("layer-alias",))


@dataclass(frozen=True)
class Operation:
    destination: Path
    desired_source: Path | None
    action: str = "create"
    conflict: str | None = None
    protection: str | None = None
    identity: tuple = ()


def plan_for(tree, operations=(), **kwargs):
    repo, home, system = tree
    values = dict(
        target="machine",
        home=home,
        repo=repo,
        layers=("common-z", "common-a", "machine"),
        exclusions=(),
        operations=tuple(operations),
        overrides=(),
        warnings=(),
        roots=(home, system),
    )
    values.update(kwargs)
    return SimpleNamespace(**values)


def selected_plan(tree, *, system=False):
    repo, home, root = tree
    selected, overrides = workflow.collect_links(
        repo, home, ("common-z", "common-a", "machine"), nixos_root=root if system else None
    )
    return plan_for(
        tree, [Operation(path, source) for path, source in selected.items()], overrides=overrides
    )


def test_view_has_legacy_categories_relative_paths_and_optional_system(tree):
    plan = selected_plan(tree)
    text = workflow.describe_sync_plan(plan)
    for title in (
        "Dotfiles",
        "Agent skills (personal)",
        "Claude Code personal wiring",
        "Claude Code skills (work)",
        "Claude Code plugins",
        "Steel cogs",
    ):
        assert title in text
    for group in ("agents-skills", "claude-skills", "claude-plugins", "steel-cogs", "machine"):
        assert f"  {group} (" in text
    assert "Imported layers: common-z common-a\n" in text
    assert "~/.config/tool [create]" in text
    assert "~/.claude/skills -> ~/.agents/skills [create]" in text
    assert "NixOS configuration" not in text
    assert "Layer overrides" in text
    assert str(plan.home) not in text and str(plan.repo) not in text
    assert "NixOS configuration" in workflow.describe_sync_plan(selected_plan(tree, system=True))
    kept = plan_for(tree, [replace(op, action="keep") for op in plan.operations])
    kept_text = workflow.describe_sync_plan(kept)
    assert "keep:" not in kept_text and "[keep]" not in kept_text
    assert "~/.config/tool\n" in kept_text


def test_exclusions_conflicts_stale_protection_overrides_and_extensions(tree):
    repo, home, _ = tree
    source = repo / "machine/dotfiles/.config/tool"
    plan = plan_for(
        tree,
        [
            Operation(home / ".secret", source, "protected", protection="exclusion"),
            Operation(home / ".config/keep", source, "skip", "existing directory"),
            Operation(home / ".config/backup", source, "backup", "unowned file"),
            Operation(home / "unsafe/child", source, "skip", "redirected parent", "unsafe parent"),
            Operation(home / ".old", None, "remove"),
            Operation(home / ".old-modified", None, "skip", "stale object changed"),
        ],
        exclusions=(".secret", ".config/private"),
        warnings=(f"Preserve modified object: {home / '.changed'}",),
        overrides=((home / ".config/tool", repo / "common-a/dotfiles/.config/tool", source),),
    )
    section = workflow.Section(
        "Terminal integration", (f"{home}/.config/terminal/machine",), "generated"
    )
    text = workflow.describe_sync_plan(
        plan, extra_sections=(section,), footer=("Startup remains disabled.",)
    )
    inventory, exclusions = text.split("Exclusions", 1)
    assert ".secret" not in inventory and ".config/private" not in inventory
    assert "~/.secret (protected: exclusion)" in exclusions
    assert "~/.config/keep: existing directory (skipped; left untouched)" in text
    assert "~/.config/backup: unowned file (back up and replace)" in text
    assert "protected: unsafe parent" in text
    assert "Stale symlinks to remove (1):\n  ~/.old" in text
    assert "~/.old-modified: stale object changed (skipped; left untouched)" in text
    assert "~/.config/tool: common-a -> machine" in text
    assert "Terminal integration (1):\n  generated (1):\n    ~/.config/terminal/machine" in text
    assert text.endswith("Startup remains disabled.")
    assert "~/.changed" in text
    assert str(home) not in text and str(repo) not in text


@pytest.mark.parametrize(
    "tty_enabled,no_color,enabled",
    [(False, False, False), (True, False, True), (True, True, False), (False, True, False)],
)
def test_colors_follow_stdout_tty_and_no_color(monkeypatch, tty_enabled, no_color, enabled):
    monkeypatch.setattr(workflow.sys.stdout, "isatty", lambda: tty_enabled)
    if no_color:
        monkeypatch.setenv("NO_COLOR", "")
    else:
        monkeypatch.delenv("NO_COLOR", raising=False)
    assert workflow._color_enabled() is enabled
    for formatter, code in (
        (workflow.bold, "1"),
        (workflow.green, "32"),
        (workflow.yellow, "33"),
        (workflow.red, "31"),
        (workflow.cyan, "36"),
        (workflow.dim, "2"),
    ):
        assert formatter("text") == (f"\033[{code}mtext\033[0m" if enabled else "text")


@pytest.mark.parametrize(
    "response,accepted",
    [("y", True), (" YES ", True), ("n", False), ("", False), ("yes please", False)],
)
def test_injected_confirmation_is_used_even_on_tty(monkeypatch, response, accepted):
    monkeypatch.setattr(workflow.sys.stdin, "isatty", lambda: True)
    prompts = []
    assert (
        workflow.ask_confirmation(input_fn=lambda prompt: prompts.append(prompt) or response)
        is accepted
    )
    assert prompts == ["Are these changes OK? (y/n) "]


def test_confirmation_uses_normal_non_tty_input(monkeypatch):
    monkeypatch.setattr(workflow.sys.stdin, "isatty", lambda: False)
    prompts = []
    monkeypatch.setattr("builtins.input", lambda prompt: prompts.append(prompt) or "yes")
    assert workflow.ask_confirmation("Proceed? ")
    assert prompts == ["Proceed? "]


@pytest.mark.parametrize("response,accepted", [("y", True), ("Y", True), ("n", False)])
def test_tty_confirmation_reads_single_key_and_restores_terminal(
    monkeypatch, capsys, response, accepted
):
    events = []
    stdin = SimpleNamespace(
        isatty=lambda: True,
        fileno=lambda: 7,
        read=lambda count: events.append(("read", count)) or response,
    )
    monkeypatch.setattr(workflow.sys, "stdin", stdin)
    monkeypatch.setattr(
        workflow.termios, "tcgetattr", lambda fd: events.append(("get", fd)) or "previous"
    )
    monkeypatch.setattr(workflow.tty, "setraw", lambda fd: events.append(("raw", fd)))
    monkeypatch.setattr(
        workflow.termios, "tcsetattr", lambda *args: events.append(("restore", *args))
    )
    assert workflow.ask_confirmation("Proceed? ") is accepted
    assert events == [
        ("get", 7),
        ("raw", 7),
        ("read", 1),
        ("restore", 7, workflow.termios.TCSADRAIN, "previous"),
    ]
    assert capsys.readouterr().out == "Proceed? \n"


def test_confirmation_does_not_swallow_input_errors_and_restores_tty(monkeypatch):
    def interrupted(*args):
        raise KeyboardInterrupt

    with pytest.raises(KeyboardInterrupt):
        workflow.ask_confirmation(input_fn=interrupted)
    restored = []
    monkeypatch.setattr(
        workflow.sys,
        "stdin",
        SimpleNamespace(isatty=lambda: True, fileno=lambda: 9, read=interrupted),
    )
    monkeypatch.setattr(workflow.termios, "tcgetattr", lambda fd: "original")
    monkeypatch.setattr(workflow.tty, "setraw", lambda fd: None)
    monkeypatch.setattr(workflow.termios, "tcsetattr", lambda *args: restored.append(args))
    with pytest.raises(KeyboardInterrupt):
        workflow.ask_confirmation()
    assert restored == [(9, workflow.termios.TCSADRAIN, "original")]


def test_dry_run_plans_renders_once_without_signature_prompt_lock_or_apply(tree):
    events, outputs = [], []
    plan = selected_plan(tree)

    def forbidden(*args):
        pytest.fail("dry-run performed a mutation or confirmation step")

    def planner():
        events.append("plan")
        return plan

    def describe(chosen):
        assert chosen is plan
        events.append("describe")
        return "shared view"

    assert (
        workflow.run_sync(
            planner=planner,
            applier=forbidden,
            dry_run=True,
            confirm=forbidden,
            input_fn=forbidden,
            output=outputs.append,
            describe=describe,
            lock=forbidden,
            signature=forbidden,
        )
        == 0
    )
    assert events == ["plan", "describe"]
    assert outputs == ["shared view", "Dry-run: no changes made."]


def test_confirmation_receives_exact_rendered_description_and_cancel_does_not_lock(tree):
    plan, outputs = selected_plan(tree), []
    seen = []

    def forbidden(*args):
        pytest.fail("cancelled sync attempted mutation")

    assert (
        workflow.run_sync(
            planner=lambda: plan,
            applier=forbidden,
            confirm=lambda text: seen.append(text) or False,
            output=outputs.append,
            lock=forbidden,
            cancelled_status=0,
        )
        == 0
    )
    assert seen == [outputs[0]]
    assert outputs[-1] == "Operation cancelled."


def test_locked_replan_callback_order_and_result(tree):
    events, outputs = [], []
    plan = selected_plan(tree)
    plans = []

    def planner():
        chosen = plan_for(tree, plan.operations)
        plans.append(chosen)
        events.append("plan")
        return chosen

    def signature(chosen):
        events.append("signature")
        return chosen.operations

    @contextmanager
    def lock():
        events.append("lock")
        yield
        events.append("unlock")

    def apply(chosen):
        assert chosen is plans[-1] and chosen is not plans[0]
        events.append("apply")
        return SimpleNamespace(
            ownership={str(op.destination): str(op.desired_source) for op in chosen.operations},
            warnings=(),
            backups=(),
        )

    def describe(chosen):
        events.append("describe")
        return "same view"

    def confirm(text):
        assert text == outputs[0] == "same view"
        events.append("confirm")
        return True

    assert (
        workflow.run_sync(
            planner=planner,
            applier=apply,
            confirm=confirm,
            output=outputs.append,
            describe=describe,
            lock=lock,
            signature=signature,
        )
        == 0
    )
    assert events == [
        "plan",
        "describe",
        "signature",
        "confirm",
        "lock",
        "plan",
        "signature",
        "apply",
        "unlock",
    ]
    assert len(outputs) == 2 and outputs[-1].startswith("Sync result:")


@pytest.mark.parametrize("changed", ["action", "identity", "warning"])
def test_replan_refuses_changed_plan_without_apply(tree, changed):
    first = plan_for(tree, [Operation(tree[1] / "tool", tree[0] / "machine/configuration.nix")])
    second = plan_for(tree, first.operations)
    if changed == "warning":
        second.warnings = ("new warning",)
    else:
        second.operations = (
            replace(first.operations[0], **{changed: "skip" if changed == "action" else (123,)}),
        )
    plans = iter((first, second))
    outputs = []

    def forbidden(chosen):
        pytest.fail("changed plan was applied")

    assert (
        workflow.run_sync(
            planner=lambda: next(plans),
            applier=forbidden,
            confirm=lambda text: True,
            output=outputs.append,
        )
        == 1
    )
    assert outputs[-1] == "Sync plan changed after confirmation; review a fresh dry-run."


def test_common_workflow_uses_injected_reader_and_existing_context_manager(tree):
    plan, prompts = plan_for(tree), []
    with_context = []

    @contextmanager
    def context():
        with_context.append(True)
        yield

    assert (
        workflow.run_sync(
            planner=lambda: plan,
            applier=lambda chosen: {"complete": True},
            input_fn=lambda prompt: prompts.append(prompt) or "yes",
            output=lambda text: None,
            lock=context(),
        )
        == 0
    )
    assert prompts == ["Are these changes OK? (y/n) "]
    assert with_context == [True]


def test_result_summary_uses_ownership_counters_backups_and_relative_warnings(tree):
    repo, home, _ = tree
    operations = [
        Operation(home / name, repo / "machine/configuration.nix", action)
        for name, action in (
            ("new", "create"),
            ("updated", "replace"),
            ("kept", "keep"),
            ("missing", "create"),
            ("blocked", "skip"),
        )
    ]
    operations.append(Operation(home / "old", None, "remove"))
    plan = plan_for(tree, operations)
    result = SimpleNamespace(
        ownership={str(op.destination): str(op.desired_source) for op in operations[:3]},
        backups=(home / "updated.backup",),
        warnings=(f"Preserved {home / 'blocked'}",),
        errors=(),
    )
    text = workflow.render_sync_result(plan, result)
    assert "1 created, 1 updated, 1 unchanged, 1 removed, 2 skipped, 1 backups." in text
    assert "~/updated.backup" in text and "Preserved ~/blocked" in text
    assert str(home) not in text
    explicit = workflow.render_sync_result(
        plan, {"created": 7, "removed": 0, "complete": False, "errors": ("failed",)}
    )
    assert "7 created" in explicit and "0 removed" in explicit
    assert "Errors (1):" in explicit and "Sync is partial" in explicit


def test_protected_conflict_reason_remains_visible(tree):
    repo, home, _ = tree
    plan = plan_for(
        tree,
        [
            Operation(
                home / "protected",
                repo / "machine/configuration.nix",
                "protected",
                "user-owned file",
                "reserved",
            )
        ],
    )
    text = workflow.describe_sync_plan(plan)
    assert "Dotfiles" not in text
    assert "~/protected: user-owned file (protected: reserved; left untouched)" in text


def test_view_shortens_resolved_home_alias_without_changing_destinations(tree, tmp_path):
    repo, home, system = tree
    alias = tmp_path / "home-alias"
    alias.symlink_to(home, target_is_directory=True)
    plan = plan_for(
        (repo, alias, system),
        [Operation(alias / "tool", repo / "machine/configuration.nix")],
        warnings=(f"Preserve {home / 'changed'}",),
    )
    text = workflow.describe_sync_plan(plan)
    assert "~/tool" in text and "Preserve ~/changed" in text
    assert str(alias) not in text and str(home) not in text
    assert plan.operations[0].destination == alias / "tool"


def test_result_does_not_report_preserved_stale_objects_as_removed(tree):
    repo, home, _ = tree
    stale = home / "stale"
    stale.symlink_to(repo / "missing")
    plan = plan_for(tree, [Operation(stale, None, "remove")])
    result = SimpleNamespace(ownership={}, backups=(), warnings=(f"Preserve {stale}",))
    text = workflow.render_sync_result(plan, result)
    assert "0 removed, 1 skipped" in text


def test_generated_result_adapter_conflicts_and_generation_are_visible(tree):
    text = workflow.render_sync_result(
        plan_for(tree),
        {"complete": False, "conflicts": [str(tree[1] / "terminal")], "generation": "profile-7"},
    )
    assert "1 skipped" in text
    assert "Preserved conflicts (1):\n  ~/terminal" in text
    assert "Generation: profile-7" in text
    assert "Sync is partial" in text


def test_mutated_signature_object_cannot_bypass_recheck(tree):
    plan = plan_for(tree)
    signature = {"generation": 1}
    outputs = []

    def confirm(description):
        signature["generation"] = 2
        return True

    def forbidden(chosen):
        pytest.fail("changed signature was applied")

    assert (
        workflow.run_sync(
            planner=lambda: plan,
            applier=forbidden,
            confirm=confirm,
            signature=lambda chosen: signature,
            output=outputs.append,
        )
        == 1
    )
    assert "changed after confirmation" in outputs[-1]


@pytest.mark.parametrize("stage", ["plan", "apply"])
def test_workflow_reports_errors_and_partial_result(tree, stage):
    outputs = []

    def failing(*args):
        raise ValueError("fixture failure")

    plan = plan_for(tree)
    assert (
        workflow.run_sync(
            planner=failing if stage == "plan" else lambda: plan,
            applier=failing,
            confirm=lambda text: True,
            output=outputs.append,
        )
        == 1
    )
    assert outputs[-1] == "Error: fixture failure"
    assert (
        workflow.run_sync(
            planner=lambda: plan,
            applier=lambda chosen: {"complete": False},
            confirm=lambda text: True,
            output=outputs.append,
        )
        == 1
    )
