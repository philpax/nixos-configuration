## What This Is

Personal NixOS configuration managing multiple machines with shared configuration layers and dotfiles.

## Deployment

```bash
# Sync config to a machine (creates symlinks for <target>/ and <target>/dotfiles/)
./sync.sh <machine_name> [--force]

# After syncing, rebuild the system
sudo nixos-rebuild switch
```

Machines synced before 2026-08-09 (the target-first inversion) need the migration steps in [MIGRATION.md](MIGRATION.md). The file covers the stale-symlink sweep for old `nixos/` and `dotfiles/` paths, root-owned dangling links, the mindgame nixpkgs-config rebuild failure, and the redline secrets relocation.

## Architecture

### Repository Layout

The repository is target-first: every machine or shared layer ("target") owns a
directory at the repo root, containing its Nix files directly (incl.
`configuration.nix`) plus a `dotfiles/` subdirectory where it has dotfiles:

```
common-all/          → Base: users, SSH, packages, locale
common-desktop/      → GUI: display manager (SDDM), fonts, PipeWire, Firefox, printing
common-dev/          → Dev tools: Git, Helix, Direnv, Ripgrep; shared agent skills
common-dev-desktop/  → Niri compositor, Waybar, Alacritty, Steam, Wine
jinroh/
mindgame/
paprika/
redline/
```

There are no top-level `nixos/` or `dotfiles/` grouping directories — the
machine dirs and the `common-*` layers live side by side at the root, and each
target holds its own `dotfiles/` subdir (e.g. `redline/dotfiles/.config/...`).

### Configuration Layering

Machines compose from shared layers via NixOS imports. Each layer's Nix files
live at `<layer>/...` and its dotfiles at `<layer>/dotfiles/...`; a machine's
own config likewise lives at `<machine>/...` with dotfiles at
`<machine>/dotfiles/...`:

```
common-all          → Base: users, SSH, packages, locale
common-desktop      → GUI: display manager (SDDM), fonts, PipeWire, Firefox, printing
common-dev          → Dev tools: Git, Helix, Direnv, Ripgrep; shared agent skills
common-dev-desktop  → Niri compositor, Waybar, Alacritty, Steam, Wine
```

The primary user account is centralised in `common-all/configuration.nix`
(`users.users.philpax`) and exposed as the `options.mainUser` option (default
`"philpax"`). Modules must never hardcode the username or `/home/<name>`:
read `config.mainUser` for the name and
`config.users.users.${config.mainUser}.home` for the home path instead.

**Machine import patterns:**
- **jinroh**: common-all + common-desktop (KDE Plasma, not Niri)
- **paprika**: all four layers + ThinkPad T480s hardware
- **mindgame**: all four layers + NVIDIA/Docker/ML
- **redline**: common-all + common-dev (headless server with ZFS, AI services, Immich, Navidrome; the dev tools and shared agent skills arrive via `programs/development.nix`)

### Auto-importing Modules

`programs/default.nix` and `services/default.nix` use `builtins.readDir` to auto-import all `.nix` files in their directory. Drop a new `.nix` file in and it's automatically included — no need to edit `default.nix`.

### Dotfiles

`sync.sh` reads `<target>/configuration.nix` to determine which `common-*`
layers a machine imports, then symlinks its dotfiles from each imported
target's `dotfiles/` subdir. This mirrors the NixOS import hierarchy — e.g.
redline (headless, imports only `common-all`) won't receive desktop dotfiles
like niri or quickshell configs. When re-syncing a different machine, symlinks
from the previous sync that are no longer needed are detected via
`.sync-state.json` and offered for removal.

### Agent skills

`sync.sh` symlinks skills into the canonical `~/.agents/skills` tree, which
Polytoken discovers, then wires Claude Code personal to the same tree via a
single `~/.claude/skills → ~/.agents/skills` directory symlink — the same
pattern as the repo's own project-local `.claude/skills → .agents/skills`.
Skills are stored per-layer at `<layer>/dotfiles/.agents/skills/<name>/`, so a
machine gets a skill only if it includes that layer; the shared dev-workflow
skills (committing, GitHub issues, contributing docs, prose) live in
`common-dev/dotfiles/.agents/skills/` and reach the dev machines (paprika,
mindgame, redline), not jinroh.

Skills marked with a `.work-compatible` marker file are additionally symlinked
into the work-account directory `~/.claude-work/skills/<name>` (sourced from
`common-dev/dotfiles/.agents/skills`), so the personal and work accounts load
the same skills. Add the marker file to a skill's directory to opt it into the
work account.

### Redline Server

`redline/` is the most complex machine config with:
- `ai/` — llama-cpp, large-model-proxy, ComfyUI (custom ONNX/CUDA overlay)
- `folders.nix` — central mount point and directory definitions used across services
- Services for Immich, Navidrome, Samba, Syncthing, DNS (dnsmasq)
- Game servers: Minecraft, and FiveM (`services/fivem.nix` packages FXServer and builds its resource tree; `services/fivem/` holds the custom resources)

## Development

Python scripts (`sync.py`) are linted and formatted with [ruff](https://docs.astral.sh/ruff/), and tested with [pytest](https://docs.pytest.org/). Configuration lives in `pyproject.toml`.

```bash
uvx ruff check           # lint
uvx ruff format --check  # format check
uvx pytest -v            # run tests
```

CI runs all three on push/PR. Run `uvx ruff format` to auto-format before committing.
