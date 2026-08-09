#!/usr/bin/env python3
"""Sync NixOS configuration and dotfiles via symlinks.

The repository is target-first: each machine or shared layer ("target") owns a
directory at the repo root (common-all/, common-desktop/, ..., redline/)
containing its Nix files directly (incl. configuration.nix), plus a dotfiles/
subdirectory where it has dotfiles.

Creates symlinks for the target's NixOS files (the target's own dir plus the
common-* layers it imports) under /etc/nixos, and for its dotfiles under $HOME,
then symlinks /etc/nixos/configuration.nix to the target's configuration.nix.
Skills are symlinked into the canonical ~/.agents/skills tree (which
Polytoken discovers), with Claude Code personal wired to the same tree via
~/.claude/skills -> ~/.agents/skills. Work-account skills additionally go to
~/.claude-work/skills; the work-account set is the skills marked
.work-compatible.

Only the common-* layers that the machine's configuration.nix actually imports
are synced — mirrors the NixOS import hierarchy so e.g. a headless machine
won't receive desktop dotfiles.

When re-syncing, symlinks from a previous sync that are no longer in the current
sync-set are detected (via .sync-state.json) and offered for removal.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import termios
import tty
from collections import defaultdict
from datetime import date, datetime, timezone
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent
# Target-first layout: every machine/layer ("target") lives at the repo root,
# with its Nix files directly (incl. configuration.nix) and any dotfiles under
# <target>/dotfiles/. There is no top-level nixos/ or dotfiles/ grouping dir.
TARGETS_ROOT = REPO_DIR
NIXOS_TARGET = Path("/etc/nixos")
DOTFILES_TARGET = Path.home()
STATE_FILE = REPO_DIR / ".sync-state.json"


def target_dir(name: str) -> Path:
    """Return the repo directory for a target (machine or common-* layer)."""
    return TARGETS_ROOT / name


def discover_targets() -> list[Path]:
    """Return repo-root dirs that are sync targets.

    A target has either a configuration.nix (Nix machine/layer) or a dotfiles/
    subdirectory (dotfiles-only). Excludes non-target dirs like .agents,
    .claude, steel-cogs, and stray files.
    """
    if not TARGETS_ROOT.is_dir():
        return []
    targets = [
        d
        for d in TARGETS_ROOT.iterdir()
        if d.is_dir() and ((d / "configuration.nix").is_file() or (d / "dotfiles").is_dir())
    ]
    return sorted(targets)


# Skills are the shared source of truth. Per-skill directory symlinks are
# created under ~/.agents/skills (which Polytoken discovers natively), and
# Claude Code personal reads the same tree through a single directory symlink
# ~/.claude/skills -> ~/.agents/skills — matching the repo's own project-local
# .claude/skills -> .agents/skills pattern. Skills live per-layer at
# <layer>/dotfiles/.agents/skills/<name>, so which skills a machine gets
# follows the same layer hierarchy as the dotfiles — e.g. redline's
# llama-cpp-model-tuning skill only syncs to machines that include the redline
# layer.
#
# Polytoken 0.6.4 does not discover skill directories that are symlinks
# (reported upstream). Until a fixed release lands, copy mode copies the
# skill trees into ~/.agents/skills as real directories instead of symlinking
# them, so Polytoken picks them up. Flip AGENT_SKILLS_COPY_MODE to False once
# the fix is out to return to directory symlinks. The copy mode expires on
# AGENT_SKILLS_COPY_MODE_EXPIRY: after that date a sync fails until the
# constant is flipped, so the workaround cannot silently outlive its reason
# for existing.
AGENTS_SKILLS_SUBPATH = Path(".agents") / "skills"
SHARED_SKILLS_SOURCE = TARGETS_ROOT / "common-dev" / "dotfiles" / AGENTS_SKILLS_SUBPATH
CC_SKILLS_TARGET = Path.home() / ".claude" / "skills"
AGENTS_SKILLS_TARGET = Path.home() / ".agents" / "skills"
AGENT_SKILLS_COPY_MODE = True
AGENT_SKILLS_COPY_MODE_EXPIRY = date(2026, 8, 10)
AGENT_SKILLS_COPY_MODE_EXPIRY_MSG = (
    "Agent skills copy mode has expired (Polytoken should now follow skill "
    "directory symlinks). Set AGENT_SKILLS_COPY_MODE = False in sync.py to "
    "return to symlinking skills into ~/.agents/skills."
)

# Skills usable from Claude Code's work-account install get synced into
# ~/.claude-work/skills/ as well, so the personal and work accounts load the
# same skills. A skill opts in by containing a .work-compatible marker file
# (see build_work_skill_symlinks).
CLAUDE_WORK_SKILLS_DIR = Path.home() / ".claude-work"
CLAUDE_WORK_SKILLS_TARGET = CLAUDE_WORK_SKILLS_DIR / "skills"
WORK_COMPATIBLE_MARKER = ".work-compatible"

# Steel plugins ("cogs") for the plugin-enabled Helix fork are git submodules under
# steel-cogs/. Each is directory-symlinked into steel's cog root ($STEEL_HOME/cogs; STEEL_HOME
# is pinned to ~/.config/steel in the fish config) so `(require "forest/...")` resolves. They
# live outside the target dirs so the per-file dotfiles flow doesn't also grab their
# LICENSE/README/.git; here they get one clean directory symlink each.
STEEL_COGS_SOURCE = REPO_DIR / "steel-cogs"
STEEL_COGS_TARGET = Path.home() / ".config" / "steel" / "cogs"

LAYER_IMPORT_RE = re.compile(r"\.\./(common-[a-z-]+)")


# ---------------------------------------------------------------------------
# Terminal colors (auto-disabled when not a TTY or NO_COLOR is set)
# ---------------------------------------------------------------------------


def _color_enabled() -> bool:
    return sys.stdout.isatty() and "NO_COLOR" not in os.environ


def _wrap(code: str, text: str) -> str:
    if not _color_enabled():
        return text
    return f"\033[{code}m{text}\033[0m"


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


# ---------------------------------------------------------------------------
# Pure logic (no I/O — trivially testable)
# ---------------------------------------------------------------------------


def parse_imported_layers(content: str) -> list[str]:
    """Extract common-* layer names from Nix configuration content.

    Looks for ../common-*/ import paths and returns sorted unique layer names.
    """
    matches = LAYER_IMPORT_RE.findall(content)
    return sorted(set(matches))


def compute_stale_symlinks(
    previous: dict[str, str],
    current: list[tuple[Path, Path]],
) -> list[str]:
    """Find symlink targets in the previous manifest that aren't in the current sync-set."""
    current_targets = {str(target) for target, _ in current}
    return [target for target in previous if target not in current_targets]


