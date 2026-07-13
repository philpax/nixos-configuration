# Upgrading the Minecraft server to a new modpack version

High-level runbook for moving to a newer AoC Aeronautics (or any NeoForge modpack) release. The live server lives at `/mnt/ssd0/minecraft` and runs as the `minecraft` user via the `minecraft-server` systemd service (defined in `~/nixos-configuration/nixos/redline/services/minecraft.nix`). The service always points at `/mnt/ssd0/minecraft`, so the upgrade is "swap what's behind that path".

Everything below touches `minecraft`-owned files, so most steps need `sudo`. Claude can do the readable bulk; the rest is a handful of sudo commands it will hand you.

## 1. Stop the server

    sudo systemctl stop minecraft-server

Confirm nothing is still holding the world before copying anything.

## 2. Archive the current server

Rename the live folder, suffixing it with the pack version you're leaving (this becomes your rollback):

    sudo mv /mnt/ssd0/minecraft /mnt/ssd0/minecraft-aoc-aeronautics-<old-version>

## 3. Extract the new modpack into place

Extract the new server pack zip so its contents land directly in `/mnt/ssd0/minecraft` (config/, mods/, start.sh, variables.txt, etc. at the top level).

## 4. Carry over your data from the archived folder

This is the part to do with Claude, or by hand following the same shape. Bring over from the old folder:

- **`world/`** — the whole save (region, entities, poi, playerdata, `serverconfig/`, ftbquests, ftbteams, aeroclaims, and all the `.dat` state). This is 4-5 GB and includes the Distant Horizons LOD databases, so DH terrain survives automatically. The `.dat` files are `0600`, so this needs sudo (`sudo rsync -a old/world/ /mnt/ssd0/minecraft/world/`).
- **`server.properties`** — the old one is your real config (motd, whitelist, difficulty, etc.); copy it over the pack default.
- **`ops.json`, `whitelist.json`, `banned-players.json`, `banned-ips.json`, `eula.txt`, `usercache.json`, `usernamecache.json`.**
- **`variables.txt` — only the `JAVA_ARGS` line** (the 16 GB heap + Aikar's flags). Do NOT copy the whole file: the new one carries the new `MODLOADER_VERSION`, which must stay.

Leave the new pack's **`config/`, `mods/`, `datapacks/`, `defaultconfigs/`** as shipped — that's the point of the upgrade. Your per-world settings live in `world/serverconfig/` and come across with the world. If you think you hand-edited a global config, diff the old `config/` against the new one and port just those values; last time there were none worth moving.

Verify before moving on: the new `world/` file count should match the old one, and `level.dat` + `playerdata/` should be present.

## 5. Reinstall Distant Horizons

DH is not part of the base pack — it's added on top, so it won't be in the fresh extraction. Grab the matching build from Modrinth (https://modrinth.com/mod/distanthorizons) for the pack's Minecraft + NeoForge version, drop the jar in `mods/`, and copy the old `config/DistantHorizons.toml` across. Reuse the **same DH version** you were running so it reads the existing LOD databases instead of rebuilding them. (A newer DH will still work, but may migrate/rebuild the sqlite.)

    sudo cp DistantHorizons-*.jar /mnt/ssd0/minecraft/mods/
    sudo cp /mnt/ssd0/minecraft-aoc-aeronautics-<old-version>/config/DistantHorizons.toml /mnt/ssd0/minecraft/config/

## 6. Start and verify

    sudo systemctl start minecraft-server
    journalctl -u minecraft-server -f

The service chowns everything to `minecraft` on start, so ownership of anything you copied in as your own user gets fixed automatically. Watch the first boot for registry-remap warnings from mods that were added or dropped between versions. If it's healthy, connect and spot-check a base or two.

## 7. Tell your users

Let players know the new modpack version and where to get it, **and the exact Distant Horizons version** to install client-side — DH has to match between client and server. Include the Modrinth link.

## Rollback

If the new version misbehaves, stop the service, `mv` the new `/mnt/ssd0/minecraft` aside, and rename the archived `minecraft-aoc-aeronautics-<old-version>` folder back to `/mnt/ssd0/minecraft`. The nightly ZFS/restic backups of `/mnt/ssd0/minecraft` are the deeper safety net.
