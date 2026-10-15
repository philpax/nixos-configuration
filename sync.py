#!/usr/bin/env python3
"""Select and confirm shared sync plans for NixOS and home-only targets."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import replace
from pathlib import Path

import sync_engine
from home_sync import apply_home_sync, plan_home_sync
from sync_workflow import AGENTS_SKILLS_SUBPATH as AGENTS_SKILLS_SUBPATH
from sync_workflow import CLAUDE_PLUGINS_SUBPATH as CLAUDE_PLUGINS_SUBPATH
from sync_workflow import WORK_COMPATIBLE_MARKER as WORK_COMPATIBLE_MARKER
from sync_workflow import ask_confirmation as confirm
from sync_workflow import bold as bold
from sync_workflow import build_cog_symlinks as build_cog_symlinks
from sync_workflow import build_layered_plugin_symlinks as build_layered_plugin_symlinks
from sync_workflow import build_layered_skill_symlinks as build_layered_skill_symlinks
from sync_workflow import build_skill_symlinks as build_skill_symlinks
from sync_workflow import build_symlink_list as build_symlink_list
from sync_workflow import build_work_skill_symlinks as build_work_skill_symlinks
from sync_workflow import collect_links, describe_sync_plan, run_sync
from sync_workflow import cyan as cyan
from sync_workflow import dim as dim
from sync_workflow import green as green
from sync_workflow import red as red
from sync_workflow import yellow as yellow

REPO_DIR = Path(__file__).resolve().parent
TARGETS_ROOT = REPO_DIR
NIXOS_TARGET = Path("/etc/nixos")
DOTFILES_TARGET = Path.home()
STATE_FILE = REPO_DIR / ".sync-state.json"
LAYER_IMPORT_RE = re.compile(r"\.\./(common-[a-z-]+)")


def target_dir(name: str) -> Path:
    """Return the repository directory for a machine or shared layer."""
    return TARGETS_ROOT / name


def discover_targets() -> list[Path]:
    """Find target directories with Nix configuration, dotfiles, or sync metadata."""
    if not TARGETS_ROOT.is_dir():
        return []
    return sorted(
        directory
        for directory in TARGETS_ROOT.iterdir()
        if directory.is_dir()
        and not directory.is_symlink()
        and (
            (directory / "configuration.nix").is_file()
            or (directory / "dotfiles").is_dir()
            or (directory / "sync.json").is_file()
        )
    )


def parse_imported_layers(content: str) -> list[str]:
    """Extract sorted unique common-* layer names from Nix import paths."""
    return sorted(set(LAYER_IMPORT_RE.findall(content)))


def get_imported_layers(config_path: Path) -> list[str]:
    """Include common-* imports in the machine's configuration and Nix submodules."""
    if not config_path.is_file():
        return []
    layers: set[str] = set()
    for nix_file in config_path.parent.rglob("*.nix"):
        layers.update(parse_imported_layers(nix_file.read_text()))
    return sorted(layers)


def is_home_target(name: str) -> bool:
    """A target with sync.json declares its own dotfile layers and never touches NixOS."""
    return bool(sync_engine.NAME_RE.fullmatch(name)) and (target_dir(name) / "sync.json").is_file()


def list_available_targets() -> list[str]:
    """List machine targets and their selection mode or imported layers."""
    if not TARGETS_ROOT.is_dir():
        print(f"  Error: targets directory not found at {TARGETS_ROOT}")
        return []
    targets = []
    for entry in discover_targets():
        if entry.name.startswith("common"):
            continue
        config = entry / "configuration.nix"
        if (entry / "sync.json").is_file():
            targets.append(f"{entry.name} (home only; layers from sync.json)")
        elif config.is_file():
            layers = get_imported_layers(config)
            targets.append(
                f"{entry.name} (layers: {' '.join(layers)})"
                if layers
                else f"{entry.name} (no layers)"
            )
        else:
            targets.append(f"{entry.name} (no configuration.nix)")
    return targets


def read_manifest(path: Path | None = None) -> dict[str, str] | None:
    """Return the symlink mapping from legacy or shared state for compatibility.

    Planning uses the engine's validated state reader, not this display helper.
    """
    path = STATE_FILE if path is None else path
    if not path.is_file():
        return None
    return json.loads(path.read_text()).get("symlinks", {})


