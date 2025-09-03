{ config, pkgs, ... }:

let
  # Create a dedicated user for paxboard
  paxboardUser = "paxboard";
  paxboardGroup = "paxboard";
in
{
  # Create the paxboard user and group
  users.users.${paxboardUser} = {
    isSystemUser = true;
    group = paxboardGroup;
    description = "paxboard service user";
    home = "/var/lib/paxboard";
    createHome = true;
    shell = "${pkgs.bash}/bin/bash";
  };

  users.groups.${paxboardGroup} = {};

  # Create the systemd service
  systemd.services.paxboard = {
    description = "paxboard";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      User = paxboardUser;
      Group = paxboardGroup;
      ExecStart = "/mnt/ssd2/paxboard/target/release/paxboard";
      WorkingDirectory = "/mnt/ssd2/paxboard";
      Restart = "always";
      RestartSec = "10";

      # Security settings
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;

      # Limit resource usage
      LimitNOFILE = 65536;
      LimitNPROC = 1024;
    };

    environment = {
      # Set any environment variables the service might need
      RUST_LOG = "info";
    };
  };

  # Open firewall port 1729
  networking.firewall.allowedTCPPorts = [ 1729 ];
}