"""Select home links for the shared sync planner and applier.

Target declarations supply ordered layers and excluded destinations. Link discovery,
operation planning, ownership, mutation, state and presentation use the common sync
implementation. This module does not implement a separate home mutation path.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from sync_engine import SyncOperation as HomeOperation
from sync_engine import SyncPlan as HomeSyncPlan
from sync_engine import SyncResult as HomeSyncResult
from sync_engine import _relative, plan_links
from sync_engine import apply_sync as apply_home_sync
from sync_engine import read_state as read_home_state
from sync_workflow import collect_links, describe_sync_plan

__all__ = [
    "HomeOperation",
    "HomeSyncPlan",
    "HomeSyncResult",
    "apply_home_sync",
    "describe_home_plan",
    "plan_home_sync",
    "read_home_state",
]

NAME_RE = re.compile(r"[a-z][a-z0-9-]*\Z")


def _read_selection(repo: Path, target: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    if not isinstance(target, str) or not NAME_RE.fullmatch(target):
        raise ValueError(f"Unsafe home-only target: {target!r}")
    target_dir = repo / target
    if target_dir.is_symlink() or not target_dir.is_dir():
        raise ValueError(f"Unknown home-only target: {target}")
    selection_path = target_dir / "sync.json"
    if selection_path.is_symlink() or not selection_path.is_file():
        raise ValueError(f"Home-only target requires sync.json: {selection_path}")
    try:
        selection = json.loads(selection_path.read_text())
    except (ValueError, UnicodeDecodeError) as exc:
        raise ValueError(f"Malformed home-only selection: {selection_path}") from exc
    if (
        not isinstance(selection, dict)
        or set(selection) != {"schema_version", "layers", "exclusions"}
        or type(selection["schema_version"]) is not int
        or selection["schema_version"] != 1
        or not isinstance(selection["layers"], list)
        or not isinstance(selection["exclusions"], list)
    ):
        raise ValueError("sync.json requires schema_version 1, layers, and exclusions")
    layers = selection["layers"]
    if not all(isinstance(layer, str) and NAME_RE.fullmatch(layer) for layer in layers):
        raise ValueError("Unsafe home-only layer name")
    if len(layers) != len(set(layers)) or target in layers:
        raise ValueError("Duplicate home-only layer or target")
    for layer in layers:
        folder = repo / layer
        if (
            folder.is_symlink()
            or not folder.is_dir()
            or not ((folder / "dotfiles").is_dir() or (folder / "configuration.nix").is_file())
        ):
            raise ValueError(f"Unknown home-only layer: {layer}")
    exclusions = tuple(str(_relative(value)) for value in selection["exclusions"])
    return tuple([*layers, target]), tuple(dict.fromkeys(exclusions))


def plan_home_sync(
    *,
    target: str,
    home: Path,
    repo: Path,
    state_path: Path | None = None,
    force: bool = False,
    extra_exclusions: tuple[str, ...] = (),
) -> HomeSyncPlan:
    """Read the home target declaration and submit links to the shared engine."""
    home, repo = Path(home).resolve(strict=True), Path(repo).resolve(strict=True)
    layers, exclusions = _read_selection(repo, target)
    selected, overrides = collect_links(repo, home, layers)
    return plan_links(
        target=target,
        home=home,
        repo=repo,
        selected=selected,
        state_path=state_path,
        layers=layers,
        exclusions=(*exclusions, *extra_exclusions),
        overrides=overrides,
        force=force,
    )


def describe_home_plan(plan: HomeSyncPlan) -> str:
    """Use the same categorized presentation as every other sync request."""
    return describe_sync_plan(plan)
