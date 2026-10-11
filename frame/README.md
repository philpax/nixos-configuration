# Steam Frame CLI environment

Frame supplies CLI packages and shared dotfiles on ARM64 SteamOS. `nix-user-chroot` exposes a home-backed, single-user Nix store as `/nix` inside a private namespace. Host applications cannot use its store paths directly.

## Scope

Frame shares definitions from `common-all/packages`, `common-dev/packages`, and `common-desktop/packages/fonts.nix`, with an independent nixpkgs pin. NixOS uses its own package set.

`frame/sync.json` is authoritative for dotfile layers and exclusions. Sync includes the repository's `authorized_keys` and Makima authentication files; `.tokens` remains excluded. Ownership checks preserve modified or unowned files and links. Missing private keys require separate provisioning.

Deployment stays under home. It never uses sudo, unlocks the root filesystem, installs GUI terminals, replaces the VR session, or changes system services, the login shell, or host SSH configuration. Polytoken, Makima, and Claude Code retain separate installers.

## Prerequisites and locations

The host needs `aarch64-linux`, `/usr/bin/python3`, Bash, curl, tar, xz, sha256sum, Git, and working unprivileged user/mount namespaces. The checkout must remain at a stable path, with Steel submodules initialized.

State, the private store, profile, and exported assets default to `~/.local/share/frame-cli`; alternate state directories must remain beneath home. The host wrapper is `~/.local/bin/frame-cli`. Privileged operations and device access are unsupported. Activation manages a Syncthing user service through the host systemd user manager.

## Installation and entry

From a stable checkout:

```bash
cd ~/nixos-configuration
git pull --ff-only
git submodule update --init
./sync.sh frame --dry-run
./sync.sh frame
```

The dry-run is read-only: no bootstrap, downloads, evaluation, builds, or writes. Combined sync installs or updates the profile before asking for home activation confirmation. Declining stops activation, not profile publication or matching asset refreshes. Build failure stops before activation. No NixOS rebuild follows.

Explicit `./sync.sh --home-only frame` manages dotfiles only. Combined deployment rejects `--force` and `--init-state`. Conflicts remain preserved and return nonzero; new startup integration waits for resolution.

Manual commands remain available:

```bash
/usr/bin/python3 frame/cli.py install
~/.local/bin/frame-cli status
~/.local/bin/frame-cli enter
~/.local/bin/frame-cli enter -- git --version
~/.local/bin/frame-cli update
~/.local/bin/frame-cli rollback
```

Install, update, and rollback do not add startup hooks. Default entry starts `fish -l`; explicit commands preserve arguments and exit status. Status reports the active generation, including after rollback.

## Source and package customization

Source precedence is `--nixpkgs-pin PATH`, then `~/.config/frame-cli/nixpkgs.json` if present, then `frame/nixpkgs.json`. JSON requires `rev` and `sha256`, containing a full revision and NAR hash. Invalid selections fail.

Package precedence is `--overrides PATH`, then `~/.config/frame-cli/overrides.nix` if present, then no override:

```bash
frame-cli update --nixpkgs-pin ~/.config/frame-cli/nixpkgs.json --overrides ~/.config/frame-cli/overrides.nix
```

Overrides are trusted executable Nix, not sandboxed data. They accept `{ pkgs, cliPackages, fontPackages }` and return `{ cliPackages, fontPackages }`; required runtime tools cannot be removed. Files are snapshotted before evaluation and must be self-contained: relative imports and sources are not copied. See [example-overrides.nix](example-overrides.nix). Changes require a successful update and do not affect NixOS.

## Activation

```bash
frame-cli activate --dry-run
frame-cli activate
```

Activation confirms home links, generated assets, Bash startup hooks, and the Syncthing user service. Successful activation reloads the user systemd manager and restarts `frame-syncthing.service`. Conflicts defer service startup. Only unset/empty `XDG_CONFIG_HOME` or canonical `~/.config` is supported, including for dry-runs. Explicit entry preserves custom XDG paths but does not relocate shared dotfiles.

Automatic entry requires interactive Bash with TTY input/output. Noninteractive SSH and file transfers remain quiet. Keep a working SSH session during activation. Recovery bypasses automatic entry:

