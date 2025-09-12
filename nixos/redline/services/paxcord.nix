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
      WorkingDirectory = "/mnt/ssd2/ai/paxcord";
      ExecStart = "/mnt/ssd2/ai/paxcord/target/debug/paxcord";
      Restart = "always";
      RestartSec = "10s";
      Environment = [ "RUST_BACKTRACE=1" ];
    };
  };
}