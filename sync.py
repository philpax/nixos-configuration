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
from datetime import datetime, timezone
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent
NIXOS_SOURCE = REPO_DIR / "nixos"
DOTFILES_SOURCE = REPO_DIR / "dotfiles"
NIXOS_TARGET = Path("/etc/nixos")
DOTFILES_TARGET = Path.home()
STATE_FILE = REPO_DIR / ".sync-state.json"

LAYER_IMPORT_RE = re.compile(r"\.\./(common-[a-z-]+)")


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


# ---------------------------------------------------------------------------
# Filesystem-reading logic (testable with tmp_path)
# ---------------------------------------------------------------------------


def get_imported_layers(config_path: Path) -> list[str]:
    """Read a machine's configuration.nix and extract its common-* layer imports."""
    if not config_path.is_file():
        return []
    return parse_imported_layers(config_path.read_text())


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


def read_manifest(path: Path = STATE_FILE) -> dict[str, str] | None:
    """Read sync state manifest. Returns the symlinks dict or None if no manifest exists."""
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
                    print(f"Warning: {target} already exists and is not a symlink. Skipping.")
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
                    print(f"Warning: {target} already exists and is not a symlink. Skipping.")
                    continue
            try:
                target.symlink_to(source)
            except OSError as e:
                print(f"Error: failed to create symlink {target} -> {source}: {e}")
                sys.exit(1)

        print(f"Created/Updated symlink: {target} -> {source}")
        created.append((target, source))

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
        print(f"Removed stale symlink: {path}")
        removed.append(target)
    return removed


def create_config_symlink(
    folder_name: str,
    nixos_source: Path = NIXOS_SOURCE,
    nixos_target: Path = NIXOS_TARGET,
) -> tuple[Path, Path] | None:
    source = nixos_source / folder_name / "configuration.nix"
    target = nixos_target / "configuration.nix"

    if not source.is_file():
        print(f"Error: Configuration file not found at {source}")
        return None

    print(f"Creating symlink: {target} -> {source}")
    _run_sudo(["ln", "-sf", str(source), str(target)])
    print("Symlink created successfully!")
    return (target, source)


def write_manifest(
    machine: str,
    symlinks: list[tuple[Path, Path]],
    state_file: Path = STATE_FILE,
) -> None:
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


def main():
    parser = argparse.ArgumentParser(
        description="Create symlinks for NixOS configuration and dotfiles.",
        usage="%(prog)s <machine_name> [--force]",
    )
    parser.add_argument("machine", nargs="?", help="Machine name (e.g. redline, paprika)")
    parser.add_argument(
        "-f", "--force", action="store_true", help="Overwrite existing non-symlink files"
    )
    args = parser.parse_args()

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
    print(f"Imported layers for {folder_name}: {' '.join(imported_layers) or 'none'}\n")

    # Build the new sync-set
    nixos_symlinks = build_symlink_list(
        NIXOS_SOURCE, NIXOS_TARGET, folder_name, imported_layers, strip_layer_prefix=False
    )
    dotfiles_symlinks = build_symlink_list(
        DOTFILES_SOURCE, DOTFILES_TARGET, folder_name, imported_layers, strip_layer_prefix=True
    )
    all_new_symlinks = nixos_symlinks + dotfiles_symlinks

    # Read previous manifest and compute stale symlinks
    previous = read_manifest(STATE_FILE)
    stale: list[str] = []
    if previous:
        stale = compute_stale_symlinks(previous, all_new_symlinks)

    # Display the proposed symlinks
    print("Proposed symlinks for NixOS configuration:")
    for target, source in nixos_symlinks:
        print(f"  {target} -> {source}")
    print()

    print("Proposed symlinks for dotfiles:")
    for target, source in dotfiles_symlinks:
        print(f"  {target} -> {source}")
    print()

    # Display stale symlinks
    if stale:
        print("The following symlinks from a previous sync are no longer needed:")
        for path in stale:
            print(f"  {path}")
        print()

    # Show conflicts
    all_conflicts = find_conflicts(nixos_symlinks) + find_conflicts(dotfiles_symlinks)
    if all_conflicts:
        print("The following existing files (not symlinks) would be overwritten:")
        for path in all_conflicts:
            print(f"  {path}")
        print()
        if not args.force:
            print("Use --force / -f to overwrite them. Without it, these files will be skipped.")
            print()

    # Ask for confirmation
    if not confirm("Are these symlinks OK? (y/n) "):
        print("Operation cancelled.")
        sys.exit(0)

    # Create/Update symlinks — collect what was created even on partial failure
    created_nixos: list[tuple[Path, Path]] = []
    created_dotfiles: list[tuple[Path, Path]] = []
    config_symlink: tuple[Path, Path] | None = None

    try:
        print("\nCreating/Updating symlinks for NixOS configuration...")
        created_nixos = create_or_update_symlinks(nixos_symlinks, use_sudo=True, force=args.force)

        print("\nCreating/Updating symlinks for dotfiles...")
        created_dotfiles = create_or_update_symlinks(
            dotfiles_symlinks, use_sudo=False, force=args.force
        )

        print("\nSymlinking complete!")

        # Remove stale symlinks
        if stale:
            print("\nRemoving stale symlinks...")
            nixos_stale, dotfile_stale = split_by_target(stale, NIXOS_TARGET, DOTFILES_TARGET)
            if nixos_stale:
                remove_symlinks(nixos_stale, use_sudo=True)
                for path in nixos_stale:
                    cleanup_empty_dirs(Path(path), NIXOS_TARGET, use_sudo=True)
            if dotfile_stale:
                remove_symlinks(dotfile_stale, use_sudo=False)
                for path in dotfile_stale:
                    cleanup_empty_dirs(Path(path), DOTFILES_TARGET, use_sudo=False)

        # Create configuration.nix symlink
        print("\nCreating configuration.nix symlink...")
        config_symlink = create_config_symlink(folder_name)
        if config_symlink is None:
            sys.exit(1)

    finally:
        # Always write manifest, even on partial failure
        all_created = created_nixos + created_dotfiles
        if config_symlink:
            all_created.append(config_symlink)
        if all_created:
            write_manifest(folder_name, all_created)


if __name__ == "__main__":
    main()
