# Migrating machines to the target-first layout (issue #24)

This runbook applies to machines synced before the repository hierarchy inversion (2026-08-09). A machine needs it when its `.sync-state.json` or its dotfile symlinks still reference the old layout:

```
OLD: ~/nixos-configuration/{nixos,dotfiles}/<target>/...
NEW: ~/nixos-configuration/<target>/{configuration.nix,dotfiles/...}
```

The repo-side change is transparent to evaluation. The machine targets and the `common-*` layers moved in lockstep, so every relative Nix import resolves at the same depth (AC.4). The on-machine symlink target sets are unchanged (AC.3). The hazards below are host-side state, not repo defects. The `git mv` moved files out from under absolute symlink targets and out from under root-owned dotfiles synced against the old layout.

## Per-machine procedure

Apply the steps on each machine to migrate, in order.

1. Pull the new tree. The targets now live at the repo root.

2. Run the sync. Sync refreshes the invoking user's `$HOME` dotfiles to the new source paths and clears stale entries:

   ```bash
   ./sync.sh <machine>          # review the plan, confirm, apply
   ```

   The first sync re-creates symlinks with the new sources. Sudo prompts cover the `/etc/nixos` links. The manifest (`.sync-state.json`) is rewritten with the new source paths automatically. No migration of the state file is needed. A sync on or after 2026-08-10 fails unless `AGENT_SKILLS_COPY_MODE` has been flipped in `sync.py` (copy-mode expiry; a separate deliberate change).

3. Find stale symlinks. Search for symlinks that point at the old layout, under the user's home and under root's home:

   ```bash
   find /home/philpax /root -type l 2>/dev/null \
     -exec sh -c 'readlink "$1" | grep -qE "nixos-configuration/dotfiles/|nixos-configuration/nixos/" \
       && echo "STALE: $1 -> $(readlink "$1")"' _ {} \;
   ```

   Each hit is a symlink whose target moved during the `git mv`. Repoint the symlink to the new path (drop the `nixos/` or `dotfiles/` level), or remove it if the file is no longer wanted. `sync.sh` refreshes the invoking user's links. Most hits are therefore root-owned. A root-owned dangling link stays latent until something reads it.

4. Root nixpkgs config. `sudo nixos-rebuild` evaluates as root (`HOME=/root`). On mindgame the evaluation failed with:

   ```
   error: path '/home/philpax/nixos-configuration/dotfiles/common-all/.config/nixpkgs/config.nix' does not exist
   ```

   Root cause: nixpkgs's impure config lookup (`pkgs/top-level/impure.nix`) fires when any config imports a bare external nixpkgs without passing `config` (this repo: `mindgame/nixpkgs-xr.nix`). The lookup then imports `$HOME/.config/nixpkgs/config.nix`. The file was a stale symlink to the old repo dotfiles path, now dangling. Fix:

   ```bash
   sudo mkdir -p /root/.config/nixpkgs
   sudo ln -sfn /home/philpax/nixos-configuration/common-all/dotfiles/.config/nixpkgs/config.nix \
     /root/.config/nixpkgs/config.nix
   # or remove it — nixpkgs falls back to an empty config if NIXPKGS_CONFIG is unset
   # sudo rm -f /root/.config/nixpkgs/config.nix
   ```

   Check `NIXPKGS_CONFIG` in root's environment (`sudo env | grep -i nixpkgs`). If it points at a now-missing `/etc/nix/nixpkgs-config.nix`, unset it or recreate that file.

5. Rebuild. Rebuild to confirm evaluation:

   ```bash
   sudo nixos-rebuild switch
   ```

   If the rebuild fails, the trace names a path. Check whether the path is an old-layout absolute path (a host stale symlink, per step 4) or a relative import. A relative import failure is not expected here; the lockstep move preserves depth.

## Machine-specific notes

All machines: run the stale-symlink sweep (step 3). Only mindgame (the `nixpkgs-xr` impure import) hits the root-nixpkgs-config evaluation failure as a hard rebuild error. Root-owned dangling links are a latent problem on every machine.

redline: relocate the host-only untracked secrets before syncing. The secrets are not tracked and were not moved by `git mv`:

```bash
mkdir -p redline/secrets && mv nixos/redline/secrets/* redline/secrets/
# on the redline host after pulling; not committed
```

`redline/services/*.nix` import `../secrets/*`. The files are host-only and whitelisted in CI checks. The machine also expects `sudo nixos-rebuild` to work out of the box.

## Actions to avoid

Do not edit `.nix` import paths. They resolve at the same relative depth after the move; changing them breaks evaluation.

Do not migrate `.sync-state.json` by hand. The targets are unchanged; the next sync rewrites the file with the new source paths.

Do not commit root host state. The state is machine-local.