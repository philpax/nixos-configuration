{ config, pkgs, ... }:

let
  folders = import ../folders.nix;

  minecraftUser = "minecraft";
  minecraftGroup = "minecraft";
  minecraftDir = folders.minecraft;
  jdk = pkgs.temurin-bin-21;
in
{
  users.users.${minecraftUser} = {
    isSystemUser = true;
    group = minecraftGroup;
    description = "Minecraft server service user";
    home = minecraftDir;
    shell = "${pkgs.bash}/bin/bash";
  };

  users.groups.${minecraftGroup} = {};

  systemd.services.minecraft-server = {
    description = "Minecraft (NeoForge) server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # start.sh shells out to `java`, curl, awk, etc. — make them all resolvable.
    path = [ jdk pkgs.bash pkgs.coreutils pkgs.curl pkgs.gawk pkgs.gnugrep pkgs.gnused ];

    serviceConfig = {
      Type = "simple";
      User = minecraftUser;
      Group = minecraftGroup;

      WorkingDirectory = minecraftDir;
      # Run as root to fix ownership before dropping to the minecraft user.
      ExecStartPre = "+${pkgs.coreutils}/bin/chown -R ${minecraftUser}:${minecraftGroup} ${minecraftDir}";
      ExecStart = "${pkgs.bash}/bin/bash ${minecraftDir}/start.sh";

      StandardInput = "null";
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "minecraft-server";

      Restart = "on-failure";
      RestartSec = "10";

      ReadWritePaths = [ minecraftDir ];

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;

      LimitNOFILE = 65536;

      # Keep the 16G JVM heap out of swap. The box has 125G RAM, but with the
      # default swappiness the kernel was paging ~6G of the live heap to disk;
      # G1GC then stalled multi-second pulling it back in during collections,
      # which showed up as periodic "Can't keep up!" tick lag. Pin this cgroup
      # to RAM only.
      MemorySwapMax = 0;
    };
  };

  networking.firewall.allowedTCPPorts = [ 25565 25566 ];
}