def split_by_target(
    paths: list[str],
    nixos_target: Path,
    dotfiles_target: Path,
) -> tuple[list[str], list[str]]:
    """Split paths into those under nixos_target (need sudo) and dotfiles_target."""
    nixos_paths: list[str] = []
    dotfile_paths: list[str] = []
    for path in paths:
        p = Path(path)
        try:
            p.relative_to(nixos_target)
            nixos_paths.append(path)
            continue
        except ValueError:
            pass
        dotfile_paths.append(path)
    return nixos_paths, dotfile_paths


def is_common_dir(name: str) -> bool:
    return name.startswith("common-")


def group_by_layer(
    symlinks: list[tuple[Path, Path]],
    source_dir: Path,
) -> dict[str, list[tuple[Path, Path]]]:
    """Group symlinks by their source layer (first directory component).

    Returns dict with common-* keys sorted first, then machine names.
    """
    groups: dict[str, list[tuple[Path, Path]]] = defaultdict(list)
    for target, source in symlinks:
        layer = source.relative_to(source_dir).parts[0]
        groups[layer].append((target, source))
    common = {k: v for k, v in sorted(groups.items()) if is_common_dir(k)}
    machine = {k: v for k, v in sorted(groups.items()) if not is_common_dir(k)}
    return {**common, **machine}


def shorten_path(path: str | Path, home: Path | None = None) -> str:
    """Shorten a path for display, using ~ for home directory."""
    path_str = str(path)
    if home is None:
        home = Path.home()
    home_str = str(home)
    if path_str.startswith(home_str + "/"):
        return "~" + path_str[len(home_str) :]
    return path_str


# ---------------------------------------------------------------------------
# Filesystem-reading logic (testable with tmp_path)
# ---------------------------------------------------------------------------


def get_imported_layers(config_path: Path) -> list[str]:
    """Read a machine's configuration.nix and extract its common-* layer imports.

    Scans configuration.nix and all .nix files in the machine's directory to
    find transitive common-* layer imports — e.g. redline imports common-dev
    via programs/development.nix, not directly in configuration.nix.
    """
    if not config_path.is_file():
        return []

    machine_dir = config_path.parent
    layers: set[str] = set()
    for nix_file in machine_dir.rglob("*.nix"):
        layers.update(parse_imported_layers(nix_file.read_text()))
    return sorted(layers)


def build_symlink_list(
    targets_root: Path,
    target_dir: Path,
    folder_name: str,
    allowed_layers: list[str],
    strip_layer_prefix: bool = False,
) -> list[tuple[Path, Path]]:
    """Build list of (target, source) pairs for files to symlink.

    Walks each allowed target directory under ``targets_root`` — the folder
    itself plus all ``allowed_layers`` — collecting files from
    ``<target>/**`` for NixOS config or ``<target>/dotfiles/**`` for dotfiles.

    In the target-first layout ``targets_root`` is the repo root and a target's
    Nix files live directly at ``<target>/...``; its dotfiles (when
    ``strip_layer_prefix`` is True) live at ``<target>/dotfiles/...`` and are
    mapped to ``target_dir`` with the ``<target>/dotfiles`` prefix stripped, so
    ``<target>/dotfiles/.config/fish/config.fish`` becomes
    ``$HOME/.config/fish/config.fish``.
    """
    if not targets_root.is_dir():
        raise FileNotFoundError(f"Source directory not found: {targets_root}")

    allowed = {folder_name, *allowed_layers}
    symlinks: list[tuple[Path, Path]] = []

    for target_name in sorted(allowed):
        if strip_layer_prefix:
            # Dotfiles pass: walk only <target>/dotfiles/**
            source_dir = targets_root / target_name / "dotfiles"
            if not source_dir.is_dir():
                continue
        else:
            # NixOS pass: walk <target>/** but never descend into dotfiles/
            source_dir = targets_root / target_name
            if not source_dir.is_dir():
                continue

        for source_path in sorted(source_dir.rglob("*")):
            # Skip symlinks and non-files (match `find -type f` semantics)
            if source_path.is_symlink() or not source_path.is_file():
                continue

            if (
                not strip_layer_prefix
                and "dotfiles" in source_path.relative_to(targets_root / target_name).parts
            ):
                # NixOS pass: never emit <target>/dotfiles/** files (they are
                # dotfiles, linked in the dotfiles pass, not Nix config).
                continue

            # Relative to targets_root, keeping the target-name prefix: the
            # NixOS pass lands a shared layer's files under
            # /etc/nixos/<layer>/... (e.g. common-all/configuration.nix ->
            # /etc/nixos/common-all/configuration.nix), while the dotfiles pass
            # strips the leading <target>/dotfiles components below.
            relative = source_path.relative_to(targets_root)

            if strip_layer_prefix:
                # <target>/dotfiles/<rel> -> <rel> (drop both components), so
                # <target>/dotfiles/.config/fish/config.fish ->
                # .config/fish/config.fish -> $HOME/.config/fish/config.fish.
                relative = Path(*relative.parts[2:])
                if not relative.parts:
                    continue

            # The per-layer skill sources (<target>/dotfiles/.agents/skills/<name>)
            # must not be re-added as per-file dotfile links:
            # build_layered_skill_symlinks creates whole-directory symlinks at
            # ~/.agents/skills/<name>, and a file link at
            # ~/.agents/skills/<name>/SKILL.md would collide with that directory
            # symlink on every sync. (.claude stays walked — e.g.
            # <target>/dotfiles/.claude/CLAUDE.md is a desired dotfile link.)
            if strip_layer_prefix and relative.parts[0].startswith(".agents"):
                continue

            target_path = target_dir / relative
            symlinks.append((target_path, source_path))

    return symlinks


