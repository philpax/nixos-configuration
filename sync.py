#!/usr/bin/env python3
"""Sync NixOS configuration and dotfiles via symlinks.

Creates symlinks for NixOS (common-* + <machine>) and dotfiles (common-* + <machine>),
then symlinks /etc/nixos/configuration.nix to the machine's configuration.nix.

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
import subprocess
import sys
import termios
import tty
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent
NIXOS_SOURCE = REPO_DIR / "nixos"
DOTFILES_SOURCE = REPO_DIR / "dotfiles"
NIXOS_TARGET = Path("/etc/nixos")
DOTFILES_TARGET = Path.home()
STATE_FILE = REPO_DIR / ".sync-state.json"

# Polytoken skills are the source of truth; these are symlinked into
# Claude Code's personal skills directory (~/.claude/skills/<name>) so CC
# loads the same skills. CC follows directory-level symlinks to read SKILL.md.
# Skills live per-layer at <layer>/.config/polytoken/skills/<name>, so which
# skills a machine gets follows the same layer hierarchy as the dotfiles —
# e.g. redline's llama-cpp-model-tuning skill only syncs to machines that
# include the redline layer.
POLYTOKEN_SKILLS_SUBPATH = Path(".config") / "polytoken" / "skills"
POLYTOKEN_SKILLS_SOURCE = DOTFILES_SOURCE / "common-all" / POLYTOKEN_SKILLS_SUBPATH
CC_SKILLS_TARGET = Path.home() / ".claude" / "skills"

# Steel plugins ("cogs") for the plugin-enabled Helix fork are git submodules under
# steel-cogs/. Each is directory-symlinked into steel's cog root ($STEEL_HOME/cogs; STEEL_HOME
# is pinned to ~/.config/steel in the fish config) so `(require "forest/...")` resolves. They
# live outside dotfiles/ so the per-file dotfiles flow doesn't also grab their
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
    source_dir: Path,
    target_dir: Path,
    folder_name: str,
    allowed_layers: list[str],
    strip_layer_prefix: bool = False,
) -> list[tuple[Path, Path]]:
    """Build list of (target, source) pairs for files to symlink.

    Only includes files from the allowed layers and the specified folder.
    If strip_layer_prefix is True, strips the first directory component
    (the layer name) from the relative path — used for dotfiles.
    """
    if not source_dir.is_dir():
        raise FileNotFoundError(f"Source directory not found: {source_dir}")

    allowed = {folder_name, *allowed_layers}
    symlinks: list[tuple[Path, Path]] = []

    for source_path in sorted(source_dir.rglob("*")):
        # Skip symlinks and non-files (match `find -type f` semantics)
        if source_path.is_symlink() or not source_path.is_file():
            continue

        relative = source_path.relative_to(source_dir)
        first_part = relative.parts[0]

        if first_part not in allowed:
            continue

        if strip_layer_prefix:
            if len(relative.parts) < 2:
                relative = Path(relative.name)
            else:
                relative = relative.relative_to(first_part)

        target_path = target_dir / relative
        symlinks.append((target_path, source_path))

    return symlinks


def build_skill_symlinks(
    source_dir: Path,
    target_dir: Path,
) -> list[tuple[Path, Path]]:
    """Build (target, source) pairs for Polytoken skill directories.

    Each immediate subdirectory of ``source_dir`` that contains a ``SKILL.md``
    becomes a directory-level symlink at ``target_dir/<skill_name>``.
    This lets Claude Code load the same skills Polytoken uses.
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


def build_layered_skill_symlinks(
    dotfiles_source: Path,
    target_dir: Path,
    folder_name: str,
    allowed_layers: list[str],
) -> list[tuple[Path, Path]]:
    """Collect Polytoken skill symlinks across every layer the machine syncs.

    Skills are stored per-layer at ``<layer>/.config/polytoken/skills/<name>``,
    so a machine only gets a skill if it includes that layer — mirroring the
    dotfiles hierarchy. When two layers define a skill of the same name, the
    machine-specific layer wins over the shared common-* layers.
    """
    # common-* layers first so a machine-specific layer of the same name wins.
    layers = [*allowed_layers, folder_name]
    by_target: dict[Path, Path] = {}
    for layer in layers:
        skills_dir = dotfiles_source / layer / POLYTOKEN_SKILLS_SUBPATH
        for target, source in build_skill_symlinks(skills_dir, target_dir):
            by_target[target] = source
    return sorted(by_target.items())


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


