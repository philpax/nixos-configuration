{ config, pkgs, ... }:

let
  folders = import ../folders.nix;
in {
  users.users.ai.extraGroups = [ "editabledata" ];

  systemd.services.paxcord = {
    description = "paxcord";
    after = [ "largemodelproxy.service" ];
    requires = [ "largemodelproxy.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      User = "ai";
      Group = "ai";
      WorkingDirectory = folders.ai.paxcord;
      ExecStart = "${folders.ai.paxcord}/target/debug/paxcord";
      Restart = "always";
      RestartSec = "10s";
      Environment = [ "RUST_BACKTRACE=1" ];
    };
  };
}