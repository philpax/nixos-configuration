# Runs under the interactive user rather than redline's dedicated `ai`
# user — mindgame is a personal desktop.
{ config, pkgs, ... }:

let
  lib = pkgs.lib;
  anankeLib = import ../../common-all/ananke-lib.nix { inherit lib; };

  home = config.users.users.${config.mainUser}.home;
  anankeDir = "${home}/programming/ananke";

  vllmEnv = {
    PATH = lib.makeBinPath [ pkgs.docker pkgs.coreutils pkgs.bash ];
    HOME = home;
  };

  museGlimmerRoot = "${home}/ai/muse-glimmer";
  museGlimmerModelsDir = "${museGlimmerRoot}/models";

  inherit (anankeLib.mkAnankeConfig {
    inherit pkgs anankeDir;
    openaiPort = anankeLib.ports.openai;
    managementPort = anankeLib.ports.management;
    services = anankeLib.mkIndexedServices {
      basePort = 8200;
      models = [
        # Two modes; only one is ever resident (each pledges most of the
        # 5090's 32 GiB). CONTAINER_SUFFIX keeps their docker container
        # names distinct.
        {
          kind = "vllm";
          name = "diffusiongemma-26b-a4b-2x128k";
          scriptArgs = [ "2x128k" ];
          vramGb = 23;
          perGpuMib = 23500;
          extraEnv = { CONTAINER_SUFFIX = "-2x128k"; };
          description = "DiffusionGemma 26B (A4B) served by vLLM (NVFP4, 2x128k mode).";
        }
        {
          kind = "vllm";
          name = "diffusiongemma-26b-a4b-256k";
          scriptArgs = [ "1x256k" ];
          vramGb = 22;
          perGpuMib = 23000;
          extraEnv = { CONTAINER_SUFFIX = "-256k"; };
          description = "DiffusionGemma 26B (A4B) served by vLLM (NVFP4, 1x256k mode).";
        }
        # `template = "llama-cpp"` (dynamic, estimator-driven
        # allocation), not vLLM's `command` template: ananke's
        # `--spec-type draft-dflash` support sizes the reservation, so
        # there's no static vram_gb to hand-pick. `launcher` runs
        # llama-server in a Docker container instead of natively.
        {
          name = "muse-glimmer";
          model = "${museGlimmerModelsDir}/muse-glimmer-30B-kquant-dynamic.gguf";
          mmproj = "${museGlimmerModelsDir}/mmproj-kquant.gguf";
          extra = {
            launcher = [ "${museGlimmerRoot}/muse-glimmer.sh" "{model}" "{args}" ];
            draft_model = "${museGlimmerModelsDir}/dflash-kquant.gguf";
            spec_type = "draft-dflash";
            context = 262144;
            parallel = 2;
            env = vllmEnv;
            # Must match the `--cgroup-parent` muse-glimmer.sh passes to
            # `docker run`, and the `systemd.slices` name below.
            tracking.cgroup_parent = "/ananke.slice/ananke-muse-glimmer.slice";
            devices.gpu_allow = [ 0 ];
            health = {
              http = "/health";
              timeout = "5m";
            };
            description = "Muse Glimmer 30B served by llama.cpp in Docker (dflash speculative decoding).";
          };
        }
      ];
      buildVllm = port: m: anankeLib.mkVllmService {
        inherit (m) name vramGb perGpuMib description;
        inherit port;
        script = "${home}/ai/diffusiongemma/diffusiongemma.sh";
        scriptArgs = m.scriptArgs or [ ];
        upstreamModel = "nvidia/diffusiongemma-26B-A4B-it-NVFP4";
        gpuIndices = [ 0 ];
        env = vllmEnv;
        extraEnv = m.extraEnv or { };
      };
      buildLlamaCpp = port: m: anankeLib.mkLlmService {
        inherit (m) name model;
        inherit port;
        mmproj = m.mmproj or null;
        extra = m.extra or { };
      };
    };
  }) configFile;
in
{
  options.ai.ananke = {
    openaiPort = lib.mkOption {
      type = lib.types.port;
      default = anankeLib.ports.openai;
      readOnly = true;
      description = "Port ananke's OpenAI-compatible API listens on.";
    };
    managementPort = lib.mkOption {
      type = lib.types.port;
      default = anankeLib.ports.management;
      readOnly = true;
      description = "Port ananke's management API (including /metrics) listens on.";
    };
  };

  config = {
    # Declared explicitly so it exists at boot rather than racing
    # docker's lazy creation of it.
    systemd.slices."ananke-muse-glimmer" = {
      description = "Cgroup parent for ananke's muse-glimmer container";
    };

    systemd.services.ananke = anankeLib.mkAnankeSystemdService {
      inherit anankeDir configFile;
      user = config.mainUser;
      group = "users";
      after = [ "docker.service" "network.target" ];
      requires = [ "docker.service" ];
      path = [ pkgs.docker pkgs.curl pkgs.bash ];
      environment.LD_LIBRARY_PATH = "/run/opengl-driver/lib";
    };

    # Per-service ports are loopback-only (allowExternalServices
    # defaults to false); everything goes through openaiPort instead.
    networking.firewall.allowedTCPPorts = [ anankeLib.ports.openai anankeLib.ports.management ];
  };
}
