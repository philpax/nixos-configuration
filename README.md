# NixOS configuration

Personal NixOS configuration with shared layers and dotfiles. Run `./sync.sh <machine>` to sync a NixOS target before rebuilding. The [Steam Frame target](frame/README.md) provides a separate home-directory-only CLI environment on ARM64 SteamOS; it does not import NixOS services or change the host system.

On Frame, `./sync.sh frame` installs the private CLI profile on first use or updates it on later runs, then displays the home activation plan and asks for confirmation. No `nixos-rebuild` command is needed. `./sync.sh frame --dry-run` reports the profile action and home changes without downloads, builds, or writes. `--home-only frame` remains a dotfile-only operation. Profile deployment and confirmed activation remain separate stages; declining activation leaves the installed or updated profile available through explicit `frame-cli enter`. The shared CLI and explicit desktop-font definitions live under the layers' `packages/` directories; Frame's source pin does not change NixOS version selection.

Current-host regression validation uses `tests/check-current-nixos.py` to bind the checkout's actual machine configuration and existing host nixpkgs/hardware inputs. Its full system build does not activate the result or sync `/etc/nixos`. See [Frame verification](frame/README.md#verification-and-removal) and the contributing instructions.

## Scripts

| Script | What it does |
| --- | --- |
| `sync.sh` / `sync.py` | Sync a NixOS machine's config and dotfiles before rebuilding, or install/update and confirm home activation with `./sync.sh frame`. |
| `slurp.py` | Adopt a file or directory into a target's `dotfiles/` and symlink it back into place (the inverse of hand-editing a live file). |
| `update-ai.py` | Regenerate the makima and Polytoken provider configs (`providers.toml`, `config.yaml`) from the ananke model definitions in `mindgame/` and `redline/`. Run before `sync.sh` when the served models change: `uv run update-ai.py`. `--check` exits non-zero if the generated files have drifted from their templates. |

`update-ai.py` reads `config.ai.ananke.clientModels` from each machine (via a `nix eval` shim) and renders the colocated `.j2` templates (`<target>.j2` next to its output), so the ananke Nix configs are the single source of truth for which models are served and at what context length.

Run the Python scripts through [uv](https://docs.astral.sh/uv/) — `pyproject.toml` pins their dependencies (`jinja2`, and a `dev` group with `pytest`/`ruff`):
