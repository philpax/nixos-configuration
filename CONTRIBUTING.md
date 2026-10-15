# Contributing

Personal NixOS configuration with shared layers and dotfiles.

## Deployment

```bash
./sync.sh <machine>
sudo nixos-rebuild switch
```

Frame runs SteamOS with Nix and system-manager rather than NixOS:

```bash
./sync.sh frame
frame/rebuild.sh switch
```

The device needs a one-time `sudo frame/bootstrap.sh install` first. See [frame/README.md](frame/README.md).

`--dry-run` is read-only. Sync preserves unowned or modified objects and removes stale links only when they still match recorded ownership. `--force` backs up non-directory conflicts; directories are never recursively replaced. `--init-state` applies only to NixOS targets. Unresolved conflicts return a nonzero status.

Machines last synced before the target-first migration need [MIGRATION.md](MIGRATION.md).

## Architecture

### Repository layout and layers

Each machine or shared layer owns `<target>/configuration.nix` and `<target>/dotfiles/`. NixOS imports determine the dotfile layers; machine overrides win. Frame declares its layers and exclusions in `frame/sync.json`.

A layer's `portable.nix` holds what both NixOS and Frame's system-manager configuration accept: packages, fonts, fish, the SSH client and agent, and Syncthing. Its NixOS entry point imports `portable.nix` alongside NixOS-only settings, and Frame imports `portable.nix` directly. `frame/steamos.nix` implements the NixOS options portable modules use on SteamOS; anything it does not declare fails Frame's evaluation rather than being ignored.

| Layer | Contents |
| --- | --- |
| `common-all` | Users, SSH, packages, locale |
| `common-ai` | AI packages and services |
| `common-desktop` | KDE, fonts, audio, desktop applications |
| `common-dev` | Development tools, Helix, shared skills and plugins |
| `common-dev-desktop` | Niri, panels, terminals, Steam and Wine |

Machine-specific configuration lives in `jinroh/`, `paprika/`, `patlabor/`, `mindgame/`, `redline/`, and `frame/`. Frame's declared sync includes repository `authorized_keys` and Makima authentication files.

Modules must use `config.mainUser` and `config.users.users.${config.mainUser}.home` rather than hardcoded user names or home paths.

`programs/default.nix` and `services/default.nix` auto-import their directory's `.nix` files, so they hold NixOS-only modules. Shared package functions belong in `packages/`. Overlays every machine applies are listed in `common-all/overlays/default.nix`. NixOS supplies its existing `pkgs`; Frame pins nixpkgs and system-manager in `frame/nixpkgs.json` and `frame/system-manager.json`.

Syncthing membership is declared in `common-all/syncthing-topology.nix`. Machines select `philpax.syncthing.device` and supply their folder paths; Frame runs the same NixOS module through system-manager. A null device ID marks an unprovisioned peer, excluded until the generated ID is recorded.

### Dotfiles and sync

`sync_workflow.py` handles shared discovery, display, and confirmation; `sync_engine.py` handles ownership, state, and mutations. Target adapters supply destinations and exclusions.

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

Use `uv run ruff format` to format changes. CI runs lint and tests, and evaluates Frame's configuration on arm64 with `nix-instantiate frame`. Do not stage, commit, or deploy without operator consent.

`uv run update-ai.py` regenerates provider configs from the Ananke definitions in `mindgame/services/ananke.nix` and `redline/ai/ananke.nix`. Run it before syncing model changes; `--check` detects drift.

### Current-host build-only verification

Capture a baseline before changing shared NixOS package or font definitions:

```bash
uv run tests/check-current-nixos.py baseline
uv run tests/check-current-nixos.py evaluate --baseline <artifact>
uv run tests/check-current-nixos.py build --baseline <artifact> --timeout 14400
```

The checker targets the current `mindgame` checkout with the existing host nixpkgs and hardware inputs. It builds without activating or syncing `/etc/nixos`, and verifies the running system is unchanged. A failed or changed baseline is an unresolved check; do not substitute Frame's pin or repair unrelated host inputs to pass it.
