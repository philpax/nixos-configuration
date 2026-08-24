#!/usr/bin/env python3
"""Regenerate makima and Polytoken provider configs from the ananke Nix configs.

The ananke service definitions are the source of truth for which models are
served and at what context length. Each machine's ananke module exposes
``config.ai.ananke.clientModels`` — the subset of models flagged for client
exposure, with ``context_window`` and ``supports_vision`` derived from the
runtime config (see ``anankeLib.mkClientModel``). This script evals that option
for each machine, then templates the two consumer config files in full so any
manual drift surfaces as a diff on the next run.

Sources:
  mindgame/services/ananke.nix   -> ananke-mindgame provider
  redline/ai/ananke.nix          -> ananke-redline provider

Outputs:
  common-dev/dotfiles/.config/makima/providers.toml
  common-all/dotfiles/.config/polytoken/config.yaml
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from jinja2 import ChoiceLoader, Environment, FileSystemLoader

REPO_DIR = Path(__file__).resolve().parent

# Machines to evaluate, in canonical provider/model output order.
MACHINES = ["mindgame", "redline"]

# Our canonical model classes, mapped to each consumer's vocabulary. These two
# tables are the only place makima/Polytoken tier vocabulary lives, so a rename on
# either consumer's side is a one-line change here rather than a Nix sweep.
MAKI_TIER = {"large": "strong", "medium": "medium", "small": "weak"}
PT_CLASS = {"large": "full", "medium": "mini", "small": "nano"}

MAKI_PATH = REPO_DIR / "common-dev" / "dotfiles" / ".config" / "makima" / "providers.toml"
PT_PATH = REPO_DIR / "common-all" / "dotfiles" / ".config" / "polytoken" / "config.yaml"

# Templates live beside their targets as `<name>.j2` (e.g. providers.toml.j2),
# so the generation source for each file is obvious from its location. The
# expander discovers every `*.j2` in these dirs and writes the `.j2`-stripped
# sibling, so adding a consumer is just dropping a template next to its output.
TEMPLATE_DIRS = [MAKI_PATH.parent, PT_PATH.parent]

_env = Environment(
    loader=ChoiceLoader([FileSystemLoader(d) for d in TEMPLATE_DIRS]),
    trim_blocks=True,
    lstrip_blocks=True,
    keep_trailing_newline=False,
)


def eval_machine(machine: str) -> dict:
    """Eval ``config.ai.ananke.clientModels`` (and the openai port) for a machine.

    Returns ``{"models": [...], "port": int}``. Uses a thin ``nix eval`` shim
    that imports the machine's ``configuration.nix`` and reads only the
    ``ai.ananke`` options, so the full machine config evaluates but no system
    closure is built.
    """
    expr = (
        "let np = import <nixpkgs> {}; "
        f"c = (np.nixos {{ imports = [ ./{machine}/configuration.nix ]; }}).config; "
        "in { models = c.ai.ananke.clientModels; port = c.ai.ananke.openaiPort; }"
    )
    result = subprocess.run(
        ["nix", "eval", "--json", "--impure", "--expr", expr],
        cwd=REPO_DIR,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"nix eval failed for {machine}:\n{result.stderr.strip()}")
    return json.loads(result.stdout)


def build_providers() -> list[tuple[str, dict]]:
    """Evaluate every machine and assemble per-provider info in output order."""
    providers: list[tuple[str, dict]] = []
    for machine in MACHINES:
        data = eval_machine(machine)
        provider_name = f"ananke-{machine}"
        providers.append(
            (
                provider_name,
                {
                    "display_name": f"Custom ({provider_name})",
                    "api_key_env": f"ANANKE_{machine.upper()}_API_KEY",
                    "base_url": f"http://{machine}:{data['port']}/v1",
                    "models": data["models"],
                },
            )
        )
    return providers


def resolve_defaults(providers: list[tuple[str, dict]]) -> dict[str, str]:
    """Build the Polytoken ``defaults`` map (full/mini/nano) from model ``roles``.

    Each role must map to exactly one model; a collision is an error.
    """
    defaults: dict[str, str] = {}
    for provider_name, info in providers:
        for model in info["models"]:
            for role in model.get("roles", []):
                full_name = f"{provider_name}/{model['name']}"
                if role in defaults and defaults[role] != full_name:
                    raise SystemExit(
                        f"role '{role}' is claimed by both {defaults[role]} "
                        f"and {full_name}; each role must map to one model"
                    )
                defaults[role] = full_name
    return defaults


def gather_context() -> dict:
    """Gather every template's inputs into one shared context.

    ``providers`` and ``defaults`` come from the ananke Nix eval; ``maki_tier``
    and ``pt_class`` map our canonical classes to each consumer's vocabulary.
    Templates pick what they need from this dict.
    """
    providers = build_providers()
    return {
        "providers": providers,
        "defaults": resolve_defaults(providers),
        "maki_tier": MAKI_TIER,
        "pt_class": PT_CLASS,
    }


def discover_templates() -> list[Path]:
    """Find every `*.j2` template in the template dirs (top-level only)."""
    seen: list[Path] = []
    for d in TEMPLATE_DIRS:
        for path in sorted(d.glob("*.j2")):
            if path not in seen:
                seen.append(path)
    return seen


def render_all(context: dict) -> dict[Path, str]:
    """Render every discovered template to its `.j2`-stripped sibling path."""
    rendered: dict[Path, str] = {}
    for template in discover_templates():
        output = template.with_suffix("")
        rendered[output] = _env.get_template(template.name).render(**context)
    return rendered


def write_file(path: Path, content: str) -> bool:
    """Write content if it differs from the file on disk. Returns True if changed."""
    existing = path.read_text() if path.exists() else None
    if existing == content:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    return True


def check_file(path: Path, content: str) -> bool:
    """Return True if content matches the file on disk (drift gate)."""
    existing = path.read_text() if path.exists() else None
    return existing == content


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if generated content differs from the files on disk",
    )
    args = parser.parse_args()

    generated = render_all(gather_context())

    if args.check:
        drifted = [path for path, content in generated.items() if not check_file(path, content)]
        if drifted:
            for path in drifted:
                print(f"drift detected: {path}", file=sys.stderr)
            return 1
        return 0

    changed = False
    for path, content in generated.items():
        if write_file(path, content):
            print(f"updated {path.relative_to(REPO_DIR)}")
            changed = True
    if not changed:
        print("already up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
