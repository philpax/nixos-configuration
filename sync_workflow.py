"""Shared link selection, plan display, and confirmed sync workflow.

Callers supply destinations, planning, mutation, and any lock they require. This
module does not choose ownership, privilege, or generated-file policies.
"""

from __future__ import annotations

import os
import re
import sys
import termios
import tty
from collections import defaultdict
from collections.abc import Mapping
from contextlib import nullcontext
from dataclasses import dataclass, fields, is_dataclass
from pathlib import Path

AGENTS_SKILLS_SUBPATH = Path(".agents/skills")
CLAUDE_PLUGINS_SUBPATH = Path(".claude-plugins")
WORK_COMPATIBLE_MARKER = ".work-compatible"
_NAME_RE = re.compile(r"[a-z][a-z0-9-]*\Z")


def _color_enabled() -> bool:
    return sys.stdout.isatty() and "NO_COLOR" not in os.environ


def _wrap(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _color_enabled() else text


def bold(text: str) -> str:
    return _wrap("1", text)


def green(text: str) -> str:
    return _wrap("32", text)


def yellow(text: str) -> str:
    return _wrap("33", text)


def red(text: str) -> str:
    return _wrap("31", text)


def cyan(text: str) -> str:
    return _wrap("36", text)


def dim(text: str) -> str:
    return _wrap("2", text)


def _machine_last(folder_name, allowed_layers):
    return [*dict.fromkeys(layer for layer in allowed_layers if layer != folder_name), folder_name]


def build_symlink_list(
    targets_root: Path,
    target_dir: Path,
    folder_name: str,
    allowed_layers: list[str],
    strip_layer_prefix: bool = False,
) -> list[tuple[Path, Path]]:
    """Collect files with legacy sorted-layer ordering and the machine last."""
    if not targets_root.is_dir():
        raise FileNotFoundError(f"Source directory not found: {targets_root}")
    selected = {}
    for layer in _machine_last(folder_name, sorted(set(allowed_layers))):
        source_dir = targets_root / layer
        if strip_layer_prefix:
            source_dir /= "dotfiles"
        if not source_dir.is_dir():
            continue
        for source in sorted(source_dir.rglob("*")):
            if source.is_symlink() or not source.is_file():
                continue
            relative = source.relative_to(source_dir)
            if not strip_layer_prefix:
                if "dotfiles" in relative.parts:
                    continue
                relative = Path(layer) / relative
            elif relative.parts[0].startswith(".agents") or relative.parts[0] == str(
                CLAUDE_PLUGINS_SUBPATH
            ):
                # Skills and plugins are linked as whole directories below.
                continue
            selected[target_dir / relative] = source
    return sorted(selected.items())


def _directory_links(source_dir, target_dir, marker):
    if not source_dir.is_dir():
        return []
    return [
        (target_dir / entry.name, entry)
        for entry in sorted(source_dir.iterdir())
        if entry.is_dir() and (entry / marker).is_file()
    ]


def build_skill_symlinks(source_dir: Path, target_dir: Path) -> list[tuple[Path, Path]]:
    """Link each immediate directory containing SKILL.md as one skill."""
    return _directory_links(source_dir, target_dir, "SKILL.md")


def build_work_skill_symlinks(source_dir: Path, target_dir: Path) -> list[tuple[Path, Path]]:
    """Link only skills containing the work-account opt-in marker."""
    return [
        (destination, source)
        for destination, source in build_skill_symlinks(source_dir, target_dir)
        if (source / WORK_COMPATIBLE_MARKER).is_file()
    ]


def build_layered_skill_symlinks(
    targets_root: Path, target_dir: Path, folder_name: str, allowed_layers: list[str]
) -> list[tuple[Path, Path]]:
    selected = {}
    for layer in _machine_last(folder_name, allowed_layers):
        selected.update(
            build_skill_symlinks(
                targets_root / layer / "dotfiles" / AGENTS_SKILLS_SUBPATH, target_dir
            )
        )
    return sorted(selected.items())


def build_layered_plugin_symlinks(
    targets_root: Path, target_dir: Path, folder_name: str, allowed_layers: list[str]
) -> list[tuple[Path, Path]]:
    selected = {}
    for layer in _machine_last(folder_name, allowed_layers):
        selected.update(
            _directory_links(
                targets_root / layer / "dotfiles" / CLAUDE_PLUGINS_SUBPATH,
                target_dir,
                ".claude-plugin/plugin.json",
            )
        )
    return sorted(selected.items())


def build_cog_symlinks(source_dir: Path, target_dir: Path) -> list[tuple[Path, Path]]:
    """Link checked-out Steel cogs as whole directories."""
    return _directory_links(source_dir, target_dir, "cog.scm")


def _absolute_root(path):
    return Path(os.path.abspath(Path(path).expanduser()))


def _validate_layer(repo, name):
    if not isinstance(name, str) or not _NAME_RE.fullmatch(name):
        raise ValueError(f"Unsafe sync layer name: {name!r}")
    folder = repo / name
    if (
        folder.is_symlink()
        or not folder.is_dir()
        or not any(
            (folder / entry).is_dir() if entry == "dotfiles" else (folder / entry).is_file()
            for entry in ("configuration.nix", "dotfiles", "sync.json")
        )
    ):
        raise ValueError(f"Unknown sync layer: {name}")


def collect_links(
    repo: Path, home: Path, layers: tuple[str, ...], *, nixos_root: Path | None = None
) -> tuple[dict[Path, Path], tuple[tuple[Path, Path, Path], ...]]:
    """Select one inventory; optional system destinations only extend it.

    Layers are ordered, with the target last. Repeated layers are applied once;
    the last layer always wins. Sources are canonical repository paths, except
    for the personal Claude Code link to the selected home's agents skill tree.
    """
    repo = Path(repo).expanduser().resolve()
    home = _absolute_root(home)
    if not repo.is_dir():
        raise FileNotFoundError(f"Source directory not found: {repo}")
    if not layers:
        raise ValueError("Sync requires at least one layer (the target)")
    for layer in layers:
        _validate_layer(repo, layer)
    layers = _machine_last(layers[-1], layers[:-1])
    system = _absolute_root(nixos_root) if nixos_root is not None else None
    if system is not None and (system.is_relative_to(home) or home.is_relative_to(system)):
        raise ValueError("Home and system destinations must not overlap")
    selected: dict[Path, Path] = {}
    overrides = []

    def add(destination, source, *, wiring=False):
        source = source if wiring else source.resolve()
        if not wiring and not source.is_relative_to(repo):
            raise ValueError(f"Source escapes repository: {source}")
        if destination in selected and selected[destination] != source:
            overrides.append((destination, selected[destination], source))
        selected[destination] = source

    for layer in layers:
        for destination, source in build_symlink_list(repo, home, layer, [], True):
            add(destination, source)
        for destination, source in build_skill_symlinks(
            repo / layer / "dotfiles" / AGENTS_SKILLS_SUBPATH, home / AGENTS_SKILLS_SUBPATH
        ):
            add(destination, source)
        for destination, source in build_layered_plugin_symlinks(
            repo, home / ".local/share/claude-plugins", layer, []
        ):
            add(destination, source)
        if system is not None:
            for destination, source in build_symlink_list(repo, system, layer, []):
                add(destination, source)

    # Opt-in follows the winning personal skill, never a shadowed shared skill.
    for destination, source in tuple(selected.items()):
        if (
            destination.parent == home / AGENTS_SKILLS_SUBPATH
            and (source / WORK_COMPATIBLE_MARKER).is_file()
        ):
            add(home / ".claude-work/skills" / destination.name, source)
    for destination, source in build_cog_symlinks(repo / "steel-cogs", home / ".config/steel/cogs"):
        add(destination, source)
    add(home / ".claude/skills", home / AGENTS_SKILLS_SUBPATH, wiring=True)
    if system is not None:
        entry = repo / layers[-1] / "configuration.nix"
        if not entry.is_file():
            raise FileNotFoundError(f"Configuration file not found: {entry}")
        add(system / "configuration.nix", entry)
    return dict(sorted(selected.items())), tuple(overrides)


@dataclass(frozen=True)
class Section:
    """One optional group of display items, rendered like the link inventory."""

    title: str
    items: tuple[str, ...]
    group: str | None = None


def _get(value, name, default=None):
    return value.get(name, default) if isinstance(value, Mapping) else getattr(value, name, default)


def _roots(plan):
    roots = _get(plan, "roots", ())
    if isinstance(roots, Mapping):
        roots = roots.values()
    elif isinstance(roots, (str, Path)):
        roots = (roots,)
    return tuple(Path(root) for root in roots if root is not None)


def _system_root(plan, destination):
    home = Path(_get(plan, "home"))
    return next(
        (root for root in _roots(plan) if root != home and destination.is_relative_to(root)), None
    )


def _display_path(path, plan):
    path, home, repo = Path(path), Path(_get(plan, "home")), Path(_get(plan, "repo"))
    if path == home:
        return "~"
    if path.is_relative_to(home):
        return f"~/{path.relative_to(home)}"
    system = _system_root(plan, path)
    if system is not None:
        return f"NixOS/{path.relative_to(system)}"
    if path.is_relative_to(repo):
        return str(path.relative_to(repo))
    return str(path)


def _shorten_text(text, plan):
    text = str(text)
    home = Path(_get(plan, "home"))
    home_aliases = [home]
    # Planning may preserve a lexical home path while diagnostics resolve it.
    # Shortening both spellings is display-only; destinations remain untouched.
    resolved_home = home.resolve()
    if resolved_home != home:
        home_aliases.append(resolved_home)
    # Replace complete path prefixes, not similarly named neighbouring homes.
    for root, replacement in (
        (Path(_get(plan, "repo")), ""),
        *((alias, "~/") for alias in home_aliases),
    ):
        text = text.replace(str(root) + "/", replacement)
        text = re.sub(re.escape(str(root)) + r"(?=$|[\s,;:)])", replacement.rstrip("/"), text)
    for root in _roots(plan):
        if root != Path(_get(plan, "home")):
            text = text.replace(str(root) + "/", "NixOS/")
    return text


def _source_layer(source, plan):
    if source is not None:
        source, repo = Path(source), Path(_get(plan, "repo"))
        if source.is_relative_to(repo) and source != repo:
            return source.relative_to(repo).parts[0]
    return str(_get(plan, "target"))


def _category(op, plan):
    destination, home = Path(_get(op, "destination")), Path(_get(plan, "home"))
    if _system_root(plan, destination) is not None:
        return "NixOS configuration", _source_layer(_get(op, "desired_source"), plan)
    for subpath, title, group in (
        (".agents/skills", "Agent skills (personal)", "agents-skills"),
        (".claude/skills", "Claude Code personal wiring", "claude-skills"),
        (".claude-work/skills", "Claude Code skills (work)", "agents-skills"),
        (".local/share/claude-plugins", "Claude Code plugins", "claude-plugins"),
        (".config/steel/cogs", "Steel cogs", "steel-cogs"),
    ):
        if destination.is_relative_to(home / subpath):
            return title, group
    return "Dotfiles", _source_layer(_get(op, "desired_source"), plan)


def _excluded(op, plan):
    if _get(op, "action") in {"protected", "excluded"}:
        return True
    destination, home = Path(_get(op, "destination")), Path(_get(plan, "home"))
    if not destination.is_relative_to(home):
        return False
    relative = destination.relative_to(home)
    return any(
        relative.is_relative_to(Path(exclusion)) or Path(exclusion).is_relative_to(relative)
        for exclusion in _get(plan, "exclusions", ())
    )


def _render_sections(sections, plan, *, count_color=green, item_color=dim):
    by_title = {}
    for section in sections:
        if section.items:
            by_title.setdefault(section.title, []).append(section)
    lines = []
    for title, groups in by_title.items():
        count = sum(len(section.items) for section in groups)
        lines.append(f"{bold(title)} {count_color(f'({count})')}:")
        for section in groups:
            if section.group is not None:
                lines.append(f"  {yellow(section.group)} {dim(f'({len(section.items)})')}:")
            indent = "    " if section.group is not None else "  "
            lines.extend(indent + item_color(_shorten_text(item, plan)) for item in section.items)
        lines.append("")
    return lines


def _action_note(action):
    return {
        "keep": "",
        "unchanged": "",
        "create": " [create]",
        "replace": " [update]",
        "update": " [update]",
        "backup": " [back up and replace]",
        "skip": " [skipped]",
    }.get(action, f" [{action}]")


def describe_sync_plan(plan, *, extra_sections=(), footer=()) -> str:
    """Render all destinations with one grouped view, including preserved paths."""
    imported = [str(layer) for layer in _get(plan, "layers", ()) if layer != _get(plan, "target")]
    lines = [f"{bold('Imported layers:')} {cyan(' '.join(imported) or 'none')}", ""]
    inventory = defaultdict(lambda: defaultdict(list))
    conflicts, stale, excluded = [], [], {}
    for op in sorted(_get(plan, "operations", ()), key=lambda op: str(_get(op, "destination"))):
        destination = Path(_get(op, "destination"))
        source, action = _get(op, "desired_source"), _get(op, "action")
        path = _display_path(destination, plan)
        if _excluded(op, plan):
            protection = _get(op, "protection") or "exclusion"
            excluded[path] = f" (protected: {protection})"
            if _get(op, "conflict"):
                conflicts.append(
                    f"{path}: {_get(op, 'conflict')} (protected: {protection}; left untouched)"
                )
            continue
        if action == "remove":
            stale.append(path)
        if source is not None and action != "remove":
            title, group = _category(op, plan)
            if title == "NixOS configuration":
                root = _system_root(plan, destination)
                relative = destination.relative_to(root)
                path = (
                    str(Path(*relative.parts[1:])) if relative.parts[0] == group else str(relative)
                )
            elif title == "Claude Code personal wiring":
                path += f" -> {_display_path(source, plan)}"
            inventory[title][group].append(path + _action_note(action))
        if _get(op, "conflict"):
            reason = str(_get(op, "conflict"))
            protection = _get(op, "protection")
            if protection and protection not in reason:
                reason += f"; protected: {protection}"
            disposition = (
                "back up and replace"
                if action == "backup"
                else "skipped; left untouched"
                if action == "skip"
                else f"{action} without backup"
            )
            conflicts.append(f"{_display_path(destination, plan)}: {reason} ({disposition})")
    sections = []
    for title in (
        "NixOS configuration",
        "Dotfiles",
        "Agent skills (personal)",
        "Claude Code personal wiring",
        "Claude Code skills (work)",
        "Claude Code plugins",
        "Steel cogs",
    ):
        for group in sorted(
            inventory[title], key=lambda group: (not group.startswith("common-"), group)
        ):
            sections.append(Section(title, tuple(inventory[title][group]), group))
    sections.extend(extra_sections)
    lines.extend(_render_sections(sections, plan))
    lines.extend(
        _render_sections(
            [
                Section(
                    "Exclusions", tuple(path + reason for path, reason in sorted(excluded.items()))
                )
            ],
            plan,
            count_color=yellow,
        )
    )
    lines.extend(
        _render_sections(
            [
                Section("Stale symlinks to remove", tuple(stale)),
                Section("Conflicts", tuple(conflicts)),
            ],
            plan,
            count_color=red,
        )
    )
    overrides = tuple(
        f"{_display_path(destination, plan)}: "
        f"{_source_layer(old, plan)} -> {_source_layer(new, plan)}"
        for destination, old, new in _get(plan, "overrides", ())
    )
    lines.extend(
        _render_sections(
            [
                Section("Layer overrides", overrides),
                Section("Warnings", tuple(_get(plan, "warnings", ()))),
            ],
            plan,
            count_color=yellow,
        )
    )
    lines.extend(_shorten_text(line, plan) for line in footer)
    return "\n".join(lines).rstrip()


def ask_confirmation(message="Are these changes OK? (y/n) ", *, input_fn=None) -> bool:
    """Read one key on a TTY, or one line from an injected/non-TTY reader."""
    if input_fn is not None or not sys.stdin.isatty():
        return (input_fn or input)(message).strip().lower() in {"y", "yes"}
    print(message, end="", flush=True)
    fd = sys.stdin.fileno()
    previous = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        response = sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, previous)
    print()
    return response.lower() == "y"


