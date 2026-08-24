# Shared helpers for machines running a hand-built ananke checkout
# (https://github.com/philpax/ananke). Used by redline/ai/ananke.nix and
# mindgame/services/ananke.nix.
{ lib }:
let
  # The `[service.container]` block, shared by `mkContainerCommandService`
  # and by `llama-cpp` services passing one through `extra`.
  mkContainerBlock =
    { image
    , network ? "host"
    , containerPort ? null
    , ipc ? null
    , mounts ? [ ]
    , envPassthrough ? [ ]
      # Expanded once per GPU ananke's placement picks, so the container
      # sees exactly the devices the allocator reserved for it.
    , gpuDevice ? "nvidia.com/gpu=\${id}"
    , runtime ? "docker"
    }:
    { inherit image network runtime; }
    // lib.optionalAttrs (gpuDevice != null) { gpu_device = gpuDevice; }
    // lib.optionalAttrs (containerPort != null) { container_port = containerPort; }
    // lib.optionalAttrs (ipc != null) { inherit ipc; }
    // lib.optionalAttrs (mounts != [ ]) { inherit mounts; }
    // lib.optionalAttrs (envPassthrough != [ ]) { env_passthrough = envPassthrough; };

  # A read-only bind mount, the shape model and artifact mounts want.
  roMount = source: target: { inherit source target; read_only = true; };
in
{
  # `llama-cpp` services build their container block directly, since theirs
  # goes through `extra`.
  inherit mkContainerBlock roMount;

  ports = {
    openai = 7070;
    management = 7071;
  };

  # A `template = "llama-cpp"` service. Fields besides model/mmproj vary
  # too much per model to name here, so they go through `extra` — including
  # `launcher` and `container`, which are mutually exclusive.
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
  # with the entry in `builders` named by its `kind`, defaulting to
  # `llama-cpp`.
  mkIndexedServices =
    { basePort
    , models
    , builders
    }:
    lib.imap0
      (index: m:
        let kind = m.kind or "llama-cpp"; in
        (builders.${kind} or (throw "no builder for kind `${kind}`"))
          (basePort + index)
          m)
      models;

  # Projects `{ "--flag" = value; }` into argv. `true` emits a bare flag,
  # `false`/`null` omits it, anything else emits flag then value. Attribute
  # order is alphabetical, which is why this suits named flags rather than
  # positional arguments.
  flagArgs = attrs:
    lib.concatLists (lib.mapAttrsToList
      (flag: value:
        if value == null || value == false then [ ]
        else if value == true then [ flag ]
        else [ flag (toString value) ])
      attrs);

  # Projects an ananke model entry into the client-facing shape consumed by
  # `update-ai.py`. A model is exposed to clients (makima/Polytoken) iff its
  # entry carries a `client` attr; this helper derives `context_window` and
  # `supports_vision` from the runtime fields rather than duplicating them,
  # then merges the per-model `client` overrides (class, roles, reasoning,
  # max_output_tokens).
  #
  # `context_window` derivation, by runtime kind:
  #   ninfer    → `maxContext` (the reservation is exact).
  #   llama-cpp → `context / parallel`, unless `kv_unified` (the slots
  #              share one KV pool, so the full context survives).
  # `supports_vision` derivation:
  #   ninfer    → the `vision` flag.
  #   llama-cpp → an `mmproj` is present.
  mkClientModel = m:
    let
      kind = m.kind or "llama-cpp";
      extras = m.extra or m.extras or { };
      totalContext =
        if kind == "ninfer" then m.maxContext
        else extras.context or (throw "mkClientModel: llama-cpp model `${m.name}` needs extras.context");
      parallel = extras.parallel or 1;
      kvUnified = extras.kv_unified or false;
      context_window =
        if kind == "llama-cpp" && !kvUnified then totalContext / parallel
        else totalContext;
      supports_vision =
        if kind == "ninfer" then m ? vision && m.vision
        else m ? mmproj && m.mmproj != null;
    in
    {
      inherit (m) name;
      inherit context_window supports_vision;
    } // m.client;

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

  # `template = "command"` service whose workload runs in a container
  # ananke drives itself. ananke owns the lifecycle, so there is no script,
  # no `shutdown_command`, and no shell to hand a `PATH` — `env` is only
  # what the workload itself reads.
  #
  # `command` is the in-container argv, and should bind `${listen_host}` and
  # `${listen_port}`. Under `network = "host"` those resolve to `127.0.0.1`
  # and the allocated port; under `bridge` to `0.0.0.0` and
  # `containerPort`, with ananke publishing
  # `127.0.0.1:<allocated>:<containerPort>`. Bridge requires both.
  mkContainerCommandService =
    { name
    , port
    , image
    , command
    , upstreamModel
    , vramGb
    , perGpuMib
    , gpuIndices ? [ 0 ]
    , network ? "host"
    , containerPort ? null
    , ipc ? null
    , mounts ? [ ]
    , env ? { }
    , envPassthrough ? [ ]
    , gpuDevice ? "nvidia.com/gpu=\${id}"
    , runtime ? "docker"
    , description ? null
    , modality ? null
    , idleTimeout ? "60m"
    # Above ananke's default priority (50) — these backends' cold start is
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
      inherit name port command;
      idle_timeout = idleTimeout;
      inherit priority;
      allocation = {
        mode = "static";
        reserve_gb = vramGb;
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
      container = mkContainerBlock {
        inherit image network containerPort ipc mounts envPassthrough gpuDevice runtime;
      };
    }
    # Elided when empty rather than emitted as a bare `[service.env]`.
    // lib.optionalAttrs (env != { }) { inherit env; }
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
