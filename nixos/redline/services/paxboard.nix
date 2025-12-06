{ config, pkgs, ... }:

let
  folders = import ../folders.nix;

  # Create a dedicated user for paxboard
  paxboardUser = "paxboard";
  paxboardGroup = "paxboard";
in
{
  # Create the paxboard user and group
  users.users.${paxboardUser} = {
    isSystemUser = true;
    group = paxboardGroup;
    extraGroups = [ "editabledata" ];
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

      # Set up the environment
      Environment = [
        "NODE_ENV=development"
        "PATH=${pkgs.nodejs}/bin:${pkgs.nodePackages.npm}/bin:/run/current-system/sw/bin"
      ];

      # The actual command
      ExecStart = "${pkgs.nodejs}/bin/npm run dev";
      WorkingDirectory = folders.paxboard;
      ReadWritePaths = [
        folders.paxboard
      ];
      Restart = "always";
      RestartSec = "10";

      # Security settings
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = false;  # Required for nvidia-smi access
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;

      # Limit resource usage
      LimitNOFILE = 65536;
      LimitNPROC = 1024;
    };
  };

  # Open firewall port 1729
  networking.firewall.allowedTCPPorts = [ 1729 ];
}