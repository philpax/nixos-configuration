"""Adapt the shared niri configuration for Frame's nested session."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def _replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise ValueError(f"expected one {label}, found {count}")
    return text.replace(old, new, 1)


def _remove_line_once(text: str, line: str, label: str) -> str:
    lines = text.splitlines(keepends=True)
    matches = [
        index for index, candidate in enumerate(lines) if candidate.rstrip("\r\n").strip() == line
    ]
    if len(matches) != 1:
        raise ValueError(f"expected one {label}, found {len(matches)}")
    del lines[matches[0]]
    return "".join(lines)


def adapt_config(source: str, startup: str) -> str:
    """Adapt shared niri config text for a nested Frame session.

    This intentionally performs only exact, known shared-config replacements.
    Unrelated settings and blocks are preserved byte-for-byte. Missing or
    duplicated anchors raise ``ValueError`` so source drift cannot silently
    produce a partially adapted config.
    """
    if not startup:
        raise ValueError("startup must be a non-empty executable path")

    config = _replace_once(
        source,
        'mod-key-nested "Iso_Level3_Shift"',
        'mod-key-nested "Super"',
        "nested mod-key setting",
    )
    config = config.replace(
        "    // When running nested (windowed), use AltGr as the mod key so it doesn't\n"
        "    // collide with the host compositor's Super or our own Alt binds.\n",
        "",
    )
    config = config.replace(
        "            // Make Right Alt emit ISO_Level3_Shift so it can serve as the\n"
        "            // nested mod key (see mod-key-nested above). Inert in the real\n"
        "            // session on a plain us layout.\n",
        "",
    )
    config = _replace_once(
        config,
        'options "lv3:ralt_switch"',
        "",
        "Right Alt XKB option",
    )
    config = _replace_once(
        config,
        'spawn-at-startup "sh" "-c" "~/.config/wayland-autostart.sh"',
        f"spawn-at-startup {json.dumps(startup, ensure_ascii=False)}",
        "shared session startup spawn",
    )
    for include in ("outputs.kdl", "machine.kdl", "workspaces.kdl"):
        config = _remove_line_once(
            config,
            f'include optional=true "{include}"',
            f"optional {include} include",
        )

    config = _replace_once(
        config,
        'Mod+D { spawn "anyrun"; }',
        'Mod+D { spawn "fuzzel"; }',
        "anyrun launcher bind",
    )
    config = _remove_line_once(
        config,
        'Super+Alt+L { spawn "swaylock"; }',
        "nested screen-lock bind",
    )
    config = _remove_line_once(
        config,
        "Mod+Shift+P { power-off-monitors; }",
        "nested monitor-power bind",
    )
    return config


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="shared niri config input")
    parser.add_argument("output", type=Path, help="Frame niri config output")
    parser.add_argument("startup", help="Frame startup helper executable path")
    arguments = parser.parse_args()

    adapted = adapt_config(arguments.source.read_text(), arguments.startup)
    arguments.output.write_text(adapted)


if __name__ == "__main__":
    main()
