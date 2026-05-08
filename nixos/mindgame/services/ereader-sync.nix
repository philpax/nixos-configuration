{ config, pkgs, ... }:

let
  targetVendorId = "2237";
  targetFsLabel = "KOBOeReader";
  src = import ./lib/books-source.nix;

  syncScript = pkgs.writeShellApplication {
    name = "ereader-sync";
    runtimeInputs = with pkgs; [ util-linux rsync coreutils ];
    text = ''
      DEV="''${1:?missing device path}"
      DEVICE_MOUNT="/run/media/ereader"

      if mountpoint -q "$DEVICE_MOUNT" 2>/dev/null; then
        current_source=$(findmnt -no SOURCE --target "$DEVICE_MOUNT" 2>/dev/null || true)
        if [ "$current_source" = "$DEV" ]; then
          echo "Device already mounted at $DEVICE_MOUNT."
        else
          echo "Stale mount at $DEVICE_MOUNT (source: $current_source) — replacing..."
          umount -l "$DEVICE_MOUNT" 2>/dev/null || true
          mount -o "uid=1000,gid=100,iocharset=utf8,flush" "$DEV" "$DEVICE_MOUNT"
        fi
      else
        mkdir -p "$DEVICE_MOUNT"
        echo "Mounting $DEV at $DEVICE_MOUNT..."
        mount -o "uid=1000,gid=100,iocharset=utf8,flush" "$DEV" "$DEVICE_MOUNT"
      fi

      echo "Syncing top-level files: ${src.booksSubdir}/ -> device root"
      rsync -rt -v --human-readable --info=stats2 \
        --no-perms --no-owner --no-group --modify-window=1 \
        --filter='- /*/' \
        "${src.booksPath}/" \
        "$DEVICE_MOUNT/"

      echo "Sync complete. Device left mounted at $DEVICE_MOUNT — umount when done."
    '';
  };
in
{
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_USAGE}=="filesystem", ENV{ID_VENDOR_ID}=="${targetVendorId}", ENV{ID_FS_LABEL}=="${targetFsLabel}", TAG+="systemd", ENV{SYSTEMD_WANTS}+="ereader-sync@%k.service"
  '';

  systemd.services."ereader-sync@" = {
    description = "Sync books to eReader (%I)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = src.mountPoint;
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 2";
      ExecStart = "${syncScript}/bin/ereader-sync /dev/%I";
      TimeoutStartSec = "30min";
    };
  };
}