def copy_skill_tree(source: Path, target: Path) -> None:
    """Copy a skill directory tree into target as real files.

    Used in copy mode (AGENT_SKILLS_COPY_MODE) so Polytoken discovers the
    skill at ``target``: Polytoken 0.6.4 skips skill directories that are
    symlinks. ``target`` is replaced by a copy of ``source`` on every sync, so
    re-syncs converge to the source tree. Any existing target directory is
    removed first.
    """
    if target.is_symlink() or target.exists():
        if target.is_symlink() or target.is_file():
            target.unlink()
        else:
            shutil.rmtree(target)
    target.mkdir(parents=True)
    for entry in sorted(source.rglob("*")):
        if entry.is_dir():
            continue
        rel = entry.relative_to(source)
        dest = target / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(entry, dest)


def build_skill_symlinks(
    source_dir: Path,
    target_dir: Path,
) -> list[tuple[Path, Path]]:
    """Build (target, source) pairs for Polytoken skill directories.

    Each immediate subdirectory of ``source_dir`` that contains a ``SKILL.md``
    becomes a directory-level symlink at ``target_dir/<skill_name>``. Both
    Polytoken (which discovers ~/.agents/skills) and Claude Code follow
    directory-level symlinks to read SKILL.md.
    """
    if not source_dir.is_dir():
        return []

    symlinks: list[tuple[Path, Path]] = []
    for entry in sorted(source_dir.iterdir()):
        if not entry.is_dir():
            continue
        if not (entry / "SKILL.md").is_file():
            continue
        target = target_dir / entry.name
        symlinks.append((target, entry))
    return symlinks


def build_work_skill_symlinks(
    source_dir: Path,
    target_dir: Path,
) -> list[tuple[Path, Path]]:
    """Build (target, source) pairs for work-account skill directories.

    Like :func:`build_skill_symlinks`, but only for skills that opted in by
    containing a ``.work-compatible`` marker file. Each such skill becomes a
    directory-level symlink at ``target_dir/<skill_name>``, so Claude Code's
    work-account install (~/.claude-work/skills/) loads the same skills as the
    personal one (~/.agents/skills).
    """
    if not source_dir.is_dir():
        return []

    symlinks: list[tuple[Path, Path]] = []
    for entry in sorted(source_dir.iterdir()):
        if not entry.is_dir():
            continue
        if not (entry / "SKILL.md").is_file():
            continue
        if not (entry / WORK_COMPATIBLE_MARKER).is_file():
            continue
        target = target_dir / entry.name
        symlinks.append((target, entry))
    return symlinks


def build_layered_skill_symlinks(
    targets_root: Path,
    target_dir: Path,
    folder_name: str,
    allowed_layers: list[str],
    copy_mode: bool = AGENT_SKILLS_COPY_MODE,
) -> list[tuple[Path, Path]]:
    """Collect skill links across every layer the machine syncs.

    Skills are stored per-layer at ``<layer>/dotfiles/.agents/skills/<name>``,
    so a machine only gets a skill if it includes that layer — mirroring the
    dotfiles hierarchy. When two layers define a skill of the same name, the
    machine-specific layer wins over the shared common-* layers.

    The returned pairs are ``(target_dir/<name>, source_skill_dir)`` in both
    modes; ``copy_mode`` only changes how the target is materialised on disk
    (real directory copy vs directory symlink).
    """
    # common-* layers first so a machine-specific layer of the same name wins.
    layers = [*allowed_layers, folder_name]
    by_target: dict[Path, Path] = {}
    for layer in layers:
        skills_dir = targets_root / layer / "dotfiles" / AGENTS_SKILLS_SUBPATH
        for target, source in build_skill_symlinks(skills_dir, target_dir):
            by_target[target] = source
    return sorted(by_target.items())


