# NixOS configuration

My NixOS configuration. Clone somewhere, then run `./sync.sh` to create symlinks to the relevant locations.

## Scripts

| Script | What it does |
| --- | --- |
| `sync.sh` / `sync.py` | Symlink a machine's Nix config to `/etc/nixos` and its `dotfiles/` into `$HOME` (run after pulling: `./sync.sh <machine>`). |
| `slurp.py` | Adopt a file or directory into a target's `dotfiles/` and symlink it back into place (the inverse of hand-editing a live file). |
| `update-ai.py` | Regenerate the makima and Polytoken provider configs (`providers.toml`, `config.yaml`) from the ananke model definitions in `mindgame/` and `redline/`. Run before `sync.sh` when the served models change: `uv run update-ai.py`. `--check` exits non-zero if the generated files have drifted from their templates. |

`update-ai.py` reads `config.ai.ananke.clientModels` from each machine (via a `nix eval` shim) and renders the colocated `.j2` templates (`<target>.j2` next to its output), so the ananke Nix configs are the single source of truth for which models are served and at what context length.

Run the Python scripts through [uv](https://docs.astral.sh/uv/) — `pyproject.toml` pins their dependencies (`jinja2`, and a `dev` group with `pytest`/`ruff`):
