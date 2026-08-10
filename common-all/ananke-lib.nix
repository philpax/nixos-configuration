# Shared helpers for machines running a hand-built ananke checkout
# (https://github.com/philpax/ananke). Used by redline/ai/ananke.nix and
# mindgame/services/ananke.nix.
{ lib }:
{
  # `script` must accept the allocated port as its last positional arg
  # (`{port}`, after any `scriptArgs`) and support `--stop` for teardown.
  # `env` has no default — ananke's spawner env_clear()s before exec, so
  # callers must supply at least PATH.
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

  # `binaryPath` defaults to a cargo-built checkout; Nix only wires up the
  # service, it doesn't build ananke.
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
