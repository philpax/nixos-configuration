{ config, pkgs, ... }:

{
  systemd.services.paxcord = {
    description = "paxcord";
    after = [ "largemodelproxy.service" ];
    requires = [ "largemodelproxy.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      User = "ai";
      Group = "ai";
      WorkingDirectory = "/mnt/ssd0/ai/paxcord";
      ExecStart = "/mnt/ssd0/ai/paxcord/target/debug/paxcord";
      Restart = "always";
      RestartSec = "10s";
      Environment = [ "RUST_BACKTRACE=1" ];
    };
  };
}