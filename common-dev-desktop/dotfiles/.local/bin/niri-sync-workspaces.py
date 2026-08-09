#!/usr/bin/env python3
"""niri-sync-workspaces — write currently named Niri workspaces into config.kdl.

Reads the live workspace list from ``niri msg -j workspaces``, resolves each
workspace's output to the "<make> <model> <serial>" name config.kdl uses (via
``niri msg -j outputs``), and replaces the contiguous run of
``workspace "..." { open-on-output "..." }`` blocks in config.kdl with exactly
the currently open named workspaces, in their live order.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

CONFIG_PATH = Path.home() / ".config" / "niri" / "config.kdl"

BLOCK_RE = re.compile(r'workspace "([^"]+)" \{\n    open-on-output "([^"]+)"\n\}\n?')


def niri_json(*args: str) -> object:
    result = subprocess.run(
        ["niri", "msg", "-j", *args], capture_output=True, text=True, check=True
    )
    return json.loads(result.stdout)


def current_workspaces() -> list[tuple[str, str]]:
    """Named workspaces from the live session as (name, output_name), by idx."""
    workspaces = niri_json("workspaces")
    outputs = niri_json("outputs")
    named = [w for w in workspaces if w["name"] is not None]
    named.sort(key=lambda w: w["idx"])
    result = []
    for w in named:
        output = outputs.get(w["output"])
        if output is None:
            continue
        output_name = f"{output['make']} {output['model']} {output['serial']}"
        result.append((w["name"], output_name))
    return result


def render_block(name: str, output: str) -> str:
    return f'workspace "{name}" {{\n    open-on-output "{output}"\n}}\n'


def main() -> int:
    if not CONFIG_PATH.is_file():
        print(f"error: config not found at {CONFIG_PATH}", file=sys.stderr)
        return 1

    text = CONFIG_PATH.read_text()
    matches = list(BLOCK_RE.finditer(text))
    if not matches:
        print("error: no workspace blocks found in config.kdl", file=sys.stderr)
        return 1

    # Confirm the matches form one contiguous run, and that no other
    # 'workspace "' occurrences exist outside it — otherwise bail rather than
    # guess, since the file has a shape this script doesn't understand.
    for a, b in zip(matches, matches[1:]):
        if a.end() != b.start():
            print(
                "error: workspace blocks aren't contiguous; edit config.kdl by hand",
                file=sys.stderr,
            )
            return 1
    span_start, span_end = matches[0].start(), matches[-1].end()
    if 'workspace "' in text[:span_start] or 'workspace "' in text[span_end:]:
        print(
            "error: found workspace blocks outside the main run; edit config.kdl by hand",
            file=sys.stderr,
        )
        return 1

    existing = [(m.group(1), m.group(2)) for m in matches]

    try:
        current = current_workspaces()
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"error: failed to query niri: {e}", file=sys.stderr)
        return 1

    if current == existing:
        print("niri-sync-workspaces: config.kdl already up to date")
        return 0

    new_section = "".join(render_block(name, output) for name, output in current)
    new_text = text[:span_start] + new_section + text[span_end:]
    CONFIG_PATH.write_text(new_text)

    existing_names = {name for name, _ in existing}
    current_names = {name for name, _ in current}
    added = [name for name, _ in current if name not in existing_names]
    removed = [name for name, _ in existing if name not in current_names]
    changed = [
        name
        for name, output in current
        if name in dict(existing) and dict(existing)[name] != output
    ]
    if added:
        print(f"added: {', '.join(added)}")
    if removed:
        print(f"removed: {', '.join(removed)}")
    if changed:
        print(f"moved: {', '.join(changed)}")
    print(f"niri-sync-workspaces: wrote {CONFIG_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
