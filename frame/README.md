# Steam Frame CLI environment

The Frame target provides the repository's CLI packages, fish configuration, terminal bindings, and passive desktop dotfiles on ARM64 SteamOS. It uses `nix-user-chroot` with a single-user Nix store beneath the user's home. The store appears at `/nix` only inside a private mount/user namespace. Host applications cannot use its `/nix/store` paths directly.

Production installation and activation are separate operations. Repository implementation and isolated tests do not install or activate the normal Frame home. A reviewed activation dry-run and explicit operator consent are required before production changes.

## Scope

The target shares package functions from `common-all/packages`, `common-dev/packages`, and the explicit font list in `common-desktop/packages/fonts.nix`. NixOS modules call the same functions with their existing package set. Frame selects an independent package set. Shared definitions do not require exact cross-host package-version parity.

The dotfile layers are `common-all`, `common-dev`, `common-desktop`, and `common-dev-desktop`, followed by Frame overrides. The selection includes fish, skills, plugins, checked-out Steel cogs, terminal configurations, dormant compositor/panel/launcher/locker configurations, and manually invoked scripts. It does not import NixOS services or GUI packages. Tailscale is a client only. Privileged diagnostic tools do not authorize privileged operations.

The selection excludes SSH material, NixOS cleanup, agent authentication state, desktop autostart, user service and environment startup directories, application associations, and GTK host-theme settings. Generated terminal and Fontconfig destinations are reserved for activation. Dormant Niri and Quickshell configurations do not constitute a supported Frame desktop session. The deployment does not replace the VR session or change system services, root files, the account login shell, host SSH configuration, or credentials.

Polytoken, Makima, and Claude Code retain separate installers. Applicable configuration is shared, but the deployment does not install, invoke, or test those binaries. IDA integration remains outside Frame support.

## Prerequisites and locations

The host needs Linux on `aarch64-linux`, `/usr/bin/python3`, Bash, curl, tar, xz, sha256sum, Git, and working unprivileged user and mount namespaces. Failure of a namespace check stops installation. The deployment never enables namespaces, invokes sudo, unlocks the root filesystem, or installs host packages.

The default state is `~/.local/share/frame-cli`. Its private physical store is `store`, its bootstrap home is `bootstrap-home`, and its dedicated environment profile is `profile`. Bootstrap Nix has a separate profile. Downloads, staging, metadata, mutation locks, activation ownership, backups, and exported assets remain under the selected home. The bootstrap retains a regular CA bundle copied from the checksum-verified Nix archive and validates its recorded content hash; it does not assume that the bootstrap Nix profile contains certificates. An alternate state directory must remain beneath the canonical selected home. The host wrapper is `~/.local/bin/frame-cli` and uses `/usr/bin/python3` to run this checkout's `frame/cli.py`. The checkout must remain at a stable path and Steel submodules must be checked out.

Installer defaults are checksum-verified `nix-user-chroot` 2.1.1 and Nix 2.28.5. These versions passed the isolated ARM64 SteamOS trial. The default nixpkgs revision is `151fa4e8ddfdd8dd25d945ad94ed54a13de9f6e4`, with NAR hash `sha256-Miqqk/ammqnTUxaoCyvtwoPeLbI1ksFyLxi/CazZpWY=`. Signature verification, the default signed binary cache, sandboxing, and an empty build-users group are configured for managed invocations. Inherited Nix store/configuration overrides are removed before namespace entry. Deliberate changes after entry remain user-controlled.

The namespace cannot map every supplementary group. Ordinary CLI work is supported; privileged host operations, device access, daemons, and replacement desktop sessions are not.

## Installation and entry

Run from a stable checkout only after production consent:

```bash
/usr/bin/python3 frame/cli.py install
~/.local/bin/frame-cli status
~/.local/bin/frame-cli enter
~/.local/bin/frame-cli enter -- git --version
~/.local/bin/frame-cli update
~/.local/bin/frame-cli rollback
```

Installation, update, and rollback do not add Bash startup hooks. Default entry starts `fish -l`; explicit command entry preserves argument boundaries and the command's exit status. The wrapper preserves HOME, cwd, terminal and session variables, inherited SSH sockets, and custom XDG paths. Pure entry with a custom XDG_CONFIG_HOME does not relocate shared dotfiles or guarantee their discovery.

The profile includes GCC, Clang, and `cc` selecting GCC, OpenSSL headers/pkg-config metadata, and rooted references to every selected output. Global pkg-config paths do not replace project development environments. A build failure leaves the current dedicated profile unchanged. Status reads the active profile's recorded package/source information, including after rollback.

