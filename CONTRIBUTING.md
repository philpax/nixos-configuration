# Contributing

Personal NixOS configuration with shared layers and dotfiles.

## Deployment

```bash
./sync.sh <machine>
sudo nixos-rebuild switch
```

`./sync.sh frame` installs or updates the home-only Steam Frame environment and confirms activation. It requires no NixOS rebuild or sudo. See [frame/README.md](frame/README.md) for entry, overrides, and recovery.

`--dry-run` is read-only. Sync preserves unowned or modified objects and removes stale links only when they still match recorded ownership. NixOS `--force` backs up non-directory conflicts; directories are never recursively replaced. Frame deployment rejects `--force` and `--init-state`. Unresolved conflicts return a nonzero status.

Machines last synced before the target-first migration need [MIGRATION.md](MIGRATION.md).

## Architecture

### Repository layout and layers

Each machine or shared layer owns `<target>/configuration.nix` and `<target>/dotfiles/`. NixOS imports determine the dotfile layers; machine overrides win. Frame declares its layers and exclusions in `frame/sync.json`.

| Layer | Contents |
| --- | --- |
| `common-all` | Users, SSH, packages, locale |
| `common-ai` | AI packages and services |
| `common-desktop` | KDE, fonts, audio, desktop applications |
| `common-dev` | Development tools, Helix, shared skills and plugins |
| `common-dev-desktop` | Niri, panels, terminals, Steam and Wine |

Machine-specific configuration lives in `jinroh/`, `paprika/`, `patlabor/`, `mindgame/`, and `redline/`. Frame shares CLI and passive desktop configuration without importing NixOS services or installing GUI terminals. Its declared sync includes repository `authorized_keys` and Makima authentication files.

Modules must use `config.mainUser` and `config.users.users.${config.mainUser}.home` rather than hardcoded user names or home paths.

`programs/default.nix` and `services/default.nix` auto-import their directory's `.nix` files. Shared package functions belong in `packages/`, not those module directories. NixOS supplies its existing `pkgs`; Frame uses its independent pin and the shared Helix Steel overlay.

Syncthing membership is declared in `common-all/syncthing-topology.nix`. Machines select `philpax.syncthing.device` and supply their folder paths.

### Dotfiles and sync

`sync_workflow.py` handles shared discovery, display, and confirmation; `sync_engine.py` handles ownership, state, and mutations. Target adapters supply destinations and exclusions. Frame adds generated files and startup integration to the displayed plan.

NixOS records ownership in repository `.sync-state.json`; home-only sync uses `~/.local/state/nixos-configuration/sync-home.json`. Sudo is requested only after a permitted non-home write fails for lack of permission. Home and state writes never elevate. Do not delete lock or request files to bypass a stalled worker, or use independent manifests to manage overlapping destinations.

### Skills and plugins

Skills live in `<layer>/dotfiles/.agents/skills/`. Sync links them into `~/.agents/skills` and points `~/.claude/skills` there. A `.work-compatible` marker also enables a skill under `~/.claude-work/skills`.

Claude Code plugins live in `<layer>/dotfiles/.claude-plugins/` and sync to `~/.local/share/claude-plugins/`. Fish sets `CLAUDE_CODE_PLUGIN_DIRS` for personal and work accounts. The `deep-plan` plugin provides `/deep-plan` and `/facet`; prompts live under `prompts/`, with a repository override at `.claude/plan-spec.md`.

From a plugin directory:

```bash
claude plugin validate .
claude plugin test .
tsc -p .
```

Type checking requires the API types generated when Claude Code loads the plugin.

## Development

Python dependencies are pinned in `uv.lock`; tests and support live in `tests/`.

```bash
uv run ruff check
uv run ruff format --check
uv run pytest -v
```

Use `uv run ruff format` to format changes. CI runs lint and tests. Set `FRAME_NIX_BUILD_TESTS=1` to include real profile builds. Frame tests use synthetic homes and keys; device-test staging excludes real credential contents and tests do not invoke bespoke agent binaries or installers. Do not stage, commit, or deploy without operator consent.

`uv run update-ai.py` regenerates provider configs from the Ananke definitions in `mindgame/services/ananke.nix` and `redline/ai/ananke.nix`. Run it before syncing model changes; `--check` detects drift.

### Current-host build-only verification

Capture a baseline before changing shared NixOS package or font definitions:

```bash
uv run tests/check-current-nixos.py baseline
uv run tests/check-current-nixos.py evaluate --baseline <artifact>
uv run tests/check-current-nixos.py build --baseline <artifact> --timeout 14400
```

The checker targets the current `mindgame` checkout with the existing host nixpkgs and hardware inputs. It builds without activating or syncing `/etc/nixos`, and verifies the running system is unchanged. A failed or changed baseline is an unresolved check; do not substitute Frame's pin or repair unrelated host inputs to pass it.