```bash
FRAME_CLI_NO_AUTO=1 /bin/bash -il
ssh -tt steamos@frame 'FRAME_CLI_NO_AUTO=1 /bin/bash -il'
ssh steamos@frame '~/.local/bin/frame-cli enter -- git --version'
```

## Host-visible assets and terminal configuration

Activation exports fonts and bell audio to host-visible files and owns generated Fontconfig, Ghostty, and Alacritty configuration. Terminal commands use the host wrapper. Updates and rollbacks prepare matching assets without editing startup files. Host font discovery is checked when Fontconfig tools are available. Rendering and audio need manual checks after installing a GUI terminal.

## SSH client

Frame's OpenSSH reads `~/.ssh/config` and an empty system configuration in the Nix store. It does not read SteamOS's `/etc/ssh/ssh_config` or its included files. The private namespace maps only the current user's UID; host root-owned files appear as `nobody`, which OpenSSH rejects for included configuration. The Frame-only package overlay avoids those files without disabling permission checks or changing host SSH configuration. Host SSH settings needed inside Frame belong in `~/.ssh/config`.

An existing generation with this error can use `git -c core.sshCommand='ssh -F ~/.ssh/config' pull`. If that file does not exist, use `-F /dev/null`. Apply the package fix with `frame-cli update` and enter a new session.

## SSH agent

Interactive TTY entry reuses a responding inherited or forwarded agent, otherwise starts or reuses a managed local agent. Explicit commands never start the fallback. Keys are never loaded automatically:

```bash
frame-cli agent status
ssh-add ~/.ssh/<separately-provisioned-key>
frame-cli agent stop
```

The local agent can persist until stop or reboot. Stop never signals inherited agents. Recovery refuses numeric-PID cleanup; unresolved ownership preserves control state and generation roots. Do not delete unresolved control state.

## Syncthing

The Frame profile includes Syncthing. Activation installs `~/.config/systemd/user/frame-syncthing.service` and its `default.target.wants` link. The service enters the private Nix namespace through `frame-cli`; host systemd never executes private store paths directly. Install, update, and rollback do not enable or restart the service. After a profile update or rollback, activation restarts it with the selected generation.

Each service start generates or reuses the local identity and applies peers and folders from the profile's snapshot of `common-all/syncthing-topology.nix`. This replaces folder and peer changes made through the web UI. Configuration, keys, and the database reside in `~/.local/state/frame-syncthing`. `Main` synchronizes `~/notes/Main`. Automatic binary upgrades are disabled; profile updates supply the binary.

The topology records Frame's public device ID. For a new identity, set `devices.frame = null` before the first activation. NixOS machines omit unprovisioned devices from peers and folder sharing. After that activation, retrieve the generated ID:

```bash
frame-cli syncthing device-id
systemctl --user status frame-syncthing.service
journalctl --user -u frame-syncthing.service
```

Set `devices.frame` in `common-all/syncthing-topology.nix` to that ID. Run `./sync.sh frame` again and rebuild participating NixOS machines. Other peers require the device and folder share to be added manually. The private key remains on Frame and must not be committed. A configured ID that differs from the local identity prevents service startup.

The web UI listens on `127.0.0.1:8384`. Access from another computer uses an SSH tunnel:

```bash
ssh -N -L 8384:127.0.0.1:8384 steamos@frame
```

Open `http://127.0.0.1:8384` on the computer running the tunnel. Sync traffic uses Syncthing's standard discovery, connection, and relay settings. Deployment does not change the SteamOS firewall.

Service activation requires the account's actual home directory; alternate synthetic homes cannot control the host user manager. The service starts with the systemd user manager. Starting at boot without a login requires user lingering, configured separately with `loginctl enable-linger steamos` where host permissions permit it. Lingering does not prevent headset suspension. `systemctl --user stop frame-syncthing.service` stops synchronization; a later activation restarts it.

## Verification and removal

SteamOS updates can change namespace availability; recheck entry afterward.

There is no recursive automatic uninstall. After stopping `frame-syncthing.service`, removing its owned enable link, reloading the user systemd manager, and exiting sessions and the local agent, remove only unchanged owned links/files and managed Bash blocks. Check subsequent changes before restoring backups. Remove the wrapper and state only when no process or retained asset link depends on them.