def build_cc_personal_wiring(agents_skills_target: Path) -> list[tuple[Path, Path]]:
    """One directory symlink: ~/.claude/skills -> ~/.agents/skills.

    Claude Code personal reads skills from ~/.claude/skills; pointing it at
    the canonical ~/.agents/skills tree means CC and Polytoken load the same
    per-skill symlinks with a single source of truth, mirroring the repo's own
    project-local .claude/skills -> .agents/skills symlink. The link created
    here is absolute (agents_skills_target stems from Path.home()); the repo's
    project-local one is relative (../.agents/skills). CC dereferences both
    forms fine.
    """
    return [(CC_SKILLS_TARGET, agents_skills_target)]


def classify_stale(
    stale: list[str],
    cc_targets: list[Path],
    work_targets: list[Path],
) -> tuple[list[str], list[str], list[str]]:
    """Split stale manifest entries into (cc_stale, work_stale, remaining).

    Entries at or under the Claude Code personal skill targets (~/.claude/skills
    itself, old ~/.claude/skills/<name> leaves, and the ~/.agents/skills tree)
    go to ``cc_stale``; entries under the work-account targets go to
    ``work_stale``; everything else — including old per-file skill links from
    the previous layout, which the dotfiles removal pass unlinks harmlessly —
    stays in ``remaining``. The dir-level targets are kept in the skill buckets
    so cleanup of stale leaves never walks through the ~/.claude/skills dir
    symlink into the fresh ~/.agents/skills tree.
    """
    cc_stale: list[str] = []
    work_stale: list[str] = []
    remaining: list[str] = []

    def under(path: str, prefixes: list[Path]) -> bool:
        p = Path(path)
        return any(p == prefix or p.is_relative_to(prefix) for prefix in prefixes)

    for path in stale:
        if under(path, cc_targets):
            cc_stale.append(path)
        elif under(path, work_targets):
            work_stale.append(path)
        else:
            remaining.append(path)
    return cc_stale, work_stale, remaining


def build_cog_symlinks(
    source_dir: Path,
    target_dir: Path,
) -> list[tuple[Path, Path]]:
    """Build (target, source) pairs for Steel cog directories (git submodules).

    Each immediate subdirectory of ``source_dir`` that contains a ``cog.scm``
    becomes a directory-level symlink at ``target_dir/<cog_name>``, so steel
    resolves ``(require "<cog>/<file>.scm")`` from ``$STEEL_HOME/cogs/<cog>``.
    A submodule that hasn't been checked out has no ``cog.scm`` and is skipped.
    """
    if not source_dir.is_dir():
        return []

    symlinks: list[tuple[Path, Path]] = []
    for entry in sorted(source_dir.iterdir()):
        if not entry.is_dir():
            continue
        if not (entry / "cog.scm").is_file():
            continue
        target = target_dir / entry.name
        symlinks.append((target, entry))
    return symlinks


def find_conflicts(
    symlinks: list[tuple[Path, Path]],
    exempt_targets: list[Path] | None = None,
) -> list[Path]:
    """Find existing non-symlink files that would be overwritten.

    ``exempt_targets`` are subtree roots whose existing real directories are
    expected and must not be reported as conflicts. Copy mode passes the
    ~/.agents/skills root so the copied skill directories are not flagged.
    """
    conflicts: list[Path] = []
    for target, _ in symlinks:
        if target.exists() and not target.is_symlink():
            if exempt_targets and any(
                target == root or target.is_relative_to(root) for root in exempt_targets
            ):
                continue
            conflicts.append(target)
    return conflicts


def list_available_targets() -> list[str]:
    """List machine targets, annotated with their imported layers.

    Machines are repo-root target dirs that are not common-* layers. A machine
    dir without a configuration.nix is still listed if it has dotfiles/.
    """
    if not TARGETS_ROOT.is_dir():
        print(f"  Error: targets directory not found at {TARGETS_ROOT}")
        return []
    targets: list[str] = []
    for entry in discover_targets():
        if entry.name.startswith("common"):
            continue
        config_file = entry / "configuration.nix"
        if config_file.is_file():
            layers = get_imported_layers(config_file)
            if layers:
                targets.append(f"{entry.name} (layers: {' '.join(layers)})")
            else:
                targets.append(f"{entry.name} (no layers)")
        else:
            targets.append(f"{entry.name} (no configuration.nix)")
    return targets


def read_manifest(path: Path | None = None) -> dict[str, str] | None:
    """Read sync state manifest. Returns the symlinks dict or None if no manifest exists."""
    if path is None:
        path = STATE_FILE
    if not path.is_file():
        return None
    state = json.loads(path.read_text())
    return state.get("symlinks", {})


# ---------------------------------------------------------------------------
# Side-effecting logic (symlink creation/removal, sudo)
# ---------------------------------------------------------------------------


