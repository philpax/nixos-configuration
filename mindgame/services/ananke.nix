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

  # vramGb/perGpuMib: script's default mode targets gpu-memory-utilization
  # 0.715 of the 5090's 32 GiB. upstreamModel matches vLLM's default
  # served-model-name since the script doesn't pass --served-model-name.
  diffusiongemmaService = anankeLib.mkVllmService {
    name = "diffusiongemma";
    port = llmBasePort;
    script = "${home}/ai/diffusiongemma/diffusiongemma.sh";
    upstreamModel = "nvidia/diffusiongemma-26B-A4B-it-NVFP4";
    vramGb = 23;
    perGpuMib = 23500;
    gpuIndices = [ 0 ];
    env = vllmEnv;
    description = "DiffusionGemma 26B (A4B) served by vLLM (NVFP4, 2x128k mode).";
  };

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
    service = [ diffusiongemmaService ];
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

    networking.firewall.allowedTCPPorts = [ openaiPort managementPort llmBasePort ];
  };
}
