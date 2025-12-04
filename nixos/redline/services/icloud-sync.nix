{ config, pkgs, unstable, ... }:

let
  # Create the iCloud sync script
  icloudSyncScript = pkgs.writeShellScript "icloud-sync" ''
    set -euo pipefail

    # Configuration
    ICLOUD_DIR="/mnt/ssd0/photos/iCloud"
    USERNAME="me@philpax.me"

    echo "Starting iCloud sync process"

    # Create the iCloud directory if it doesn't exist
    if ! mkdir -p "$ICLOUD_DIR"; then
        echo "ERROR: Failed to create iCloud directory $ICLOUD_DIR"
        exit 1
    fi

    # Run icloudpd
    echo "Running icloudpd sync..."
    if ! ${unstable.icloudpd}/bin/icloudpd \
        --directory "$ICLOUD_DIR" \
        --username "$USERNAME"; then
        echo "ERROR: icloudpd sync failed"
        exit 1
    fi

    echo "iCloud sync completed successfully"
  '';

in {
  # Create the icloudpd user
  users.users.icloudpd = {
    isSystemUser = true;
    group = "icloudpd";
    home = "/var/lib/icloudpd";
    createHome = true;
  };

  users.groups.icloudpd = {};

  # Create the systemd service
  systemd.services.icloud-sync = {
    description = "iCloud Photo Sync Service";
    after = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${icloudSyncScript}";
      User = "icloudpd";
      Group = "icloudpd";

      # Security settings
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [
        "/mnt/ssd0/photos"
        "/var/lib/icloudpd"
      ];
      ProtectHome = false;
      NoNewPrivileges = true;

      # Timeout after 2 hours (iCloud sync can take a while)
      TimeoutStartSec = "2h";

      # Logging
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  # Create the systemd timer for daily execution
  systemd.timers.icloud-sync = {
    description = "Daily iCloud Photo Sync Timer";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      # Run every day at 6 AM
      OnCalendar = "daily";
      # If the system was off, run as soon as possible
      Persistent = true;
      # Add some randomization to avoid issues if multiple systems run this
      RandomizedDelaySec = "30m";
    };

    # This links the timer to the service
    unitConfig = {
      Requires = "icloud-sync.service";
    };
  };

  # Create a global command to run the iCloud sync manually
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "icloud-sync" ''
      if [ "$(id -u)" -ne 0 ]; then
          echo "This command requires root privileges. Use: sudo icloud-sync"
          exit 1
      fi

      echo "Starting manual iCloud sync..."
      systemctl start icloud-sync.service --no-block
      echo "iCloud sync started. Check status and progress with:"
      echo "  icloud-sync-status"
    '')

    (pkgs.writeShellScriptBin "icloud-sync-status" ''
      echo "=== iCloud Sync Status ==="
      echo

      # Show if service is currently running
      if systemctl is-active --quiet icloud-sync.service; then
          echo "🔄 Service is currently RUNNING"
      elif systemctl is-failed --quiet icloud-sync.service; then
          echo "❌ Service FAILED on last run"
      else
          echo "⭕ Service is not running"
      fi
      echo

      echo "Timer status:"
      systemctl status icloud-sync.timer --no-pager -l --lines=3
      echo

      echo "Next scheduled run:"
      systemctl list-timers icloud-sync.timer --no-pager
      echo

      echo "Recent log entries (last 20 lines):"
      journalctl -u icloud-sync.service -n 20 --no-pager
      echo

      echo "For live monitoring during sync:"
      echo "  journalctl -fu icloud-sync.service"
    '')
  ];


  # Enable the timer by default
  systemd.timers.icloud-sync.enable = true;
}
