{ config, pkgs, unstable, ... }:
let
    port = 2283;
    immichSecrets = import ../secrets/immich.nix;

    # Download and store immich-stacker binary
    immichStackerBinary = pkgs.stdenv.mkDerivation {
        name = "immich-stacker";
        version = "1.6.0";

        src = pkgs.fetchurl {
            url = "https://github.com/mattdavis90/immich-stacker/releases/download/v1.6.0/immich-stacker-linux-amd64";
            sha256 = "sha256-MEPrjJdovcGwCVQxdn0PQprIDh8zgPipPJF8pGwTGMk=";
        };

        dontUnpack = true;
        dontConfigure = true;
        dontBuild = true;

        installPhase = ''
            mkdir -p $out/bin
            cp $src $out/bin/immich-stacker
            chmod +x $out/bin/immich-stacker
        '';
    };

    # Create the immich-stacker script
    immichStackerScript = pkgs.writeShellScript "immich-stacker" ''
        set -euo pipefail

        echo "Starting immich-stacker process"

        # Set environment variables
        export IMMICH_API_KEY="${immichSecrets.apiKey}"
        export IMMICH_ENDPOINT="http://localhost:${toString port}/api"
        export IMMICH_MATCH="\.(JP[E]?G|RW2|RAF|NEF)$"
        export IMMICH_PARENT="\.JP[E]?G$"

        # Run immich-stacker
        echo "Running immich-stacker with endpoint: $IMMICH_ENDPOINT"
        if ! ${immichStackerBinary}/bin/immich-stacker; then
            echo "ERROR: immich-stacker failed"
            exit 1
        fi

        echo "immich-stacker process finished successfully"
    '';
in
{
  services.immich = {
    enable = true;
    port = port;
    package = unstable.immich;
    host = "0.0.0.0";
    accelerationDevices = null;
  };

  users.users.immich.extraGroups = [ "video" "render" ];
  networking.firewall.allowedTCPPorts = [ port ];

  # Create the systemd service for immich-stacker
  systemd.services.immich-stacker = {
    description = "Immich Stacker Service";
    after = [ "immich.service" "multi-user.target" ];
    wants = [ "immich.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${immichStackerScript}";
      User = "immich";
      Group = "immich";

      # Security settings
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ ];
      ProtectHome = true;
      NoNewPrivileges = true;

      # Timeout after 1 hour
      TimeoutStartSec = "1h";

      # Logging
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  # Create the systemd timer for daily execution
  systemd.timers.immich-stacker = {
    description = "Daily Immich Stacker Timer";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      # Run every day at 3 AM (after immich has had time to process)
      OnCalendar = "daily";
      # If the system was off, run as soon as possible
      Persistent = true;
      # Add some randomization to avoid issues if multiple systems run this
      RandomizedDelaySec = "30m";
    };

    # This links the timer to the service
    unitConfig = {
      Requires = "immich-stacker.service";
    };
  };

  # Create global commands to run immich-stacker manually
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "immich-stacker" ''
      if [ "$(id -u)" -ne 0 ]; then
          echo "This command requires root privileges. Use: sudo immich-stacker"
          exit 1
      fi

      echo "Starting manual immich-stacker..."
      systemctl start immich-stacker.service --no-block
      echo "immich-stacker started. Check status and progress with:"
      echo "  immich-stacker-status"
    '')

    (pkgs.writeShellScriptBin "immich-stacker-status" ''
      echo "=== Immich Stacker Status ==="
      echo

      # Show if service is currently running
      if systemctl is-active --quiet immich-stacker.service; then
          echo "🔄 Service is currently RUNNING"
      elif systemctl is-failed --quiet immich-stacker.service; then
          echo "❌ Service FAILED on last run"
      else
          echo "⭕ Service is not running"
      fi
      echo

      echo "Timer status:"
      systemctl status immich-stacker.timer --no-pager -l --lines=3
      echo

      echo "Next scheduled run:"
      systemctl list-timers immich-stacker.timer --no-pager
      echo

      echo "Recent log entries (last 20 lines):"
      journalctl -u immich-stacker.service -n 20 --no-pager
      echo

      echo "For live monitoring during stacker run:"
      echo "  journalctl -fu immich-stacker.service"
    '')
  ];

  # Enable the timer by default
  systemd.timers.immich-stacker.enable = true;
}