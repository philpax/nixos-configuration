# NixOS configuration

Personal machine configurations with shared packages and dotfiles.

```bash
./sync.sh <machine>
sudo nixos-rebuild switch
```

The [Steam Frame target](frame/README.md) uses `./sync.sh frame` without a NixOS rebuild. It installs or updates a home-backed CLI environment and confirms dotfile and shell integration.

`--dry-run` previews changes without writes. Sync preserves unowned or modified files. NixOS `--force` backs up non-directory conflicts; Frame deployment rejects it.

## Scripts

| Script | Purpose |
| --- | --- |
| `sync.sh` / `sync.py` | Sync a machine's configuration and dotfiles. |
| `slurp.py` | Move a live file or directory into a target's `dotfiles/` and symlink it back. |
| `update-ai.py` | Regenerate Makima and Polytoken provider configs from the Ananke model definitions. Run `uv run update-ai.py` before syncing changed models; `--check` checks for drift. |

See [CONTRIBUTING.md](CONTRIBUTING.md) for repository conventions, tests, and build-only verification.
