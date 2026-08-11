# Shared helpers for machines running a hand-built ananke checkout
# (https://github.com/philpax/ananke). Used by redline/ai/ananke.nix and
# mindgame/services/ananke.nix.
{ lib }:
{
  ports = {
    openai = 7070;
    management = 7071;
  };

  # A `template = "llama-cpp"` service. Fields besides model/mmproj vary
  # too much per model to name here, so they go through `extra` —
  # including `launcher`, which fronts llama-server with a Docker/podman
  # wrapper instead of running it natively.
  mkLlmService =
    { name
    , port
    , model
    , mmproj ? null
    , extra ? { }
    }:
    { template = "llama-cpp"; inherit name port model; }
    // lib.optionalAttrs (mmproj != null) { inherit mmproj; }
    // extra;

  # Assigns each `models` entry a port (`basePort + index`) and builds it
  # with `buildVllm` or `buildLlamaCpp`, picked by `kind` (`"vllm"`,
  # else llama-cpp).
  mkIndexedServices =
    { basePort
    , models
    , buildVllm
    , buildLlamaCpp
    }:
    lib.imap0
      (index: m:
        let port = basePort + index; in
        if (m.kind or "llama-cpp") == "vllm"
        then buildVllm port m
        else buildLlamaCpp port m)
      models;

  # `allowExternalServices` defaults to `false` (loopback-only per-service
  # reverse proxies): the openai_api multiplexer already routes by
  # `model` name internally, and those proxies carry no auth of their own.
  mkAnankeConfig =
    { pkgs
    , openaiPort
    , managementPort
    , anankeDir
    , services
    , allowExternalManagement ? true
    , allowExternalServices ? false
    }:
    let
      ananke_config = {
        daemon = {
          management_listen = "0.0.0.0:${toString managementPort}";
          allow_external_management = allowExternalManagement;
          allow_external_services = allowExternalServices;
          data_dir = "${anankeDir}/data";
        };
        openai_api.listen = "0.0.0.0:${toString openaiPort}";
        service = services;
      };
    in
    {
      inherit ananke_config;
      configFile = (pkgs.formats.toml { }).generate "ananke-config.toml" ananke_config;
    };

  # `script` must accept the allocated port as its last positional arg
  # and support `--stop` for teardown. `env` has no default — ananke's
  # spawner env_clear()s before exec.
  mkVllmService =
    { name
    , port
    , script
    , upstreamModel
    , vramGb
    , perGpuMib
    , env
    , gpuIndices ? [ 0 1 ]
    , scriptArgs ? [ ]
    , description ? null
    , modality ? null
    , extraEnv ? { }
    , idleTimeout ? "60m"
    # Above ananke's default priority (50) — vLLM's cold start is
    # expensive enough to be worth protecting from eviction.
    , priority ? 70
    , healthTimeout ? "10m"
    }:
    let
      mkPlacementEntry = idx: lib.nameValuePair "gpu:${toString idx}" perGpuMib;
      placementOverride = lib.listToAttrs (map mkPlacementEntry gpuIndices);
    in
    {
      template = "command";
      inherit name port;
      command = [ script ] ++ scriptArgs ++ [ "{port}" ];
      shutdown_command = [ script "--stop" ];
      env = env // extraEnv;
      idle_timeout = idleTimeout;
      inherit priority;
      allocation = {
        mode = "static";
        vram_gb = vramGb;
      };
      devices = {
        placement = "gpu-only";
        placement_override = placementOverride;
      };
      health = {
        http = "/health";
        timeout = healthTimeout;
      };
      openai_proxy = {
        upstream_model = upstreamModel;
      };
    }
    // lib.optionalAttrs (description != null) { inherit description; }
    // lib.optionalAttrs (modality != null) { inherit modality; };

  # `binaryPath` defaults to a cargo-built checkout — Nix wires up the
  # service but doesn't build ananke.
  mkAnankeSystemdService =
    { anankeDir
    , configFile
    , user
    , group ? user
    , binaryPath ? "${anankeDir}/target/debug/ananke"
    , after ? [ "network.target" ]
    , requires ? [ ]
    , path ? [ ]
    , environment ? { }
    }:
    {
      description = "Ananke";
      inherit after requires path environment;
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = user;
        Group = group;
        WorkingDirectory = anankeDir;
        ExecStart = "${binaryPath} --config ${configFile}";
        Restart = "always";
        RestartSec = "10s";
      };
    };
}
