{ config, pkgs, ... }:

let
  folders = import ../folders.nix;
in {
  systemd.services.largemodelproxy = {
    description = "Large Model Proxy";
    after = [ "docker.service" "network.target" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.ai.llamaCppCuda pkgs.docker pkgs.curl pkgs.bash ];

    serviceConfig = {
      User = "ai";
      Group = "ai";
      WorkingDirectory = folders.ai.largeModelProxy;
      ExecStart = "${folders.ai.largeModelProxy}/large-model-proxy -c ${config.ai.largeModelProxy.jsonFile}";
      Restart = "always";
      RestartSec = "10s";
    };
  };
}