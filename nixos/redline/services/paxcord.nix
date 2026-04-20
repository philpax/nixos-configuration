{ config, pkgs, ... }:

let
  folders = import ../folders.nix;
in {
  systemd.services.paxcord = {
    description = "paxcord";
    after = [ "ananke.service" ];
    requires = [ "ananke.service" ];
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