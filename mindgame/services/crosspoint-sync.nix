{ config, pkgs, ... }:

let
  targetVendorId = "303a";
  targetProductId = "1001";
  targetHost = "http://crosspoint.local";
  src = import ./lib/books-source.nix;

  syncScript = pkgs.writeShellApplication {
    name = "crosspoint-sync";
    runtimeInputs = with pkgs; [ curl jq coreutils gnugrep ];
    text = ''
      TARGET="${targetHost}"

      echo "Waiting for $TARGET..."
      deadline=$((SECONDS + 60))
      until curl -sSf --max-time 3 "$TARGET/api/status" >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "$TARGET unreachable after 60s — device probably not in WiFi mode. Exiting cleanly."
          exit 0
        fi
        sleep 3
      done
      echo "Reachable."

      echo "Fetching remote file list..."
      remote_list=$(
        {
          curl -sSf "$TARGET/api/files?path=/" \
            | jq -r '.[] | select(.isDirectory == false) | .name'
          curl -sSf "$TARGET/api/files?path=/read" \
            | jq -r '.[] | select(.isDirectory == false) | .name'
        }
      )

      uploaded=0
      skipped=0
      failed=0
      shopt -s nullglob
      for f in "${src.booksPath}"/*.epub; do
        name=$(basename "$f")
        if grep -qFx "$name" <<< "$remote_list"; then
          skipped=$((skipped + 1))
          continue
        fi
        echo "Uploading: $name"
        if curl -sSf --max-time 600 -X POST -F "file=@\"$f\"" "$TARGET/upload" >/dev/null; then
          uploaded=$((uploaded + 1))
        else
          echo "  Upload failed: $name"
          failed=$((failed + 1))
        fi
      done

      echo "Done. Uploaded: $uploaded, Skipped: $skipped, Failed: $failed"
    '';
  };
in
{
  environment.systemPackages = [ syncScript ];

  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="${targetVendorId}", ATTR{idProduct}=="${targetProductId}", TAG+="systemd", ENV{SYSTEMD_WANTS}+="crosspoint-sync.service"
  '';

  systemd.services.crosspoint-sync = {
    description = "Sync epubs to CrossPoint Reader";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = src.mountPoint;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${syncScript}/bin/crosspoint-sync";
      TimeoutStartSec = "30min";
    };
  };

  systemd.timers.crosspoint-sync = {
    description = "Sync epubs to CrossPoint Reader every 12 hours";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "12h";
      Persistent = true;
    };
  };
}
