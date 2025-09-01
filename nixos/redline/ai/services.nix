{ config, pkgs, ... }:

{
  systemd.services.largemodelproxy = {
    description = "Large Model Proxy";
    after = [ "docker.service" "network.target" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.ai.llamaCppCuda pkgs.docker pkgs.curl pkgs.bash ];

    serviceConfig = {
      User = "ai";
      Group = "ai";
      WorkingDirectory = "/mnt/ssd2/ai/large-model-proxy";
      ExecStart = "/mnt/ssd2/ai/large-model-proxy/large-model-proxy -c ${config.ai.largeModelProxy.jsonFile}";
      Restart = "always";
      RestartSec = "10s";
    };
  };

  systemd.services.llmcord = {
    description = "llmcord";
    after = [ "largemodelproxy.service" ];
    requires = [ "largemodelproxy.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      User = "ai";
      Group = "ai";
      WorkingDirectory = "/mnt/ssd2/ai/llmcord";
      ExecStart = "/mnt/ssd2/ai/llmcord/target/debug/llmcord";
      Restart = "always";
      RestartSec = "10s";
      Environment = [ "RUST_BACKTRACE=1" ];
    };
  };
}