def render_sync_result(plan, result) -> str:
    """Summarize mutation results without repeating the desired inventory.

    Explicit result counters take precedence. For ownership-only results, count
    retained desired links and check whether stale destinations remain. Adapters
    can supply counters for generated files or more precise operation outcomes.
    """
    plan = _get(result, "plan", plan)
    counts = dict.fromkeys(("created", "updated", "unchanged", "removed", "skipped"), 0)
    ownership = _get(result, "ownership")
    for op in _get(plan, "operations", ()):
        action = _get(op, "action")
        bucket = {
            "create": "created",
            "replace": "updated",
            "update": "updated",
            "backup": "updated",
            "keep": "unchanged",
            "unchanged": "unchanged",
            "remove": "removed",
        }.get(action, "skipped")
        source, destination = _get(op, "desired_source"), _get(op, "destination")
        if _excluded(op, plan):
            bucket = "skipped"
        elif action == "remove" and ownership is not None and os.path.lexists(destination):
            bucket = "skipped"
        elif source is not None and ownership is not None and bucket != "skipped":
            recorded = ownership.get(str(destination), ownership.get(destination))
            if recorded is None or str(recorded) != str(source):
                bucket = "skipped"
        counts[bucket] += 1
    for name in counts:
        value = _get(result, name)
        if value is not None:
            counts[name] = value if isinstance(value, int) else len(value)
    backups = tuple(_get(result, "backups", ()))
    errors = tuple(_get(result, "errors", ()))
    warnings = tuple(_get(result, "warnings", ()))
    conflicts = tuple(_get(result, "conflicts", ()))
    if conflicts and _get(result, "skipped") is None:
        counts["skipped"] = max(counts["skipped"], len(conflicts))
    lines = [
        bold("Sync result:")
        + " "
        + ", ".join(f"{count} {name}" for name, count in counts.items())
        + f", {len(backups)} backups.",
        "",
    ]
    lines.extend(_render_sections([Section("Backups", tuple(map(str, backups)))], plan))
    lines.extend(_render_sections([Section("Warnings", warnings)], plan, count_color=yellow))
    lines.extend(
        _render_sections(
            [Section("Preserved conflicts", tuple(map(str, conflicts)))], plan, count_color=yellow
        )
    )
    lines.extend(_render_sections([Section("Errors", errors)], plan, count_color=red))
    generation = _get(result, "generation")
    if generation is not None:
        lines.append(f"Generation: {_shorten_text(generation, plan)}")
    if _get(result, "complete") is False:
        lines.append("Sync is partial; resolve the reported conflicts before retrying.")
    return "\n".join(lines).rstrip()