def find_conflicts(symlinks: list[tuple[Path, Path]]) -> list[Path]:
    """Find existing non-symlink files that would be overwritten."""
    conflicts: list[Path] = []
    for target, _ in symlinks:
        if target.exists() and not target.is_symlink():
            conflicts.append(target)
    return conflicts


def list_available_targets(nixos_source: Path = NIXOS_SOURCE) -> list[str]:
    """List non-common machine directories, annotated with their imported layers."""
    if not nixos_source.is_dir():
        print(f"  Error: NIXOS_SOURCE directory not found at {nixos_source}")
        return []
    targets: list[str] = []
    for entry in sorted(nixos_source.iterdir()):
        if not entry.is_dir() or entry.name.startswith("common"):
            continue
        config_file = entry / "configuration.nix"
        if config_file.is_file():
            layers = get_imported_layers(config_file)
            if layers:
                targets.append(f"{entry.name} (layers: {' '.join(layers)})")
            else:
                targets.append(entry.name)
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
    for label, source_dir in [("NixOS", NIXOS_SOURCE), ("dotfiles", DOTFILES_SOURCE)]:
        if not source_dir.is_dir():
            print(f"Error: {label} source directory not found at {source_dir}")
            sys.exit(1)

    all_common = sorted(
        d.name for d in NIXOS_SOURCE.iterdir() if d.is_dir() and is_common_dir(d.name)
    )
    nixos_symlinks = build_symlink_list(
        NIXOS_SOURCE, NIXOS_TARGET, folder_name, all_common, strip_layer_prefix=False
    )
    dotfiles_symlinks = build_symlink_list(
        DOTFILES_SOURCE, DOTFILES_TARGET, folder_name, all_common, strip_layer_prefix=True
    )

    config_source = NIXOS_SOURCE / folder_name / "configuration.nix"
    if config_source.is_file():
        nixos_symlinks.append((NIXOS_TARGET / "configuration.nix", config_source))

    skill_symlinks = build_skill_symlinks(POLYTOKEN_SKILLS_SOURCE, CC_SKILLS_TARGET)
    cog_symlinks = build_cog_symlinks(STEEL_COGS_SOURCE, STEEL_COGS_TARGET)

    all_symlinks = nixos_symlinks + dotfiles_symlinks + skill_symlinks + cog_symlinks
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
        print(f"{NIXOS_SOURCE}/<machine_name>/configuration.nix\n")
        print("Only the common-* layers that <machine_name>/configuration.nix actually")
        print("imports (plus <machine_name> itself) are symlinked. This mirrors the NixOS")
        print("import hierarchy so e.g. a headless machine won't receive desktop dotfiles.\n")
        print("Available targets:")
        for target in list_available_targets():
            print(f"  {target}")
        print("\nExamples:")
        print(f"  {sys.argv[0]} redline     # common-all + redline (headless)")
        print(f"  {sys.argv[0]} paprika      # all layers + paprika (desktop)")
        sys.exit(1)

    folder_name = args.machine

    # Check source dirs exist
    for label, source_dir in [("NixOS", NIXOS_SOURCE), ("dotfiles", DOTFILES_SOURCE)]:
        if not source_dir.is_dir():
            print(f"Error: {label} source directory not found at {source_dir}")
            sys.exit(1)

    # Determine which common-* layers this machine imports
    config_path = NIXOS_SOURCE / folder_name / "configuration.nix"
    imported_layers = get_imported_layers(config_path)
    layers_str = " ".join(imported_layers) or "none"
    print(f"{bold('Imported layers:')} {cyan(layers_str)}\n")

    # Build the new sync-set
    nixos_symlinks = build_symlink_list(
        NIXOS_SOURCE, NIXOS_TARGET, folder_name, imported_layers, strip_layer_prefix=False
    )
    dotfiles_symlinks = build_symlink_list(
        DOTFILES_SOURCE, DOTFILES_TARGET, folder_name, imported_layers, strip_layer_prefix=True
    )

    # Add the top-level configuration.nix symlink (the NixOS entry point).
    # This doesn't follow the layer/ path structure, so it's appended separately.
    config_source = NIXOS_SOURCE / folder_name / "configuration.nix"
    if not config_source.is_file():
        print(f"Error: Configuration file not found at {config_source}")
        sys.exit(1)
    nixos_symlinks.append((NIXOS_TARGET / "configuration.nix", config_source))

    # Symlink Polytoken skills into Claude Code's skills directory so CC
    # loads the same skills. Skills follow the same layer hierarchy as the
    # dotfiles, so a machine only gets the skills for the layers it includes.
    skill_symlinks = build_layered_skill_symlinks(
        DOTFILES_SOURCE, CC_SKILLS_TARGET, folder_name, imported_layers
    )

    # Symlink Steel cogs into $STEEL_HOME/cogs for the plugin-enabled Helix.
    # These are common to all machines (helix-steel lives in common-all).
    cog_symlinks = build_cog_symlinks(STEEL_COGS_SOURCE, STEEL_COGS_TARGET)

    all_new_symlinks = nixos_symlinks + dotfiles_symlinks + skill_symlinks + cog_symlinks

    # Read previous manifest and compute stale symlinks
    previous = read_manifest(STATE_FILE)
    stale: list[str] = []
    if previous:
        stale = compute_stale_symlinks(previous, all_new_symlinks)

    # Display the proposed symlinks, grouped by layer
    _print_grouped("NixOS configuration", nixos_symlinks, NIXOS_SOURCE, NIXOS_TARGET)
    _print_grouped(
        "Dotfiles", dotfiles_symlinks, DOTFILES_SOURCE, DOTFILES_TARGET, use_home_prefix=True
    )
    if skill_symlinks:
        print(f"{bold('Claude Code skills')} {green(f'({len(skill_symlinks)})')}:")
        print(f"  {yellow('polytoken-skills')} {dim(f'({len(skill_symlinks)})')}:")
        for target, _ in skill_symlinks:
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
        total = len(stale)
        print(f"{bold('Stale symlinks to remove')} {red(f'({total})')}:")
        if nixos_stale:
            print(f"  {dim('NixOS')} ({len(nixos_stale)}):")
            for path in sorted(nixos_stale):
                rel = str(Path(path).relative_to(NIXOS_TARGET))
                print(f"    {dim(rel)}")
        if dotfile_stale:
            print(f"  {dim('Dotfiles')} ({len(dotfile_stale)}):")
            for path in sorted(dotfile_stale):
                print(f"    {dim(shorten_path(path))}")
        print()

    # Show conflicts
    all_conflicts = (
        find_conflicts(nixos_symlinks)
        + find_conflicts(dotfiles_symlinks)
        + find_conflicts(skill_symlinks)
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

    # Create/Update symlinks — collect what was created even on partial failure
    created_nixos: list[tuple[Path, Path]] = []
    created_dotfiles: list[tuple[Path, Path]] = []
    created_skills: list[tuple[Path, Path]] = []
    created_cogs: list[tuple[Path, Path]] = []

    try:
        print(bold("NixOS configuration"))
        created_nixos = create_or_update_symlinks(nixos_symlinks, use_sudo=True, force=args.force)

        print(bold("Dotfiles"))
        created_dotfiles = create_or_update_symlinks(
            dotfiles_symlinks, use_sudo=False, force=args.force
        )

        if skill_symlinks:
            print(bold("Claude Code skills"))
            created_skills = create_or_update_symlinks(
                skill_symlinks, use_sudo=False, force=args.force
            )

        if cog_symlinks:
            print(bold("Steel cogs"))
            created_cogs = create_or_update_symlinks(cog_symlinks, use_sudo=False, force=args.force)

        # Remove stale symlinks
        if stale:
            print(bold("Stale symlinks"))
            nixos_stale, dotfile_stale = split_by_target(stale, NIXOS_TARGET, DOTFILES_TARGET)
            if nixos_stale:
                print(f"  {dim('NixOS:')}")
                remove_symlinks(nixos_stale, use_sudo=True)
                for path in nixos_stale:
                    cleanup_empty_dirs(Path(path), NIXOS_TARGET, use_sudo=True)
            if dotfile_stale:
                print(f"  {dim('Dotfiles:')}")
                remove_symlinks(dotfile_stale, use_sudo=False)
                for path in dotfile_stale:
                    cleanup_empty_dirs(Path(path), DOTFILES_TARGET, use_sudo=False)

        print(f"\n{green('✓')} Sync complete!")

    finally:
        all_created = created_nixos + created_dotfiles + created_skills + created_cogs
        if all_created:
            write_manifest(folder_name, all_created)


if __name__ == "__main__":
    main()
