#!/usr/bin/env python3
"""Sync NixOS configuration and dotfiles via symlinks.

Creates symlinks for NixOS (common-* + <machine>) and dotfiles (common-* + <machine>),
then symlinks /etc/nixos/configuration.nix to the machine's configuration.nix.

Tracks all synced symlinks in .sync-state.json for later cleanup.
"""

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent
NIXOS_SOURCE = REPO_DIR / "nixos"
DOTFILES_SOURCE = REPO_DIR / "dotfiles"
NIXOS_TARGET = Path("/etc/nixos")
DOTFILES_TARGET = Path.home()
STATE_FILE = REPO_DIR / ".sync-state.json"


def is_common_dir(name: str) -> bool:
    return name.startswith("common-")


def list_available_targets() -> list[str]:
    if not NIXOS_SOURCE.is_dir():
        return []
    targets = []
    for entry in sorted(NIXOS_SOURCE.iterdir()):
        if not entry.is_dir() or entry.name.startswith("common"):
            continue
        config_file = entry / "configuration.nix"
        if config_file.is_file():
            targets.append(entry.name)
        else:
            targets.append(f"{entry.name} (no configuration.nix)")
    return targets


def build_symlink_list(source_dir: Path, target_dir: Path, folder_name: str) -> list[tuple[Path, Path]]:
    """Build list of (target, source) pairs for files to symlink.

    Only includes files from common-* directories and the specified folder.
    For dotfiles, strips the first directory component (layer name).
    """
    symlinks = []
    for source_path in sorted(source_dir.rglob("*")):
        if not source_path.is_file():
            continue

        relative = source_path.relative_to(source_dir)
        first_part = relative.parts[0]

        if not (is_common_dir(first_part) or first_part == folder_name):
            continue

        if source_dir == DOTFILES_SOURCE:
            relative = Path(*relative.parts[1:])

        target_path = target_dir / relative
        symlinks.append((target_path, source_path))

    return symlinks


def find_conflicts(symlinks: list[tuple[Path, Path]]) -> list[Path]:
    """Find existing non-symlink files that would be overwritten."""
    conflicts = []
    for target, _ in symlinks:
        if target.exists() and not target.is_symlink():
            conflicts.append(target)
    return conflicts


def create_or_update_symlinks(
    symlinks: list[tuple[Path, Path]], use_sudo: bool, force: bool
) -> list[tuple[Path, Path]]:
    """Create or update symlinks. Returns list of successfully created (target, source) pairs."""
    created = []
    for target, source in symlinks:
        target_dir = target.parent
        is_symlink = target.is_symlink()
        exists = target.exists()

        if use_sudo:
            subprocess.run(["sudo", "mkdir", "-p", str(target_dir)], check=True)
            if is_symlink:
                subprocess.run(["sudo", "rm", "-f", str(target)], check=True)
            elif exists:
                if force:
                    subprocess.run(["sudo", "rm", "-f", str(target)], check=True)
                else:
                    print(f"Warning: {target} already exists and is not a symlink. Skipping.")
                    continue
            subprocess.run(["sudo", "ln", "-s", str(source), str(target)], check=True)
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
            target.symlink_to(source)

        print(f"Created/Updated symlink: {target} -> {source}")
        created.append((target, source))

    return created


def create_config_symlink(folder_name: str) -> tuple[Path, Path] | None:
    source = NIXOS_SOURCE / folder_name / "configuration.nix"
    target = NIXOS_TARGET / "configuration.nix"

    if not source.is_file():
        print(f"Error: Configuration file not found at {source}")
        return None

    print(f"Creating symlink: {target} -> {source}")
    subprocess.run(["sudo", "ln", "-sf", str(source), str(target)], check=True)
    print("Symlink created successfully!")
    return (target, source)


def write_manifest(machine: str, symlinks: list[tuple[Path, Path]]):
    state = {
        "machine": machine,
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "symlinks": {str(target): str(source) for target, source in symlinks},
    }
    STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")
    print(f"\nSync state written to {STATE_FILE}")


def main():
    parser = argparse.ArgumentParser(
        description="Create symlinks for NixOS configuration and dotfiles.",
        usage="%(prog)s <machine_name> [--force]",
    )
    parser.add_argument("machine", nargs="?", help="Machine name (e.g. redline, paprika)")
    parser.add_argument("-f", "--force", action="store_true", help="Overwrite existing non-symlink files")
    args = parser.parse_args()

    if not args.machine:
        print(f"Usage: {sys.argv[0]} <machine_name> [--force]\n")
        print("Creates symlinks for NixOS (only 'common-*' and '<machine_name>' folders) and dotfiles")
        print("(only 'common-*' and '<machine_name>' folders), then creates a symlink from")
        print(f"{NIXOS_TARGET}/configuration.nix to {NIXOS_SOURCE}/<machine_name>/configuration.nix\n")
        print("Note: Only the 'common-*' and specified '<machine_name>' folders will be symlinked")
        print("from both the NixOS and dotfiles source directories.\n")
        print("Available targets:")
        for target in list_available_targets():
            print(f"  {target}")
        print(f"\nExamples:")
        print(f"  {sys.argv[0]} <target>   # Create symlinks for 'common-*' + '<target>' for NixOS and dotfiles")
        sys.exit(1)

    folder_name = args.machine

    # Build the lists of proposed symlinks
    nixos_symlinks = build_symlink_list(NIXOS_SOURCE, NIXOS_TARGET, folder_name)
    dotfiles_symlinks = build_symlink_list(DOTFILES_SOURCE, DOTFILES_TARGET, folder_name)

    # Display the proposed symlinks
    print("Proposed symlinks for NixOS configuration:")
    for target, source in nixos_symlinks:
        print(f"  {target} -> {source}")
    print()

    print("Proposed symlinks for dotfiles:")
    for target, source in dotfiles_symlinks:
        print(f"  {target} -> {source}")
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
    response = input("Are these symlinks OK? (y/n) ")
    if response.lower() not in ("y", "yes"):
        print("Operation cancelled.")
        sys.exit(0)

    # Create/Update symlinks
    print(f"\nCreating/Updating symlinks for NixOS configuration (common-* + {folder_name})...")
    created_nixos = create_or_update_symlinks(nixos_symlinks, use_sudo=True, force=args.force)

    print(f"\nCreating/Updating symlinks for dotfiles (common-* + {folder_name})...")
    created_dotfiles = create_or_update_symlinks(dotfiles_symlinks, use_sudo=False, force=args.force)

    print("\nSymlinking complete!")

    # Create configuration.nix symlink
    print("\nCreating configuration.nix symlink...")
    config_symlink = create_config_symlink(folder_name)

    # Write sync state
    all_created = created_nixos + created_dotfiles
    if config_symlink:
        all_created.append(config_symlink)
    write_manifest(folder_name, all_created)


if __name__ == "__main__":
    main()
