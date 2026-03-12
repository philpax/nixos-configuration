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
common-all          → Base: users, SSH, packages, locale, unstable channel
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

### Unstable Channel

`common-all/configuration.nix` pins an unstable nixpkgs tarball and passes it as `unstable` via `_module.args`. Use `unstable.packageName` for packages needing a newer version.

### Dotfiles

`dotfiles/` mirrors the `nixos/` layer structure. `sync.sh` symlinks contents of matching `dotfiles/{common-*,<machine>}/` directories into `$HOME`. Key configs: fish shell, Helix editor, Niri, Waybar, Alacritty, mimeapps.list.

### Redline Server

`redline/` is the most complex machine config with:
- `ai/` — llama-cpp, large-model-proxy, ComfyUI (custom ONNX/CUDA overlay)
- `folders.nix` — central mount point and directory definitions used across services
- Services for Immich, Navidrome, Samba, Syncthing, DNS (dnsmasq)
