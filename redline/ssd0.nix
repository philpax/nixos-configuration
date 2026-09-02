# Global kill switch for /mnt/ssd0 and everything downstream of it.
#
# Set `redline.ssd0.enable = false;` and rebuild to bring the machine up with the
# drive completely untouched: not mounted, no swap on it, no service holding it open.
# That makes it safe to unmount, fsck, mkfs or physically pull.
#
# Why this exists: on 2026-08-01 the btrfs filesystem on nvme1n1p1 forced itself
# read-only mid-session (silent lost writes from an NVMe controller fault). Tearing it
# down by hand meant chasing fifteen services, a bind mount and a live swapfile, and
# `swapoff` then failed with EROFS because the filesystem was already read-only — the
# swapfile pins the mount, so the drive could not be released without a reboot.
# Flipping a flag and rebooting avoids all of that.
#
# Deliberately blunt: it disables whole services rather than selectively removing
# ssd0 paths from them. `samba` in particular also serves /storage shares, and those
# go down too. That is the right trade for a maintenance switch — predictable beats
# clever when you are about to erase a disk.
{ config, lib, ... }:

let
  cfg = config.redline.ssd0;
  off = lib.mkForce false;
in
{
  options.redline.ssd0.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Whether /mnt/ssd0 is mounted and its dependent services run.

      When false: the filesystem and the /var/lib/immich bind mount are not mounted,
      no swapfile is activated on it, btrfs autoScrub skips it, and every service that
      reads or writes it is disabled. Intended for maintenance on the drive itself.
    '';
  };

  config = lib.mkIf (!cfg.enable) {
    # --- services storing their data on ssd0 -----------------------------------
    services.navidrome.enable = off; # MusicFolder = ssd0/music
    services.syncthing.enable = off; # shares ssd0/notes
    services.samba.enable = off; # shares ssd0/music_inbox (and /storage — see above)
    services.immich.enable = off; # media root is the /var/lib/immich bind

    # --- hand-rolled units ------------------------------------------------------
    # These services either read/write ssd0 directly or would pull in units
    # that do. The worker list is derived from the module option so changing
    # redline.audiomuse.workerCount cannot leave an ungated worker behind.
    systemd.services = lib.genAttrs
      ([
        "ananke"
        "podman-network-audiomuse"
        "podman-audiomuse"
        "podman-audiomuse-postgres"
        "podman-audiomuse-redis"
        "navidrome-audiomuse-user"
        "navidrome-audiomuse-plugin"
        "audiomuse-pgdump"
        "minecraft-server"
        "fivem-server"
        "paxboard"
        "paxcord"
        "backup-sync"
        "icloud-sync"
        "immich-stacker"
      ]
      ++ map (i: "podman-audiomuse-worker-${toString i}")
        (lib.range 1 config.redline.audiomuse.workerCount))
      (_: { enable = off; });

    # --- timers + their units ---------------------------------------------------
    # backup-sync reads ssd0 as its source; running it against a missing source would
    # do nothing useful, and its rsync has no --delete so it cannot damage the
    # destination, but there is no reason to let it fire.
    systemd.timers = lib.genAttrs
      [
        "audiomuse-pgdump"
        "backup-sync"
        "icloud-sync"
        "immich-stacker"
      ]
      (_: { enable = off; });

    # restic (services.restic.backups.external) is intentionally left alone: it backs
    # up /storage/backup to the external drive and never touches ssd0. With the drive
    # out of the picture that is exactly the backup you still want running.
  };
}
