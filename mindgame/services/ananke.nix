# Runs under the interactive user rather than redline's dedicated `ai`
# user — mindgame is a personal desktop, not a headless service box.
{ config, pkgs, ... }:

let
  lib = pkgs.lib;
  anankeLib = import ../../common-all/ananke-lib.nix { inherit lib; };

  home = config.users.users.${config.mainUser}.home;
  anankeDir = "${home}/programming/ananke";

  openaiPort = 7070;
  managementPort = 7071;
  llmBasePort = 8200;

  vllmEnv = {
    PATH = lib.makeBinPath [ pkgs.docker pkgs.coreutils pkgs.bash ];
    HOME = home;
  };

  diffusiongemmaScript = "${home}/ai/diffusiongemma/diffusiongemma.sh";
  diffusiongemmaUpstreamModel = "nvidia/diffusiongemma-26B-A4B-it-NVFP4";

  # Two modes, one port each, so both can be registered with ananke at
  # once (only one is ever resident — each pledges most of the 5090's 32
  # GiB). vramGb/perGpuMib follow each mode's gpu-memory-utilization
  # target; CONTAINER_SUFFIX keeps their docker container names distinct.
  diffusiongemmaServices = [
    (anankeLib.mkVllmService {
      name = "diffusiongemma-26b-a4b-2x128k";
      port = llmBasePort;
      script = diffusiongemmaScript;
      scriptArgs = [ "2x128k" ];
      upstreamModel = diffusiongemmaUpstreamModel;
      vramGb = 23;
      perGpuMib = 23500;
      gpuIndices = [ 0 ];
      env = vllmEnv;
      extraEnv = { CONTAINER_SUFFIX = "-2x128k"; };
      description = "DiffusionGemma 26B (A4B) served by vLLM (NVFP4, 2x128k mode).";
    })
    (anankeLib.mkVllmService {
      name = "diffusiongemma-26b-a4b-256k";
      port = llmBasePort + 1;
      script = diffusiongemmaScript;
      scriptArgs = [ "1x256k" ];
      upstreamModel = diffusiongemmaUpstreamModel;
      vramGb = 22;
      perGpuMib = 23000;
      gpuIndices = [ 0 ];
      env = vllmEnv;
      extraEnv = { CONTAINER_SUFFIX = "-256k"; };
      description = "DiffusionGemma 26B (A4B) served by vLLM (NVFP4, 1x256k mode).";
    })
  ];

  ananke_config = {
    daemon = {
      management_listen = "0.0.0.0:${toString managementPort}";
      allow_external_management = true;
      allow_external_services = true;
      data_dir = "${anankeDir}/data";
    };
    openai_api = {
      listen = "0.0.0.0:${toString openaiPort}";
    };
    service = diffusiongemmaServices;
  };

  tomlFormat = pkgs.formats.toml { };
  configFile = tomlFormat.generate "ananke-config.toml" ananke_config;
in
{
  options.ai.ananke = {
    openaiPort = lib.mkOption {
      type = lib.types.port;
      default = openaiPort;
      readOnly = true;
      description = "Port ananke's OpenAI-compatible API listens on.";
    };
    managementPort = lib.mkOption {
      type = lib.types.port;
      default = managementPort;
      readOnly = true;
      description = "Port ananke's management API (including /metrics) listens on.";
    };
  };

  config = {
    systemd.services.ananke = anankeLib.mkAnankeSystemdService {
      inherit anankeDir configFile;
      user = config.mainUser;
      group = "users";
      after = [ "docker.service" "network.target" ];
      requires = [ "docker.service" ];
      path = [ pkgs.docker pkgs.curl pkgs.bash ];
      environment.LD_LIBRARY_PATH = "/run/opengl-driver/lib";
    };

    networking.firewall.allowedTCPPorts = [ openaiPort managementPort llmBasePort (llmBasePort + 1) ];
  };
}
