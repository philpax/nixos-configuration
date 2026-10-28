# Runs under the interactive user rather than redline's dedicated `ai`
# user — mindgame is a personal desktop.
#
# Every service runs its workload in a container ananke drives itself
# (`[service.container]`): ananke creates, starts, follows logs, reads the
# exit status, signals, removes, and reconciles leftovers on restart.
{ config, pkgs, ... }:

let
  lib = pkgs.lib;
  anankeLib = import ../../common-all/ananke-lib.nix { inherit lib; };
  inherit (anankeLib) flagArgs roMount;
  inherit (import ../../common-all/container-images.nix { inherit pkgs lib; })
    mkSourceImage mkImageService;

  home = config.users.users.${config.mainUser}.home;
  anankeDir = "${home}/programming/ananke";

  hfCache = "${home}/.cache/huggingface";
  ggufDir = "${home}/ai/gguf";

  # Where ninfer's artifacts land inside the container.
  artifactsIn = "/artifacts";

  images = {
    # Built from ninfer's own Dockerfile — a CUDA source build, so the
    # first run after a bump takes a while. Pinned rather than pointed at
    # a working tree, so the tag says which commit is running.
    #
    # This revision is the floor for the Qwen3.8 NVFP4 profile: the binder
    # and FP8 execution leaves it selects landed in 5d2c1f5, so the older
    # pin loads every other artifact here but not that one.
    ninfer = mkSourceImage {
      name = "ninfer";
      src = pkgs.fetchFromGitHub {
        owner = "Neroued";
        repo = "ninfer";
        rev = "81c8ce093b2c1646a87566a8e59d807fcf0ec95c";
        hash = "sha256-D+rrNhQ5+cvQu1Ylhlzu36WJZgGLmKydeGLGz8KZ/c8=";
      };
    };
  };

  # The model roster, hoisted so both `mkAnankeConfig` (below) and
  # `clientModels` (further below) can reference it.
  models = [
    # Vision is fixed at startup, so each model has separate text/vision
    # profiles. Qwen3.6 DFlash is text-only; vision profiles use MTP.
    # Context and VRAM limits retain the existing sizing values.
    {
      kind = "ninfer";
      name = "qwen3.6-27b-ninfer-mtp3";
      upstreamModel = "qwen3.6-27b";
      artifact = "qwen3_6_27b_nvfp4.ninfer";
      vramGb = 25;
      perGpuMib = 25500;
      maxContext = 196608;
      spec = "mtp";
      draftTokens = 3;
      description = "Qwen3.6-27B (NVFP4) served by ninfer (MTP=3, 196608 ctx, text-only).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    {
      kind = "ninfer";
      name = "qwen3.6-27b-ninfer-mtp3-vision";
      upstreamModel = "qwen3.6-27b";
      artifact = "qwen3_6_27b_nvfp4.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 147456;
      spec = "mtp";
      draftTokens = 3;
      vision = true;
      description = "Qwen3.6-27B (NVFP4) served by ninfer (MTP=3, 147456 ctx, vision).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    {
      kind = "ninfer";
      name = "qwen3.6-35b-a3b-ninfer-dflash7";
      upstreamModel = "qwen3.6-35b-a3b";
      artifact = "qwen3_6_35b_a3b.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 262144;
      spec = "dflash";
      draftTokens = 7;
      description = "Qwen3.6-35B-A3B served by ninfer (DFlash=7, 262144 ctx, text-only).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    {
      kind = "ninfer";
      name = "qwen3.6-35b-a3b-ninfer-dflash7-c2";
      upstreamModel = "qwen3.6-35b-a3b";
      artifact = "qwen3_6_35b_a3b.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      # 2x concurrency against the same KV pool as the c1 profile. Each lane
      # gets half the per-session context (131072), so two lanes at full
      # context still fit the 262144-token pool and the VRAM reservation is
      # unchanged — `--max-concurrency` only adds lanes, not KV.
      maxContext = 131072;
      kvCapacity = 262144;
      maxConcurrency = 2;
      spec = "dflash";
      draftTokens = 7;
      description = "Qwen3.6-35B-A3B served by ninfer (DFlash=7, 131072 ctx x2 lanes, text-only).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    {
      kind = "ninfer";
      name = "qwen3.6-35b-a3b-ninfer-mtp3-vision";
      upstreamModel = "qwen3.6-35b-a3b";
      artifact = "qwen3_6_35b_a3b.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 163840;
      spec = "mtp";
      draftTokens = 3;
      vision = true;
      description = "Qwen3.6-35B-A3B served by ninfer (MTP=3, 163840 ctx, vision).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    {
      kind = "ninfer";
      name = "ornith-1.5-35b-a3b-ninfer-dflash7";
      upstreamModel = "qwen3.6-35b-a3b";
      artifact = "Ornith-1.5-35B-A3B-MTP.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 262144;
      spec = "dflash";
      draftTokens = 7;
      description = "Ornith 1.5 35B-A3B served by ninfer (DFlash=7, 262144 ctx, text-only).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    {
      kind = "ninfer";
      name = "qwen3.8-27b-nvfp4-ninfer-mtp3";
      upstreamModel = "qwen3.8-27b";
      artifact = "qwen3_8_27b_nvfp4.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 180224;
      spec = "mtp";
      draftTokens = 3;
      description = "Qwen3.8-27B (NVFP4) served by ninfer (MTP=3, 180224 ctx, text-only).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    {
      kind = "ninfer";
      name = "qwen3.8-27b-nvfp4-ninfer-mtp3-vision";
      upstreamModel = "qwen3.8-27b";
      artifact = "qwen3_8_27b_nvfp4.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 122880;
      spec = "mtp";
      draftTokens = 3;
      vision = true;
      description = "Qwen3.8-27B (NVFP4) served by ninfer (MTP=3, 122880 ctx, vision).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    # redline's QAT config cut down to one GPU: no tensor split, and a
    # single slot. f16 KV at this context does not fit alongside the desktop's
    # share of the 5090, so the cache is q8_0.
    {
      name = "gemma-4-31b-it-qat";
      file = "unsloth/gemma-4-31B-it-qat-GGUF/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf";
      mmproj = "unsloth/gemma-4-31B-it-qat-GGUF/mmproj-F16.gguf";
      extras = {
        context = 120000;
        flash_attn = true;
        cache_type_k = "q8_0";
        cache_type_v = "q8_0";
        cache_idle_slots = false;
        spec_type = "draft-mtp";
        spec_draft_n_max = 2;
        draft_model = "${ggufDir}/unsloth/gemma-4-31B-it-qat-GGUF/mtp-gemma-4-31B-it.gguf";
        # See redline/ai/ananke.nix for why the generation cap and the
        # disabled host-RAM prompt cache.
        extra_args = [ "-n" "16384" "--cache-ram" "0" ];
        sampling = {
          temperature = 1.0;
          top_k = 64;
          top_p = 0.95;
          min_p = 0.05;
          repeat_penalty = 1.0;
        };
      };
      client = {
        class = "medium";
        reasoning = { type = "none"; };
      };
    }
  ];

  inherit (anankeLib.mkAnankeConfig {
    inherit pkgs anankeDir;
    openaiPort = anankeLib.ports.openai;
    managementPort = anankeLib.ports.management;
    services = anankeLib.mkIndexedServices {
      basePort = 8200;
      builders = {
        llama-cpp = port: m: anankeLib.mkLlmService {
          inherit (m) name;
          inherit port;
          model = "${ggufDir}/${m.file}";
          mmproj = if m ? mmproj then "${ggufDir}/${m.mmproj}" else null;
          extra = { jinja = true; } // (m.extras or { });
        };
        ninfer = port: m: anankeLib.mkContainerCommandService {
          inherit (m) name vramGb perGpuMib description upstreamModel;
          inherit port;
          image = images.ninfer.tag;
          # Podman is the default; a model can still opt into another runtime
          # when an external compatibility workflow requires it.
          runtime = m.runtime or "podman";
          # Replaces the image's CMD, so the executable leads.
          # `--kv-capacity` defaults to `maxContext` (the per-session ceiling)
          # so the static reservation stays honest, but a model may raise it to
          # share a larger pool across concurrent lanes — ninfer's KV cache is a
          # single paged pool sized by `--kv-capacity`, independent of
          # `--max-concurrency` (which only sets the lane count).
          command = [ "ninfer-serve" "${artifactsIn}/${m.artifact}" ] ++ flagArgs {
            "--host" = "\${listen_host}";
            "--port" = "\${listen_port}";
            "--max-context" = m.maxContext;
            "--kv-capacity" = m.kvCapacity or m.maxContext;
            "--kv-dtype" = "int8";
            "--max-concurrency" = m.maxConcurrency or 1;
            "--vision" = m.vision or false;
            "--spec" = m.spec;
            "--draft-tokens" = m.draftTokens;
            "--lm-head-draft" = true;
          };
          network = "host";
          mounts = [ (roMount "${home}/ai/ninfer" artifactsIn) ];
        };
      };
      inherit models;
    };
  }) configFile;

  # The subset of `models` exposed to makima/Polytoken clients, projected into
  # the client-facing shape by `anankeLib.mkClientModel` (which derives
  # `context_window` and `supports_vision` from the runtime fields). Consumed
  # by `update-ai.py` via `nix eval`.
  clientModels = builtins.map anankeLib.mkClientModel (builtins.filter (m: m ? client) models);
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
    clientModels = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = clientModels;
      description = "Models exposed to makima/Polytoken clients, with context_window and supports_vision derived from the runtime config. Consumed by update-ai.py.";
    };
  };

  config = {
    systemd.tmpfiles.rules =
      let owner = config.mainUser; in
      [
        "d ${hfCache} 0755 ${owner} users -"
      ];

    # Runs as the interactive user: Podman's store here is that user's
    # rootless one, and the canary's image has to land in it.
    systemd.services.container-images = mkImageService {
      images = lib.attrValues images;
      user = config.mainUser;
      environment = {
        HOME = config.users.users.${config.mainUser}.home;
      };
      wants = [ "network-online.target" ];
    };

    systemd.services.ananke = anankeLib.mkAnankeSystemdService {
      inherit pkgs anankeDir configFile;
      user = config.mainUser;
      group = "users";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # ananke invokes Podman directly; no daemon is required.
      # The generated start wrapper derives XDG_RUNTIME_DIR from the service
      # process UID; the system-manager `%U` specifier would incorrectly be 0.
      environment = {
        HOME = config.users.users.${config.mainUser}.home;
        LD_LIBRARY_PATH = "/run/opengl-driver/lib";
      };
      path = [ config.ai.llamaCppCuda pkgs.podman pkgs.curl pkgs.bash ];
    };

    # Per-service ports are loopback-only (allowExternalServices defaults to
    # false); everything goes through openaiPort instead.
    networking.firewall.allowedTCPPorts = [ anankeLib.ports.openai anankeLib.ports.management ];
  };
}