def _plan_nixos_sync(target: str, *, force=False, initialize=False):
    if not isinstance(target, str) or not sync_engine.NAME_RE.fullmatch(target):
        raise ValueError(f"Unsafe sync target: {target!r}")
    layers = (
        sorted(
            directory.name
            for directory in discover_targets()
            if directory.name.startswith("common-")
        )
        if initialize
        else get_imported_layers(target_dir(target) / "configuration.nix")
    )
    layers = tuple([*layers, target])
    selected, overrides = collect_links(
        TARGETS_ROOT, DOTFILES_TARGET, layers, nixos_root=NIXOS_TARGET
    )
    plan = sync_engine.plan_links(
        target=target,
        home=DOTFILES_TARGET,
        repo=TARGETS_ROOT,
        selected=selected,
        state_path=STATE_FILE,
        layers=layers,
        roots=(NIXOS_TARGET,),
        overrides=overrides,
        force=force,
    )
    if initialize:
        matching = tuple(op for op in plan.operations if op.action == "keep")
        plan = replace(
            plan,
            operations=matching,
            ownership={str(op.destination): str(op.desired_source) for op in matching},
        )
    return plan


def _confirmation(description: str) -> bool:
    """Adapt the description callback to shared interactive confirmation."""
    return confirm("Are these changes OK? (y/n) ")


def _init_state(target: str) -> int:
    """Record only validated existing links, without creating or removing links."""
    return run_sync(
        planner=lambda: _plan_nixos_sync(target, initialize=True),
        applier=lambda plan: sync_engine.apply_sync(replace(plan, operations=()), confirmed=True),
        describe=lambda plan: describe_sync_plan(
            plan,
            footer=(
                "Initialize ownership of these existing matching symlinks only.",
                "Missing or conflicting paths are not recorded; no symlinks are changed.",
            ),
        ),
        confirm=_confirmation,
        cancelled_status=0,
    )


def main():
    parser = argparse.ArgumentParser(
        description="Sync dotfiles and NixOS configuration links for a target.",
        usage="%(prog)s <target> [--dry-run] [--force]",
    )
    parser.add_argument(
        "machine",
        nargs="?",
        metavar="target",
        help="NixOS machine, or a home-only target with sync.json",
    )
    parser.add_argument(
        "-f",
        "--force",
        action="store_true",
        help="Back up confirmed non-directory conflicts before replacement",
    )
    parser.add_argument(
        "--init-state",
        action="store_true",
        help="Record existing matching symlinks from all common-* layers and the target; "
        "never change links",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report selections and conflicts without writes/prompts",
    )
    args = parser.parse_args()
    if args.init_state and args.dry_run:
        parser.error("--init-state cannot be combined with --dry-run")
    if args.init_state and args.machine and is_home_target(args.machine):
        parser.error("--init-state applies only to NixOS targets")

    if args.machine and is_home_target(args.machine):
        status = run_sync(
            planner=lambda: plan_home_sync(
                target=args.machine, home=DOTFILES_TARGET, repo=TARGETS_ROOT, force=args.force
            ),
            applier=lambda plan: apply_home_sync(plan, confirmed=True),
            dry_run=args.dry_run,
            describe=describe_sync_plan,
            confirm=_confirmation,
            cancelled_status=0,
        )
    elif args.init_state:
        if not args.machine:
            parser.error("--init-state requires a machine name")
        status = _init_state(args.machine)
    elif args.machine:
        status = run_sync(
            planner=lambda: _plan_nixos_sync(args.machine, force=args.force),
            applier=lambda plan: sync_engine.apply_sync(plan, confirmed=True),
            dry_run=args.dry_run,
            describe=describe_sync_plan,
            confirm=_confirmation,
            cancelled_status=0,
        )
    else:
        print(f"Usage: {sys.argv[0]} <target> [--dry-run] [--force]\n")
        print("Targets with sync.json (frame) take their layers from it and change only")
        print("home dotfiles. --dry-run reports changes without prompts or writes.\n")
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
        print(f"  {sys.argv[0]} paprika     # all layers + paprika (desktop)")
        status = 1
    if status:
        sys.exit(status)


if __name__ == "__main__":
    main()
