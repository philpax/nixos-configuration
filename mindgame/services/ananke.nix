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
    mkSourceImage mkPulledImage mkImageService;

  home = config.users.users.${config.mainUser}.home;
  anankeDir = "${home}/programming/ananke";

  diffusiongemmaRoot = "${home}/ai/diffusiongemma";
  # vLLM writes here across restarts. tmpfiles creates them: ananke does not
  # create mount sources, and Docker makes a missing one root-owned.
  diffusiongemmaCache = "${diffusiongemmaRoot}/cache/diffusiongemma";
  hfCache = "${home}/.cache/huggingface";

  museGlimmerModels = "${home}/ai/muse-glimmer/models";

  # Where ninfer's artifacts land inside the container.
  artifactsIn = "/artifacts";

  diffusiongemmaModel = "nvidia/diffusiongemma-26B-A4B-it-NVFP4";

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
        rev = "5f45a26f81b6a15805a3d4d09d5c3d60f420b210";
        hash = "sha256-fGyHdZOkKRTsarkHkUxYigZT2v1J+Fq/t3V3eOpAdL8=";
      };
    };

    # v0.26.0's digest. The tag is immutable upstream; the digest says so
    # locally too.
    vllm = mkPulledImage {
      name = "vllm-openai";
      ref = "vllm/vllm-openai";
      digest = "sha256:ffb2d59b1c059a5bd8d781320c9f5189de8293693b7d95da54befddaa54abf52";
    };

    # `server-cuda` moves, so muse-glimmer would otherwise run whatever
    # was last pulled by hand. This is that tag as of 2026-08-17; bump it
    # deliberately to take a newer llama.cpp.
    llamaCppServer = mkPulledImage {
      name = "llama.cpp-server-cuda";
      ref = "ghcr.io/ggml-org/llama.cpp";
      digest = "sha256:182a26fbd68d1774860bd2a0fb5581ba3047974307eaeee64930d8bf889e0c0c";
    };
  };

  # The model roster, hoisted so both `mkAnankeConfig` (below) and
  # `clientModels` (further below) can reference it.
  models = [
    # Two modes; only one is ever resident, each pledging most of the
    # 5090's 32 GiB.
    {
      kind = "diffusiongemma";
      name = "diffusiongemma-26b-a4b-2x128k";
      vramGb = 23;
      perGpuMib = 23500;
      maxModelLen = 131072;
      maxNumSeqs = 2;
      gpuMemoryUtilization = "0.715";
      description = "DiffusionGemma 26B (A4B) served by vLLM (NVFP4, 2x128k mode).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    {
      kind = "diffusiongemma";
      name = "diffusiongemma-26b-a4b-256k";
      vramGb = 22;
      perGpuMib = 23000;
      maxModelLen = 262144;
      maxNumSeqs = 1;
      gpuMemoryUtilization = "0.70";
      description = "DiffusionGemma 26B (A4B) served by vLLM (NVFP4, 1x256k mode).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    # `llama-cpp` rather than `command`: ananke's `--spec-type
    # draft-dflash` support sizes the reservation, so there is no static
    # reserve_gb to hand-pick. ananke generates the llama-server argv and
    # runs it as the container's command.
    {
      name = "muse-glimmer";
      # Host paths: the estimator reads these GGUFs off disk. ananke
      # translates them through the mount when it generates the argv,
      # so llama-server sees `/models/...`.
      model = "${museGlimmerModels}/muse-glimmer-30B-kquant-dynamic.gguf";
      mmproj = "${museGlimmerModels}/mmproj-kquant.gguf";
      extra = {
        draft_model = "${museGlimmerModels}/dflash-kquant.gguf";
        spec_type = "draft-dflash";
        context = 262144;
        parallel = 2;
        devices.gpu_allow = [ 0 ];
        health = { http = "/health"; timeout = "5m"; };
        description = "Muse Glimmer 30B served by llama.cpp in Docker (dflash speculative decoding).";
        container = anankeLib.mkContainerBlock {
          image = images.llamaCppServer.tag;
          network = "host";
          mounts = [ (roMount museGlimmerModels "/models") ];
        };
      };
      client = {
        class = "medium";
        reasoning = { type = "none"; };
        max_output_tokens = 32768;
      };
    }
    # Vision freezes at startup, so each model has a separate text/vision
    # pair; DFlash is 35B-A3B-only and text-only, so its vision pair uses
    # MTP instead. Context and vram figures come from empirical
    # --max-concurrency 1 sizing trials on this GPU.
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
        roles = [ "full" "mini" ];
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
        roles = [ "nano" ];
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
    # Qwen3.8-27B: same architecture as the 3.6 pair and loaded by the
    # same ninfer target, but groupwise-int rather than NVFP4. Its
    # weights measure lighter (16.67/16.95 GiB vs 16.82/17.05), and the
    # text mode spends the slack on context: 221184 tokens costs 7.95
    # GiB of runtime against the vision mode's 7.32 GiB, so both reserve
    # 26 GiB.
    {
      kind = "ninfer";
      name = "qwen3.8-27b-ninfer-mtp3";
      upstreamModel = "qwen3.8-27b";
      artifact = "qwen3_8_27b.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 221184;
      spec = "mtp";
      draftTokens = 3;
      description = "Qwen3.8-27B served by ninfer (MTP=3, 221184 ctx, text-only).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    {
      kind = "ninfer";
      name = "qwen3.8-27b-ninfer-mtp3-vision";
      # The Podman canary. Its image has to be in Podman's own store,
      # which does not share Docker's — see the README note on loading it.
      runtime = "podman";
      upstreamModel = "qwen3.8-27b";
      artifact = "qwen3_8_27b.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 147456;
      spec = "mtp";
      draftTokens = 3;
      vision = true;
      description = "Qwen3.8-27B served by ninfer (MTP=3, 147456 ctx, vision).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    # The NVFP4 weight profile of that same target: 20.02 GiB of weights
    # against the groupwise-int build's 16.96, and 26 GiB is already the
    # ceiling this desktop leaves, so the extra comes out of context.
    #
    # Both contexts are the largest that loaded against a ~4.3 GiB desktop
    # baseline. ninfer sizes its reservation up front, so if the desktop
    # grows these refuse to start rather than failing partway through.
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
  ];

  inherit (anankeLib.mkAnankeConfig {
    inherit pkgs anankeDir;
    openaiPort = anankeLib.ports.openai;
    managementPort = anankeLib.ports.management;
    services = anankeLib.mkIndexedServices {
      basePort = 8200;
      builders = {
        diffusiongemma = port: m: anankeLib.mkContainerCommandService {
          inherit (m) name vramGb perGpuMib description;
          inherit port;
          image = images.vllm.tag;
          upstreamModel = diffusiongemmaModel;
          # The image declares its own ENTRYPOINT, so the argv is flags only.
          command = flagArgs {
            "--model" = diffusiongemmaModel;
            "--load-format" = "safetensors";
            "--safetensors-load-strategy" = "lazy";
            "--attention-backend" = "TRITON_ATTN";
            "--enable-prefix-caching" = true;
            "--max-model-len" = m.maxModelLen;
            "--max-num-seqs" = m.maxNumSeqs;
            "--gpu-memory-utilization" = m.gpuMemoryUtilization;
            "--diffusion-config" = ''{"canvas_length": 256}'';
            "--override-generation-config" = ''{"max_new_tokens": null}'';
            "--default-chat-template-kwargs" = ''{"enable_thinking": true}'';
            "--enable-auto-tool-choice" = true;
            "--tool-call-parser" = "gemma4";
            "--reasoning-parser" = "gemma4";
            "--mm-processor-kwargs" = ''{"max_soft_tokens": 1120}'';
            "--limit-mm-per-prompt" = ''{"image": 7}'';
            # Bridge networking: 0.0.0.0 and the container port.
            "--host" = "\${listen_host}";
            "--port" = "\${listen_port}";
          };
          # vLLM binds a fixed 8000 inside the container.
          network = "bridge";
          containerPort = 8000;
          # Multi-worker vLLM needs the host's /dev/shm.
          ipc = "host";
          env = {
            VLLM_NO_USAGE_STATS = "1";
            OMP_NUM_THREADS = "1";
            PYTORCH_CUDA_ALLOC_CONF = "max_split_size_mb:512";
          };
          # Forwarded by name from the daemon's environment if set; the
          # model is public, so this only lifts rate limits.
          envPassthrough = [ "HF_TOKEN" ];
          mounts = [
            { source = hfCache; target = "/root/.cache/huggingface"; }
            {
              source = "${diffusiongemmaCache}/torch_compile";
              target = "/root/.cache/vllm/torch_compile_cache";
            }
            { source = "${diffusiongemmaCache}/triton"; target = "/root/.triton/cache"; }
          ];
        };

        llama-cpp = port: m: anankeLib.mkLlmService {
          inherit (m) name model;
          inherit port;
          mmproj = m.mmproj or null;
          extra = m.extra or { };
        };

        ninfer = port: m: anankeLib.mkContainerCommandService {
          inherit (m) name vramGb perGpuMib description upstreamModel;
          inherit port;
          image = images.ninfer.tag;
          # Per-model so one service can exercise a second runtime while the
          # rest stay on Docker.
          runtime = m.runtime or "docker";
          # Replaces the image's CMD, so the executable leads.
          # `--kv-capacity` tracks the context exactly, keeping the static
          # reservation honest.
          command = [ "ninfer-serve" "${artifactsIn}/${m.artifact}" ] ++ flagArgs {
            "--host" = "\${listen_host}";
            "--port" = "\${listen_port}";
            "--max-context" = m.maxContext;
            "--kv-capacity" = m.maxContext;
            "--kv-dtype" = "int8";
            "--max-concurrency" = 1;
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

  # The subset of `models` exposed to Maki/Polytoken clients, projected into
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
      description = "Models exposed to Maki/Polytoken clients, with context_window and supports_vision derived from the runtime config. Consumed by update-ai.py.";
    };
  };

  config = {
    systemd.tmpfiles.rules =
      let owner = config.mainUser; in
      [
        "d ${diffusiongemmaRoot}/cache 0755 ${owner} users -"
        "d ${diffusiongemmaCache} 0755 ${owner} users -"
        "d ${diffusiongemmaCache}/torch_compile 0755 ${owner} users -"
        "d ${diffusiongemmaCache}/triton 0755 ${owner} users -"
        "d ${hfCache} 0755 ${owner} users -"
      ];

    # Runs as the interactive user: Podman's store here is that user's
    # rootless one, and the canary's image has to land in it.
    systemd.services.container-images = mkImageService {
      images = lib.attrValues images;
      podmanImages = [ images.ninfer ];
      user = config.mainUser;
    };

    systemd.services.ananke = anankeLib.mkAnankeSystemdService {
      inherit anankeDir configFile;
      user = config.mainUser;
      group = "users";
      after = [ "docker.service" "network.target" ];
      requires = [ "docker.service" ];
      # ananke invokes the runtime CLIs directly, so both are on its own
      # PATH; the containers get no PATH from here.
      path = [ pkgs.docker pkgs.podman pkgs.curl pkgs.bash ];
      environment.LD_LIBRARY_PATH = "/run/opengl-driver/lib";
    };

    # Per-service ports are loopback-only (allowExternalServices defaults to
    # false); everything goes through openaiPort instead.
    networking.firewall.allowedTCPPorts = [ anankeLib.ports.openai anankeLib.ports.management ];
  };
}