## Source and package customization

For example, `frame-cli update --nixpkgs-pin ~/.config/frame-cli/nixpkgs.json --overrides ~/.config/frame-cli/overrides.nix` explicitly selects both user inputs. Source precedence is `--nixpkgs-pin PATH`, then an existing `~/.config/frame-cli/nixpkgs.json`, then `frame/nixpkgs.json`. JSON requires a full revision and NAR hash. Invalid selections fail rather than reverting to defaults. A revision/hash pair can be obtained inside the namespace with the following deliberate update procedure:

```bash
frame-cli enter -- nix store prefetch-file --unpack --json https://github.com/NixOS/nixpkgs/archive/<full-revision>.tar.gz
```

The returned hash and the selected full revision form the JSON fields `rev` and `sha256`. This optional source update is not required for routine deployment. The default file gives the expected schema.

Package precedence is `--overrides PATH`, then an existing `~/.config/frame-cli/overrides.nix`, then no override. The example `frame/example-overrides.nix` is not a synced dotfile. An override is a trusted executable Nix function accepting `{ pkgs, cliPackages, fontPackages }` and returning `{ cliPackages, fontPackages }`. It can remove, add, or replace packages. Required entry/runtime tools, including Python for the managed SSH-agent supervisor, cannot be removed. Installation, update, and rollback check the selected generation's fish, Bash, Python, and OpenSSH agent executables before profile publication. Unsupported profile collisions stop the build. Overrides are not sandboxed data. The deployment snapshots the selected file's bytes under state before evaluation, so override files must be self-contained; relative imports or relative source paths are not relocated with the file. Changes become active only after a successful update; NixOS callers never read Frame pins or overrides.

## Activation

Inspect the entire dry-run before activation:

```bash
frame-cli activate --dry-run
frame-cli activate
```

Activation asks once for the displayed home changes. Conflicts are preserved and reported, not forced. Partial integration does not imply automatic-entry readiness. Dry-runs do not download, build, create directories or locks, publish assets, or modify startup files.

Activation supports only unset/empty XDG_CONFIG_HOME or the canonical `~/.config`. Other values are rejected before writes, including dry-runs and automatic-entry readiness. Changing XDG_CONFIG_HOME after activation falls outside the shared-config startup contract; the hook retains Bash and reports the unsupported location during an interactive attempted handoff. Custom font-data XDG paths must be absolute and home-confined. Activation records them; later updates reject incompatible changes.

Home-only sync state is `~/.local/state/nixos-configuration/sync-home.json`, separate from the legacy NixOS repository manifest. It records canonical home/repository identity and only unchanged owned links. User-modified links and files remain untouched. Activation records generated-file hashes and ownership separately beneath Frame state. Startup files must be regular user-owned files; symlinks are conflicts. Exact original bytes are backed up before the first edit. Repeated activation preserves non-managed bytes and permissions.

The managed Bash hook is sourced from marked blocks at the end of `.bashrc` and the first active login file among `.bash_profile`, `.bash_login`, and `.profile`. With no login file, activation creates `.bash_profile` containing only the managed block. `.bashrc` defers login-shell handoff until the login file finishes, including statements after a `.bashrc` source. Non-login interactive Bash hands off at the end of `.bashrc`. The outer block is POSIX-safe for non-Bash readers of `.profile`.

Automatic entry requires interactive Bash, TTY stdin/stdout, no `FRAME_CLI_NO_AUTO=1`, and no active Frame session. Readiness checks verify the installation and actual namespace/fish launch without building or starting an SSH agent. A broken installation retains Bash and emits one actionable diagnostic only for an interactive attempted entry. An installation can fail between readiness and `exec`; a subsequent runtime failure can terminate that session.

Keep a second working SSH session during approved production activation. Recovery commands are:

```bash
FRAME_CLI_NO_AUTO=1 /bin/bash -il
ssh -tt steamos@frame 'FRAME_CLI_NO_AUTO=1 /bin/bash -il'
```

The variable bypasses the host hook; it does not remove integration. Nested Bash started from fish remains Bash. Noninteractive SSH commands and file-transfer startup remain quiet and do not auto-enter or start an agent. Explicit remote CLI use is:

```bash
ssh steamos@frame '~/.local/bin/frame-cli enter -- git --version'
```

The example contains a fixed command. Arbitrary remote arguments require separate shell quoting; local argv preservation does not remove SSH's remote shell parsing.

