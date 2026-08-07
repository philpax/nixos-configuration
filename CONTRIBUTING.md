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
common-dev          → Dev tools: Git, Helix, Direnv, Ripgrep
common-dev-desktop  → Niri compositor, Waybar, Alacritty, Steam, Wine
```

**Machine import patterns:**
- **jinroh**: common-all + common-desktop (KDE Plasma, not Niri)
- **paprika**: all four layers + ThinkPad T480s hardware
- **mindgame**: all four layers + NVIDIA/Docker/ML
- **redline**: common-all only (headless server with ZFS, AI services, Immich, Navidrome)

### Auto-importing Modules

`programs/default.nix` and `services/default.nix` use `builtins.readDir` to auto-import all `.nix` files in their directory. Drop a new `.nix` file in and it's automatically included — no need to edit `default.nix`.

### Dotfiles

`sync.sh` reads `<machine_name>/configuration.nix` to determine which `common-*`
layers the machine imports, then only symlinks dotfiles for those layers. This
mirrors the NixOS import hierarchy — e.g. redline (headless, imports only
`common-all`) won't receive desktop dotfiles like niri or quickshell configs.
When re-syncing a different machine, symlinks from the previous sync that are
no longer needed are detected via `.sync-state.json` and offered for removal.

### Claude Code skills

`sync.sh` symlinks Polytoken skills (`dotfiles/common-all/.config/polytoken/skills/<name>/`)
into Claude Code's skills directories for both the personal account
(`~/.claude/skills/<name>`) and — for skills marked with a `.work-compatible`
marker file — the work account (`~/.claude-work/skills/<name>`), so Claude Code
loads the same skills as Polytoken on both accounts. These are common to all
machines. Add the marker file to a skill's directory to opt it into the work
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
