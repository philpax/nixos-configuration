# Steam Frame

Frame runs SteamOS with a multi-user Nix install and [system-manager](https://github.com/numtide/system-manager). It reuses the shared `portable.nix` modules and dotfiles. `steamos.nix` provides the compatibility options that those modules need outside NixOS.

## Setup

From a checkout with submodules initialised:

```bash
sudo frame/bootstrap.sh install
nix_channel=/nix/var/nix/profiles/default/bin/nix-channel
sudo $nix_channel --add https://nixos.org/channels/nixos-26.05 nixos
sudo $nix_channel --add https://github.com/numtide/system-manager/archive/release-26.05.tar.gz system-manager
sudo $nix_channel --update
./sync.sh frame
frame/rebuild.sh switch
```

Bootstrap is idempotent. It keeps the store and profiles in `/home/nix`, mounted at `/nix`. `sync.json` selects the dotfile layers and excludes settings that would interfere with SteamOS. nixpkgs and system-manager come from root's `nixos` and `system-manager` channels, which track the same release as the NixOS machines. system-manager's `release-YY.MM` branch must match `nixos-YY.MM`, and `main` matches `nixos-unstable`. `rebuild.sh` refuses to build until both channels exist. `./deploy.sh --channel nixos-YY.MM` switches both along with the other machines. A nightly `frame-upgrade` timer updates the channels and switches, as `system.autoUpgrade` does on NixOS.

For later changes, run sync and rebuild again. `frame/rebuild.sh build` builds without activation. `frame/bootstrap.sh check` diagnoses bootstrap problems; rerunning `install` repairs them.

## SteamOS updates

SteamOS replaces the root filesystem during updates. The store remains in `/home`, bootstrap files are preserved through the update keep list, and boot services recreate `/nix` and reactivate system-manager. The user manager waits for activation, with a timeout so a failed activation does not prevent login.

SteamOS does not depend on Nix to boot. The login shell remains `/bin/bash`, so SSH remains usable if the store cannot mount. `sudo frame/bootstrap.sh simulate-update` tests recovery on the next boot by removing the mountpoint as an update would.

## Differences from NixOS

- Interactive shells use fish without changing SteamOS's login shell. `ssh -t steamos@frame bash --noprofile` bypasses the fish handoff.
- `steamos.nix` supplies user-unit and session-environment support that system-manager lacks. SteamOS retains ownership of accounts, the host compositor, and firewall rules. The `Unit userborn.service not found` activation message is harmless.
- Nix applications use nixpkgs Mesa through `/run/opengl-driver`; SteamOS's Mesa libraries are not compatible with them. Vulkan may log a failed attempt to load the host driver before using Turnip.

### Trackpad

The SteamOS kernel lacks the Magic Trackpad 2 Bluetooth drivers. The [userspace driver README](magic-trackpad-2-linux-userspace/README.md) covers pairing and the required BlueZ changes.

SteamVR converts touchpad input to wheel events before it reaches the nested desktop, so native gestures are unavailable.

### Nested desktops

KDE remains the standard Desktop Mode. `Niri Desktop` is a separate application, also available as `frame-niri`, that Steam can add as a non-Steam application. Both desktops hide the outer gamescope cursor only over their own windows. KDE also requires software cursor rendering in the headset.

Niri uses cached upstream packages rather than the workstation forks. It adapts the shared configuration for a nested session: Windows/Super remains the modifier, Fuzzel replaces Anyrun, and machine-specific outputs, workspaces, monitor controls, screen locking, and automatic suspend are omitted. SteamOS retains control of the hardware session. The shared bar and wallpaper remain enabled; no terminal opens automatically.

Niri runs with a private runtime directory and D-Bus session while sharing host audio and the SSH agent. Exiting it stops its applications. Screen sharing and portal integration remain unverified.

## Removal

```bash
sudo frame/bootstrap.sh uninstall
```

Uninstall deactivates system-manager and removes the bootstrap configuration. It preserves `/home/nix` unless given `--purge-store`.
