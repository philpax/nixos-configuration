## What This Is

Personal NixOS configuration managing multiple machines with shared configuration layers and dotfiles.

## Deployment

```bash
# Sync config to a machine (creates symlinks for nixos/ and dotfiles/)
./sync.sh <machine_name> [--force]

# After syncing, rebuild the system
sudo nixos-rebuild switch
```

## Architecture

### Configuration Layering

Machines compose from shared layers via NixOS imports:

```
common-all          → Base: users, SSH, packages, locale
common-desktop      → GUI: display manager (SDDM), fonts, PipeWire, Firefox, printing
common-dev          → Dev tools: Git, Helix, Direnv, Ripgrep; shared agent skills
common-dev-desktop  → Niri compositor, Waybar, Alacritty, Steam, Wine
```

**Machine import patterns:**
- **jinroh**: common-all + common-desktop (KDE Plasma, not Niri)
- **paprika**: all four layers + ThinkPad T480s hardware
- **mindgame**: all four layers + NVIDIA/Docker/ML
- **redline**: common-all + common-dev (headless server with ZFS, AI services, Immich, Navidrome; the dev tools and shared agent skills arrive via `programs/development.nix`)

### Auto-importing Modules

`programs/default.nix` and `services/default.nix` use `builtins.readDir` to auto-import all `.nix` files in their directory. Drop a new `.nix` file in and it's automatically included — no need to edit `default.nix`.

### Dotfiles

`sync.sh` reads `<machine_name>/configuration.nix` to determine which `common-*`
layers the machine imports, then only symlinks dotfiles for those layers. This
mirrors the NixOS import hierarchy — e.g. redline (headless, imports only
`common-all`) won't receive desktop dotfiles like niri or quickshell configs.
When re-syncing a different machine, symlinks from the previous sync that are
no longer needed are detected via `.sync-state.json` and offered for removal.

### Agent skills

`sync.sh` symlinks skills into the canonical `~/.agents/skills` tree, which
Polytoken discovers, then wires Claude Code personal to the same tree via a
single `~/.claude/skills → ~/.agents/skills` directory symlink — the same
pattern as the repo's own project-local `.claude/skills → .agents/skills`.
Skills are stored per-layer at `dotfiles/<layer>/.agents/skills/<name>/`, so a
machine gets a skill only if it includes that layer; the shared dev-workflow
skills (committing, GitHub issues, contributing docs, prose) live in
`dotfiles/common-dev/.agents/skills/` and reach the dev machines (paprika,
mindgame, redline), not jinroh.

Skills marked with a `.work-compatible` marker file are additionally symlinked
into the work-account directory `~/.claude-work/skills/<name>` (sourced from
`common-dev/.agents/skills`), so the personal and work accounts load the same
skills. Add the marker file to a skill's directory to opt it into the work
account.

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
