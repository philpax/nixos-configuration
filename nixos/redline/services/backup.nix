{ config, pkgs, ... }:

let
  # Define backup mappings in order of execution
  backupMappings = [
    { src = "/mnt/ssd0/photos"; dst = "/data/photos"; }
    { src = "/mnt/ssd0/music"; dst = "/data/music"; }
    { src = "/mnt/ssd0/written"; dst = "/data/written"; }
    { src = "/mnt/ssd0/photos"; dst = "/storage/photos"; }
    { src = "/mnt/ssd0/music"; dst = "/storage/music"; }
    { src = "/mnt/ssd0/written"; dst = "/storage/written"; }
    { src = "/storage/photos"; dst = "/mnt/external/Photos"; }
    { src = "/storage/music"; dst = "/mnt/external/Music"; }
    { src = "/storage/written"; dst = "/mnt/external/Written"; }
    { src = "/storage/backup"; dst = "/mnt/external/Backup"; }
    { src = "/storage/downloads"; dst = "/mnt/external/Downloads"; }
    { src = "/storage/games"; dst = "/mnt/external/Games"; }
    { src = "/storage/videos"; dst = "/mnt/external/Videos"; }
  ];

  # Create the backup script
  backupScript = pkgs.writeShellScript "backup-sync" ''
    set -euo pipefail

    # Configuration
    LOCK_FILE="/var/run/backup-sync.lock"
    USER_TO_NOTIFY="philpax"

    # Error notification function
    notify_error() {
        local error_msg="$1"
        echo "ERROR: $error_msg"

        # Try multiple notification methods
        if command -v wall >/dev/null; then
            echo "Backup sync failed: $error_msg" | wall
        fi

        # Send to user if logged in
        if who | grep -q "$USER_TO_NOTIFY"; then
            echo "Backup sync failed: $error_msg" | write "$USER_TO_NOTIFY" || true
        fi

        # Log to systemd journal
        if command -v systemd-cat >/dev/null; then
            echo "Backup sync failed: $error_msg" | systemd-cat -t backup-sync -p err
        fi

        exit 1
    }

    # Check for lock file to prevent concurrent runs
    if [ -f "$LOCK_FILE" ]; then
        notify_error "Another backup process is already running (lock file exists)"
    fi

    # Create lock file
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT

    echo "Starting backup sync process"

    # Check if source mount exists
    if [ ! -d "/mnt/external" ]; then
        notify_error "Source directory /mnt/external not found or not mounted"
    fi

    # Backup mappings
    declare -a mappings=(
      ${builtins.concatStringsSep "\n      " (map (m: ''"${m.src}:${m.dst}"'') backupMappings)}
    )

    total_mappings=''${#mappings[@]}
    current_mapping=0
    failed_mappings=()

    for mapping in "''${mappings[@]}"; do
        current_mapping=$((current_mapping + 1))
        IFS=':' read -r src dst <<< "$mapping"

        echo "[$current_mapping/$total_mappings] Syncing: $src -> $dst"

        # Check if source exists
        if [ ! -d "$src" ]; then
            echo "WARNING: Source directory $src does not exist, skipping"
            continue
        fi

        # Create destination directory if it doesn't exist
        if ! mkdir -p "$dst"; then
            echo "ERROR: Failed to create destination directory $dst"
            failed_mappings+=("$src -> $dst (mkdir failed)")
            continue
        fi

        # Get rough file count for progress tracking
        echo "  Counting files..."
        file_count=$(find "$src" -type f 2>/dev/null | wc -l)
        echo "  Found approximately $file_count files to sync"

        # Calculate progress interval (every 10% or minimum every 1000 files)
        progress_interval=$((file_count / 10))
        if [ "$progress_interval" -lt 1000 ]; then
            progress_interval=1000
        fi

        # Perform rsync with periodic progress updates (no deletion)
        if ! ${pkgs.rsync}/bin/rsync \
            --archive \
            --human-readable \
            --partial \
            --partial-dir=.rsync-partial \
            --stats \
            --out-format="PROGRESS: %i %n" \
            "$src/" "$dst/" | \
            ${pkgs.gawk}/bin/awk -v interval="$progress_interval" '
            BEGIN { count = 0; last_report = 0 }
            /^PROGRESS:/ {
                count++;
                if (count - last_report >= interval) {
                    printf "  Progress: %d files processed...\n", count
                    last_report = count
                }
            }
            !/^PROGRESS:/ { print }
            '; then

            echo "ERROR: rsync failed for $src -> $dst"
            failed_mappings+=("$src -> $dst (rsync failed)")
            continue
        fi

        echo "[$current_mapping/$total_mappings] Completed: $src -> $dst"
    done

    # Report results
    if [ ''${#failed_mappings[@]} -eq 0 ]; then
        echo "Backup sync completed successfully for all $total_mappings mappings"

        # Optional: Send success notification to user
        if who | grep -q "$USER_TO_NOTIFY" && command -v write >/dev/null; then
            echo "Backup sync completed successfully at $(date)" | write "$USER_TO_NOTIFY" || true
        fi
    else
        error_summary="Backup sync completed with ''${#failed_mappings[@]} failures:"
        for failed in "''${failed_mappings[@]}"; do
            error_summary="$error_summary\n  - $failed"
        done
        notify_error "$error_summary"
    fi

    echo "Backup sync process finished"
  '';

in {
  # Create the systemd service
  systemd.services.backup-sync = {
    description = "Backup Sync Service";
    after = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${backupScript}";
      User = "root";
      Group = "root";

      # Security settings
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [
        "/mnt/external"
        "/mnt/ssd0"
        "/mnt/hdd1"
        "/mnt/hdd2"
        "/storage"
        "/var/run"
        "/dev/pts"  # For write command
      ];
      ProtectHome = true;
      NoNewPrivileges = true;

      # No timeout - backups can take a very long time
      TimeoutStartSec = "infinity";

      # Logging
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  # Create the systemd timer for weekly execution
  systemd.timers.backup-sync = {
    description = "Weekly Backup Sync Timer";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      # Run every Sunday at 2 AM
      OnCalendar = "Sun *-*-* 02:00:00";
      # If the system was off, run as soon as possible
      Persistent = true;
      # Add some randomization to avoid issues if multiple systems run this
      RandomizedDelaySec = "30m";
    };

    # This links the timer to the service
    unitConfig = {
      Requires = "backup-sync.service";
    };
  };

  # Create a global command to run the backup manually
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "backup-sync" ''
      if [ "$(id -u)" -ne 0 ]; then
          echo "This command requires root privileges. Use: sudo backup-sync"
          exit 1
      fi

      echo "Starting manual backup sync..."
      systemctl start backup-sync.service --no-block
      echo "Backup sync started. Check status and progress with:"
      echo "  backup-sync-status"
    '')

    (pkgs.writeShellScriptBin "backup-sync-status" ''
      echo "=== Backup Sync Status ==="
      echo

      # Show if service is currently running
      if systemctl is-active --quiet backup-sync.service; then
          echo "🔄 Service is currently RUNNING"
      elif systemctl is-failed --quiet backup-sync.service; then
          echo "❌ Service FAILED on last run"
      else
          echo "⭕ Service is not running"
      fi
      echo

      echo "Timer status:"
      systemctl status backup-sync.timer --no-pager -l --lines=3
      echo

      echo "Next scheduled run:"
      systemctl list-timers backup-sync.timer --no-pager
      echo

      echo "Recent log entries (last 20 lines):"
      journalctl -u backup-sync.service -n 20 --no-pager
      echo

      echo "For live monitoring during backup:"
      echo "  journalctl -fu backup-sync.service"
    '')
  ];

  # Only need to ensure run directory exists for lock file
  systemd.tmpfiles.rules = [
    "d /var/run 0755 root root -"
  ];

  # Enable the timer by default
  systemd.timers.backup-sync.enable = true;
}