## Host-visible assets and terminal configuration

Font sources and the Ocean bell sound remain rooted in the profile. Each selected font can declare rooted companion outputs; the default DejaVu package declares its separate minimal output because one font links into it. Export follows only that font's declared source and companion roots. A trusted package override can declare `passthru.frameFontCompanions` for the same purpose; unrelated store outputs are not permitted. Activation copies regular, dereferenced files to complete host-visible generations under `host-assets/generations`. An atomic `current` pointer publishes them. Host GUI processes never receive private `/nix/store` asset paths. The managed user-font link normally lives at `~/.local/share/fonts/frame-cli`. User Fontconfig includes that directory and the repository's default mono, sans, and serif families. Host `fc-list`/`fc-match` validate discovery outside the namespace when available; namespace Fontconfig alone does not prove host discovery.

Generated Ghostty configuration sets `command` for every new surface and a host-visible `bell-audio-path`. The shared optional `?machine` include loads the generated file. Generated Alacritty configuration supplies `[terminal].shell` through the shared optional `[general]` import. The main shared config does not set this field; imported fields cannot override fields later defined in the main config. Both commands use the host wrapper, never a private profile fish executable directly. Cozette and shared key bindings remain unchanged.

GUI terminals are not installed on Frame by this deployment. Parser and command tests do not prove window inheritance, visible glyph rendering, or bell audio. Those checks remain manual after a compatible terminal is installed. Ghostty audio requires a supported GTK build.

Updates and rollbacks prepare matching assets before profile publication. Profile and asset pointers cannot change in one filesystem operation. Mutation locking, a journal, retained generations, and reconciliation cover interrupted pairs. Status reports a mismatch until reconciliation succeeds. Updates and rollbacks leave terminal startup files untouched.

## SSH agent

Default interactive TTY entry reuses a responding inherited or forwarded SSH agent, including an empty agent. Forwarding is an explicit SSH choice, not a global setting. Otherwise entry starts or reuses one user-local managed OpenSSH agent. Explicit command entry, readiness, dry-runs, and file-transfer startup never start the fallback. Keys are provisioned separately and loaded explicitly:

```bash
frame-cli agent status
ssh-add ~/.ssh/<separately-provisioned-key>
frame-cli agent stop
```

No key is read or added automatically, no entry passphrase prompt occurs, and existing user SSH settings remain authoritative. Optional automatic key caching is separate user configuration. The managed socket is normally under a private user runtime directory, with a confined home-backed fallback when necessary. Host and namespace tools can reach it. The agent remains in its namespace and retains its selected generation's dependencies across profile updates.

The local agent can outlive a terminal until explicit stop or reboot. Runtime-directory removal can make a live agent unreachable; lifecycle reconciliation verifies and stops the owned process before replacement, or preserves the record/root and reports a conflict. Home-backed fallback cleanup on logout is not guaranteed. Stop never signals inherited agents and requires race-safe process handles and verified ownership/process identity. Unsupported host capabilities cause refusal rather than a numeric-PID fallback. Failed agent setup leaves a usable fish session without claiming a working agent.

The supervisor cannot spawn its child until the host records authorization. The child cannot execute `ssh-agent` until the supervisor acquires its process-bound handle. Failures before authorization can revoke the launch and release its root without assuming that launcher exit proves agent exit. A hard supervisor failure after authorization can leave an unresolved launch record. The tool preserves that record and generation root and refuses replacement when it cannot prove child exit. It does not delete unresolved state automatically or use a saved numeric PID for cleanup.

An agent socket permits signing by the same user. It does not protect against a compromised same-user process.

## Verification and removal

Automated tests use synthetic homes, temporary keys, fake installers, real terminal loaders, and bounded process-level SCP/SFTP startup harnesses. Device tests remain beneath the authorized trial directory `/home/steamos/.local/share/frame-cli-smoke-20261007`. They never modify normal-home startup files or production keys. Future SteamOS updates can change namespace availability; compatibility after reboot/update remains an operator check.

There is no recursive automatic uninstall. After all namespace sessions and the owned local agent have exited, inspect activation ownership and backups. Remove only unchanged owned generated links/files and the exact managed Bash blocks. Restore backups only after checking for subsequent user changes. Remove unchanged home-sync links using their recorded sources, never entire configuration directories. Remove the owned host wrapper and the selected state directory only after verifying that no process or retained asset link depends on them. The existing smoke trial is not removed without separate permission.