def _freeze(value):
    if is_dataclass(value) and not isinstance(value, type):
        return tuple((field.name, _freeze(getattr(value, field.name))) for field in fields(value))
    if isinstance(value, Mapping):
        return tuple(sorted(((str(key), _freeze(item)) for key, item in value.items())))
    if isinstance(value, (tuple, list)):
        return tuple(map(_freeze, value))
    if isinstance(value, (set, frozenset)):
        return tuple(sorted(map(_freeze, value), key=repr))
    if hasattr(value, "__dict__"):
        return _freeze(vars(value))
    return value


def run_sync(
    *,
    planner,
    applier,
    dry_run=False,
    confirm=None,
    input_fn=None,
    output=print,
    describe=None,
    lock=None,
    signature=None,
    cancelled_status=1,
) -> int:
    """Plan, display once, obtain consent, recheck under a lock, then apply.

    ``confirm`` receives exactly the description sent to ``output``. ``lock``
    may be a context manager or a no-argument context-manager factory. A custom
    ``signature(plan)`` can include additional caller-managed filesystem state;
    otherwise all stored plan fields are compared, including operation identity.
    """
    try:
        plan = planner()
        description = (describe or describe_sync_plan)(plan)
        expected = _freeze((signature or _freeze)(plan)) if not dry_run else None
    except (OSError, ValueError, RuntimeError) as exc:
        output(f"Error: {exc}")
        return 1
    output(description)
    if dry_run:
        output("Dry-run: no changes made.")
        return 0
    accepted = confirm(description) if confirm is not None else ask_confirmation(input_fn=input_fn)
    if not accepted:
        output("Operation cancelled.")
        return cancelled_status
    try:
        context = (
            lock if hasattr(lock, "__enter__") else lock() if lock is not None else nullcontext()
        )
        with context:
            current = planner()
            if _freeze((signature or _freeze)(current)) != expected:
                output("Sync plan changed after confirmation; review a fresh dry-run.")
                return 1
            result = applier(current)
        output(render_sync_result(current, result))
        return 1 if _get(result, "errors") or _get(result, "complete") is False else 0
    except (OSError, ValueError, RuntimeError) as exc:
        output(f"Error: {exc}")
        return 1