def _run_sudo(args: list[str]) -> None:
    """Run a sudo command, exiting cleanly on failure."""
    try:
        subprocess.run(["sudo", *args], check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error: sudo {' '.join(args)} failed with exit code {e.returncode}")
        sys.exit(1)


def create_or_update_symlinks(
    symlinks: list[tuple[Path, Path]], use_sudo: bool, force: bool
) -> list[tuple[Path, Path]]:
    """Create or update symlinks. Returns list of successfully created (target, source) pairs."""
    created: list[tuple[Path, Path]] = []
    skipped = 0
    for target, source in symlinks:
        target_dir = target.parent
        is_symlink = target.is_symlink()
        exists = target.exists()

        if use_sudo:
            _run_sudo(["mkdir", "-p", str(target_dir)])
            if is_symlink:
                _run_sudo(["rm", "-f", str(target)])
            elif exists:
                if force:
                    _run_sudo(["rm", "-f", str(target)])
                else:
                    print(f"  {yellow('skip')} {shorten_path(target)}")
                    skipped += 1
                    continue
            _run_sudo(["ln", "-s", str(source), str(target)])
        else:
            target_dir.mkdir(parents=True, exist_ok=True)
            if is_symlink:
                target.unlink()
            elif exists:
                if force:
                    target.unlink()
                else:
                    print(f"  {yellow('skip')} {shorten_path(target)}")
                    skipped += 1
                    continue
            try:
                target.symlink_to(source)
            except OSError as e:
                print(f"  {red('error')} {shorten_path(target)}: {e}")
                sys.exit(1)

        created.append((target, source))

    total = len(symlinks)
    summary = f"{green(str(len(created)))} created, {yellow(str(skipped))} skipped"
    print(f"  {summary}, {dim(f'{total} total')}")
    return created


def cleanup_empty_dirs(path: Path, stop_at: Path, use_sudo: bool = False) -> None:
    """Remove empty parent directories of path, up to (but not including) stop_at."""
    parent = path.parent
    while parent != stop_at and parent != parent.parent:
        if use_sudo:
            result = subprocess.run(["sudo", "rmdir", str(parent)], capture_output=True)
            if result.returncode != 0:
                break
        else:
            try:
                parent.rmdir()
            except OSError:
                break
        parent = parent.parent


def remove_symlinks(targets: list[str], use_sudo: bool) -> list[str]:
    """Remove symlinks at the given paths. Returns list of successfully removed paths."""
    removed: list[str] = []
    for target in targets:
        path = Path(target)
        if not path.is_symlink():
            continue
        if use_sudo:
            _run_sudo(["rm", "-f", str(path)])
        else:
            path.unlink()
        removed.append(target)
    if removed:
        print(f"  {red(str(len(removed)))} removed")
    return removed


def remove_paths(
    targets: list[str],
    use_sudo: bool,
    remove_dirs: bool = False,
) -> list[str]:
    """Remove symlinks, and (when ``remove_dirs``) real files or directories.

    Used for the personal skills bucket in copy mode, where stale
    ~/.agents/skills/<name> entries are real directories rather than symlinks.
    """
    removed: list[str] = []
    for target in targets:
        path = Path(target)
        if path.is_symlink() or path.is_file():
            if use_sudo:
                _run_sudo(["rm", "-f", str(path)])
            else:
                path.unlink()
            removed.append(target)
        elif remove_dirs and path.is_dir():
            if use_sudo:
                _run_sudo(["rm", "-rf", str(path)])
            else:
                shutil.rmtree(path)
            removed.append(target)
    if removed:
        print(f"  {red(str(len(removed)))} removed")
    return removed


def write_manifest(
    machine: str,
    symlinks: list[tuple[Path, Path]],
    state_file: Path | None = None,
) -> None:
    if state_file is None:
        state_file = STATE_FILE
    state = {
        "machine": machine,
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "symlinks": {str(target): str(source) for target, source in symlinks},
    }
    tmp_file = state_file.with_suffix(".json.tmp")
    tmp_file.write_text(json.dumps(state, indent=2) + "\n")
    os.replace(tmp_file, state_file)
    print(f"\nSync state written to {state_file}")


# ---------------------------------------------------------------------------
# CLI / I/O
# ---------------------------------------------------------------------------


def confirm(prompt: str) -> bool:
    """Yes/no confirmation. Single-keystroke on TTY, line-based otherwise."""
    if not sys.stdin.isatty():
        response = input(prompt)
        return response.lower() in ("y", "yes")
    print(prompt, end="", flush=True)
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        char = sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    print()
    return char.lower() == "y"


def _print_grouped(
    title: str,
    symlinks: list[tuple[Path, Path]],
    source_dir: Path,
    target_dir: Path,
    use_home_prefix: bool = False,
) -> None:
    """Print symlinks grouped by source layer with relative paths."""
    if not symlinks:
        return

    print(f"{bold(title)} {green(f'({len(symlinks)})')}:")

    for layer, items in group_by_layer(symlinks, source_dir).items():
        print(f"  {yellow(layer)} {dim(f'({len(items)})')}:")
        for target, _ in items:
            try:
                if use_home_prefix:
                    rel = target.relative_to(target_dir)
                    path_str = f"~/{rel}"
                else:
                    rel = target.relative_to(target_dir / layer)
                    path_str = str(rel)
            except ValueError:
                path_str = shorten_path(target)
            print(f"    {dim(path_str)}")

    print()


def _init_state(folder_name: str) -> None:
    """Write a manifest representing the old (all common-*) sync behavior.

    This lets machines that were synced before layer-aware syncing get a
    baseline manifest, so the next regular sync detects extra symlinks
    as stale and removes them.
    """
    for label, source_dir in [("NixOS", TARGETS_ROOT), ("dotfiles", TARGETS_ROOT)]:
        if not source_dir.is_dir():
            print(f"Error: {label} source directory not found at {source_dir}")
            sys.exit(1)

    all_common = sorted(d.name for d in discover_targets() if is_common_dir(d.name))
    nixos_symlinks = build_symlink_list(
        TARGETS_ROOT, NIXOS_TARGET, folder_name, all_common, strip_layer_prefix=False
    )
    dotfiles_symlinks = build_symlink_list(
        TARGETS_ROOT, DOTFILES_TARGET, folder_name, all_common, strip_layer_prefix=True
    )

    config_source = target_dir(folder_name) / "configuration.nix"
    if config_source.is_file():
        nixos_symlinks.append((NIXOS_TARGET / "configuration.nix", config_source))

    skill_symlinks = build_layered_skill_symlinks(
        TARGETS_ROOT, AGENTS_SKILLS_TARGET, folder_name, all_common
    )
    cc_personal_symlink = build_cc_personal_wiring(AGENTS_SKILLS_TARGET)
    work_skill_symlinks = build_work_skill_symlinks(SHARED_SKILLS_SOURCE, CLAUDE_WORK_SKILLS_TARGET)
    cog_symlinks = build_cog_symlinks(STEEL_COGS_SOURCE, STEEL_COGS_TARGET)

    all_symlinks = (
        nixos_symlinks
        + dotfiles_symlinks
        + skill_symlinks
        + cc_personal_symlink
        + work_skill_symlinks
        + cog_symlinks
    )
    total = len(all_symlinks)
    write_manifest(folder_name, all_symlinks)
    print(
        f"\nInitialized state with {total} symlinks (all common-* layers).\n"
        f"Run {bold(f'./sync.sh {folder_name}')} to sync with layer-awareness "
        f"and clean up stale symlinks."
    )


def main():
    parser = argparse.ArgumentParser(
        description="Create symlinks for NixOS configuration and dotfiles.",
        usage="%(prog)s <machine_name> [--force]",
    )
    parser.add_argument("machine", nargs="?", help="Machine name (e.g. redline, paprika)")
    parser.add_argument(
        "-f", "--force", action="store_true", help="Overwrite existing non-symlink files"
    )
    parser.add_argument(
        "--init-state",
        action="store_true",
        help="Write a manifest for the old (pre-layer-aware) sync behavior, "
        "so the next regular sync detects and removes stale symlinks",
    )
    args = parser.parse_args()

    if args.init_state:
        if not args.machine:
            print("Error: --init-state requires a machine name")
            sys.exit(1)
        _init_state(args.machine)
        return

    if not args.machine:
        print(f"Usage: {sys.argv[0]} <machine_name> [--force]\n")
        print("Creates symlinks for NixOS and dotfiles, then creates a symlink from")
        print(f"{NIXOS_TARGET}/configuration.nix to")
        print(f"{TARGETS_ROOT}/<target>/configuration.nix\n")
        print("Only the common-* layers that <target>/configuration.nix actually")
        print("imports (plus <target> itself) are symlinked. This mirrors the NixOS")
        print("import hierarchy so e.g. a headless machine won't receive desktop dotfiles.\n")
        print("Available targets:")
        for target in list_available_targets():
            print(f"  {target}")
        print("\nExamples:")
        print(f"  {sys.argv[0]} redline     # common-all + redline (headless)")
        print(f"  {sys.argv[0]} paprika      # all layers + paprika (desktop)")
        sys.exit(1)

    folder_name = args.machine

    # Check the targets root exists and contains targets
    if not TARGETS_ROOT.is_dir() or not discover_targets():
        print(f"Error: no targets found under {TARGETS_ROOT}")
        sys.exit(1)

    # Determine which common-* layers this machine imports
    config_path = target_dir(folder_name) / "configuration.nix"
    imported_layers = get_imported_layers(config_path)
    layers_str = " ".join(imported_layers) or "none"
    print(f"{bold('Imported layers:')} {cyan(layers_str)}\n")

    # Build the new sync-set
    nixos_symlinks = build_symlink_list(
        TARGETS_ROOT, NIXOS_TARGET, folder_name, imported_layers, strip_layer_prefix=False
    )
    dotfiles_symlinks = build_symlink_list(
        TARGETS_ROOT, DOTFILES_TARGET, folder_name, imported_layers, strip_layer_prefix=True
    )

    # Add the top-level configuration.nix symlink (the NixOS entry point).
    # This doesn't follow the layer/ path structure, so it's appended separately.
    config_source = target_dir(folder_name) / "configuration.nix"
    if not config_source.is_file():
        print(f"Error: Configuration file not found at {config_source}")
        sys.exit(1)
    nixos_symlinks.append((NIXOS_TARGET / "configuration.nix", config_source))

    # Materialise skills into the canonical ~/.agents/skills tree so Polytoken
    # discovers them, then wire Claude Code personal to that same tree with a
    # single ~/.claude/skills -> ~/.agents/skills directory symlink. Skills
    # follow the same layer hierarchy as the dotfiles, so a machine only gets
    # the skills for the layers it includes. In copy mode the skill dirs are
    # copied as real directories (Polytoken 0.6.4 skips skill dir symlinks).
    skill_symlinks = build_layered_skill_symlinks(
        TARGETS_ROOT, AGENTS_SKILLS_TARGET, folder_name, imported_layers
    )
    cc_personal_symlink = build_cc_personal_wiring(AGENTS_SKILLS_TARGET)

    # Symlink skills that opted in (via a .work-compatible marker) into the
    # work-account skills directory too, so the personal and work Claude Code
    # installs load the same skills. Only the shared common-dev skills are
    # considered — the same set every dev machine gets, regardless of layer
    # composition.
    work_skill_symlinks = build_work_skill_symlinks(SHARED_SKILLS_SOURCE, CLAUDE_WORK_SKILLS_TARGET)

    # Symlink Steel cogs into $STEEL_HOME/cogs for the plugin-enabled Helix.
    # These are common to all machines (helix-steel lives in common-all).
    cog_symlinks = build_cog_symlinks(STEEL_COGS_SOURCE, STEEL_COGS_TARGET)

    all_new_symlinks = (
        nixos_symlinks
        + dotfiles_symlinks
        + skill_symlinks
        + cc_personal_symlink
        + work_skill_symlinks
        + cog_symlinks
    )

    # Read previous manifest and compute stale symlinks
    previous = read_manifest(STATE_FILE)
    stale: list[str] = []
    if previous:
        stale = compute_stale_symlinks(previous, all_new_symlinks)

    # Display the proposed symlinks, grouped by layer
    _print_grouped("NixOS configuration", nixos_symlinks, TARGETS_ROOT, NIXOS_TARGET)
    _print_grouped(
        "Dotfiles", dotfiles_symlinks, TARGETS_ROOT, DOTFILES_TARGET, use_home_prefix=True
    )
    if skill_symlinks:
        label = "Agent skills (personal)"
        if AGENT_SKILLS_COPY_MODE:
            label += " [copied]"
        print(f"{bold(label)} {green(f'({len(skill_symlinks)})')}:")
        print(f"  {yellow('agents-skills')} {dim(f'({len(skill_symlinks)})')}:")
        for target, _ in skill_symlinks:
            print(f"    {dim(shorten_path(target))}")
        print()
        if cc_personal_symlink:
            n = len(cc_personal_symlink)
            print(f"{bold('Claude Code personal wiring')} {green(f'({n})')}:")
            print(f"  {yellow('claude-skills')} {dim(f'({n})')}:")
            for target, _ in cc_personal_symlink:
                print(f"    {dim(shorten_path(target))}")
            print()
    if work_skill_symlinks:
        print(f"{bold('Claude Code skills (work)')} {green(f'({len(work_skill_symlinks)})')}:")
        print(f"  {yellow('agents-skills')} {dim(f'({len(work_skill_symlinks)})')}:")
        for target, _ in work_skill_symlinks:
            print(f"    {dim(shorten_path(target))}")
        print()
    if cog_symlinks:
        print(f"{bold('Steel cogs')} {green(f'({len(cog_symlinks)})')}:")
        print(f"  {yellow('steel-cogs')} {dim(f'({len(cog_symlinks)})')}:")
        for target, _ in cog_symlinks:
            print(f"    {dim(shorten_path(target))}")
        print()

    # Display stale symlinks
    if stale:
        nixos_stale, dotfile_stale = split_by_target(stale, NIXOS_TARGET, DOTFILES_TARGET)
        cc_skills_stale, work_skills_stale, remaining_stale = classify_stale(
            dotfile_stale,
            cc_targets=[CC_SKILLS_TARGET, AGENTS_SKILLS_TARGET],
            work_targets=[CLAUDE_WORK_SKILLS_TARGET],
        )
        total = len(stale)
        print(f"{bold('Stale symlinks to remove')} {red(f'({total})')}:")
        if nixos_stale:
            print(f"  {dim('NixOS')} ({len(nixos_stale)}):")
            for path in sorted(nixos_stale):
                rel = str(Path(path).relative_to(NIXOS_TARGET))
                print(f"    {dim(rel)}")
        if cc_skills_stale:
            print(f"  {dim('Claude Code skills')} ({len(cc_skills_stale)}):")
            for path in sorted(cc_skills_stale):
                print(f"    {dim(shorten_path(path))}")
        if work_skills_stale:
            print(f"  {dim('Claude Code skills (work)')} ({len(work_skills_stale)}):")
            for path in sorted(work_skills_stale):
                print(f"    {dim(shorten_path(path))}")
        if remaining_stale:
            print(f"  {dim('Dotfiles')} ({len(remaining_stale)}):")
            for path in sorted(remaining_stale):
                print(f"    {dim(shorten_path(path))}")
        print()

    # Show conflicts
    skill_conflict_exempt = [AGENTS_SKILLS_TARGET] if AGENT_SKILLS_COPY_MODE else None
    all_conflicts = (
        find_conflicts(nixos_symlinks)
        + find_conflicts(dotfiles_symlinks)
        + find_conflicts(skill_symlinks, exempt_targets=skill_conflict_exempt)
        + find_conflicts(work_skill_symlinks)
        + find_conflicts(cog_symlinks)
    )
    if all_conflicts:
        print(f"{bold('Conflicts')} {red(f'({len(all_conflicts)})')}:")
        for path in all_conflicts:
            print(f"  {red(shorten_path(path))}")
        print()
        if not args.force:
            msg = "Use --force / -f to overwrite them. Without it, these files will be skipped."
            print(dim(msg))
            print()

    # Ask for confirmation
    if not confirm("Are these symlinks OK? (y/n) "):
        print("Operation cancelled.")
        sys.exit(0)

    apply_sync_changes(
        nixos_symlinks=nixos_symlinks,
        dotfiles_symlinks=dotfiles_symlinks,
        skill_symlinks=skill_symlinks,
        cc_personal_symlink=cc_personal_symlink,
        work_skill_symlinks=work_skill_symlinks,
        cog_symlinks=cog_symlinks,
        stale=stale,
        force=args.force,
        machine=folder_name,
    )
    print(f"\n{green('✓')} Sync complete!")


def apply_sync_changes(
    *,
    nixos_symlinks: list[tuple[Path, Path]],
    dotfiles_symlinks: list[tuple[Path, Path]],
    skill_symlinks: list[tuple[Path, Path]],
    cc_personal_symlink: list[tuple[Path, Path]],
    work_skill_symlinks: list[tuple[Path, Path]],
    cog_symlinks: list[tuple[Path, Path]],
    stale: list[str] | None,
    force: bool,
    nixos_target: Path = NIXOS_TARGET,
    dotfiles_target: Path = DOTFILES_TARGET,
    cc_skills_target: Path = CC_SKILLS_TARGET,
    agents_skills_target: Path = AGENTS_SKILLS_TARGET,
    work_skills_target: Path = CLAUDE_WORK_SKILLS_TARGET,
    copy_mode: bool = AGENT_SKILLS_COPY_MODE,
    machine: str | None = None,
) -> list[tuple[Path, Path]]:
    """Create/update symlinks and remove stale ones, in the required order.

    Stale symlinks are removed FIRST, before any new skill symlinks are
    created: on the first sync after the skills-layout change ~/.claude/skills
    is a real directory holding old per-skill leaf symlinks. Those leaves must
    be unlinked (and the now-empty dir removed) before ~/.claude/skills can
    become the ~/.claude/skills -> ~/.agents/skills directory symlink;
    otherwise remove_symlinks would resolve *through* the new dir symlink and
    delete freshly-created ~/.agents/skills/<name> targets, and the force-path
    unlink on the real dir would raise IsADirectoryError.

    When ``copy_mode`` is true, the personal skills are copied into
    ~/.agents/skills as real directories instead of symlinked (Polytoken 0.6.4
    skips skill directory symlinks). The ~/.claude/skills -> ~/.agents/skills
    wiring and the stale-removal order are unchanged.

    When ``machine`` is given, the combined created set is written to the sync
    manifest (in a finally, so a partial failure still records what ran).
    Returns the combined list of created symlinks.
    """
    created_nixos: list[tuple[Path, Path]] = []
    created_dotfiles: list[tuple[Path, Path]] = []
    created_skills: list[tuple[Path, Path]] = []
    created_cc_personal: list[tuple[Path, Path]] = []
    created_work_skills: list[tuple[Path, Path]] = []
    created_cogs: list[tuple[Path, Path]] = []

    try:
        if stale:
            print(bold("Stale symlinks"))
            nixos_stale, dotfile_stale = split_by_target(stale, nixos_target, dotfiles_target)
            cc_skills_stale, work_skills_stale, remaining_stale = classify_stale(
                dotfile_stale,
                cc_targets=[cc_skills_target, agents_skills_target],
                work_targets=[work_skills_target],
            )
            if nixos_stale:
                print(f"  {dim('NixOS:')}")
                remove_symlinks(nixos_stale, use_sudo=True)
                for path in nixos_stale:
                    cleanup_empty_dirs(Path(path), nixos_target, use_sudo=True)
            if remaining_stale:
                print(f"  {dim('Dotfiles:')}")
                remove_symlinks(remaining_stale, use_sudo=False)
                for path in remaining_stale:
                    cleanup_empty_dirs(Path(path), dotfiles_target, use_sudo=False)
            if cc_skills_stale:
                print(f"  {dim('Claude Code skills:')}")
                remove_paths(cc_skills_stale, use_sudo=False, remove_dirs=copy_mode)
                for path in cc_skills_stale:
                    cleanup_empty_dirs(Path(path), dotfiles_target, use_sudo=False)
            if work_skills_stale:
                print(f"  {dim('Claude Code skills (work):')}")
                remove_symlinks(work_skills_stale, use_sudo=False)
                for path in work_skills_stale:
                    cleanup_empty_dirs(Path(path), dotfiles_target, use_sudo=False)

        print(bold("NixOS configuration"))
        created_nixos = create_or_update_symlinks(nixos_symlinks, use_sudo=True, force=force)

        print(bold("Dotfiles"))
        created_dotfiles = create_or_update_symlinks(dotfiles_symlinks, use_sudo=False, force=force)

        if skill_symlinks:
            label = "Agent skills (personal)"
            if copy_mode:
                label += " [copied]"
            print(bold(label))
            if copy_mode:
                if date.today() >= AGENT_SKILLS_COPY_MODE_EXPIRY:
                    raise SystemExit(f"Error: {AGENT_SKILLS_COPY_MODE_EXPIRY_MSG}")
                for target, source in skill_symlinks:
                    copy_skill_tree(source, target)
                    created_skills.append((target, source))
            else:
                created_skills = create_or_update_symlinks(
                    skill_symlinks, use_sudo=False, force=force
                )

        if cc_personal_symlink:
            print(bold("Claude Code personal wiring"))
            created_cc_personal = create_or_update_symlinks(
                cc_personal_symlink, use_sudo=False, force=force
            )

        if work_skill_symlinks:
            print(bold("Claude Code skills (work)"))
            created_work_skills = create_or_update_symlinks(
                work_skill_symlinks, use_sudo=False, force=force
            )

        if cog_symlinks:
            print(bold("Steel cogs"))
            created_cogs = create_or_update_symlinks(cog_symlinks, use_sudo=False, force=force)

    finally:
        all_created = (
            created_nixos
            + created_dotfiles
            + created_skills
            + created_cc_personal
            + created_work_skills
            + created_cogs
        )
        if machine is not None and all_created:
            write_manifest(machine, all_created)
    return all_created


if __name__ == "__main__":
    main()
