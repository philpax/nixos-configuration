# Steam Frame

Frame runs SteamOS with a multi-user Nix install and [system-manager](https://github.com/numtide/system-manager), which applies NixOS-style modules to a non-NixOS host. `configuration.nix` imports each shared layer's `portable.nix`, the same modules the NixOS machines import, so packages, fonts, fish, the SSH agent and Syncthing are declared once for both. `steamos.nix` implements the NixOS options those modules use on SteamOS.

## Setup

Once per device, from a checkout with submodules initialised:

```bash
sudo frame/bootstrap.sh install
./sync.sh frame
frame/rebuild.sh switch
```

`bootstrap.sh install` puts the store in `/home/nix`, bind-mounts it on `/nix`, creates the `nixbld` users, writes the daemon units and `/etc/nix/nix.conf`, and installs `system-manager-boot.service`. It is idempotent. `./sync.sh frame` links dotfiles from the layers in `sync.json`. `rebuild.sh switch` builds `default.nix`, registers it as a system-manager generation, and activates it; `rebuild.sh build` only builds.

`nixpkgs.json` and `system-manager.json` pin both sources. system-manager's `main` branch expects nixpkgs unstable; a nixpkgs release needs the matching `release-*` branch.

## Surviving SteamOS updates

The root filesystem is read-only and replaced by each update; `/etc` is reset except for paths on the keep list (`/usr/lib/rauc/atomic-update-keep.conf` plus `/etc/atomic-update.conf.d/`). The setup relies on that as follows:

- The store and all profiles live in `/home/nix`, which updates never touch.
- `nix-mountpoint.service` recreates the empty `/nix` directory when an update has removed it, unlocking the root's btrfs `ro` property only around the `mkdir`.
- The bootstrap units, the `nixbld` accounts and the `.wants` links are on Valve's keep list. `bootstrap.sh` adds `/etc/nix`, its profile snippet and its tmpfiles entry to `/etc/atomic-update.conf.d/nix.conf`.
- system-manager's own `/etc` entries are symlinks into the store. They dangle until `/nix` is mounted, and an update may delete them. `system-manager-boot.service` reruns activation once `/nix` is mounted, which restores them and starts `system-manager.target`, about eight seconds into boot.

Nothing in SteamOS depends on Nix: `nix.mount` is only wanted by `local-fs.target`, and the login shell stays `/bin/bash`. If the store fails to mount, the device boots and SSH works; `frame/bootstrap.sh check` shows what is missing, and rerunning `install` repairs it.

`sudo frame/bootstrap.sh simulate-update` removes `/nix` the way an update does, to test the next boot. It unmounts lazily because sandboxed system services hold copies of the mount.

## Shell

SteamOS's login shell remains bash. Interactive login shells, such as SSH sessions, continue in fish through `/etc/profile.d/zz-fish.sh`, and Frame's Ghostty and Alacritty machine configs start fish directly, matching the NixOS machines. `ssh -t steamos@frame bash --noprofile` gets plain bash.

## User services

system-manager has no user units, so `steamos.nix` renders `systemd.user.services` with the NixOS unit types into `/etc/systemd/user`, and `reload-user-units.service` reloads the user manager whenever they change. This carries the SSH agent from `programs.ssh.startAgent` (`SSH_AUTH_SOCK` is `$XDG_RUNTIME_DIR/ssh-agent`) and the Magic Trackpad 2 driver. The agent starts empty; `AddKeysToAgent` loads a key on its first SSH use, but signing a commit first needs `ssh-add`.

The SteamOS kernel has neither `hidp` nor `hid_magicmouse`, so over Bluetooth the trackpad is a one-button mouse without the `magic-trackpad-2-linux-userspace` submodule's driver. Pairing, and the root-owned BlueZ changes it needs, are in that submodule's README.

```bash
systemctl --user status ssh-agent mt2-driver
```

## Syncthing

Frame uses `common-all/syncthing.nix` and the NixOS Syncthing module, running as a system service for the main user. Configuration and keys live in `~/.config/syncthing`. `Main` synchronises `~/notes/Main`. The web UI listens on `127.0.0.1:8384`; from another computer:

```bash
ssh -N -L 8384:127.0.0.1:8384 steamos@frame
```

Rebuilding warns that system-manager does not manage firewall rules. SteamOS's firewalld already allows ports 1024–65535 in its default zone, which covers Syncthing's 22000.

A new identity needs `devices.frame = null` in `common-all/syncthing-topology.nix` for the first switch; then record the ID from `syncthing device-id --home ~/.config/syncthing` and rebuild the participating machines.

## Graphics and Desktop Mode

Nix-built programs load GL and Vulkan drivers from `/run/opengl-driver`, which `hardware.graphics` points at nixpkgs Mesa, as NixOS does. SteamOS's own Mesa links against host libraries they cannot load. The Vulkan loader still finds SteamOS's driver manifest and logs a failure for it before using Turnip.

Fonts from `fonts.packages` are linked into the system profile and registered in `/etc/fonts/conf.d/52-nixos-default-fonts.conf`, as on NixOS. It sorts before SteamOS's `60-latin.conf`, whose preferences would otherwise win, and SteamOS applications read it too.

In the headset view, KWin's hardware-plane cursor is invisible, so `KWIN_FORCE_SW_CURSOR=1` is set in `/etc/environment.d`, and an autostart entry resets the cursor to 24 px after gamescope's 256 px. Both take effect at the next Desktop Mode login.

## Removal

`sudo frame/bootstrap.sh uninstall` deactivates system-manager, which restores the `/etc` files it replaced, and removes the units, configuration and build users. It keeps `/home/nix` unless given `--purge-store`.

system-manager logs `Unit userborn.service not found` on every activation: userborn is disabled because SteamOS owns the accounts, and the message is harmless.
