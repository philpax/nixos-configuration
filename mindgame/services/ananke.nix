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

    # iamwavecut/ninfer-all, the line that carries the `gguf_blocks_v1`
    # loader GGUF-repackaged artifacts (the Swift GSQ-RCO series) need.
    # Upstream ninfer cannot load those. The Ryan-gsq fork the Swift card
    # names also can, but predates the fix for creating its cuBLAS handle
    # under graph capture, so wide verify graphs fail at startup there.
    #
    # Its Dockerfile builds every supported architecture by default; only the
    # 5090's is needed. The entrypoint selects the build and takes `serve`
    # rather than the binary's name. This pin adds Inkling 2 Mini and the
    # 2026-11-23 tensor-core decode attention.
    ninferAll = mkSourceImage {
      name = "ninfer-all";
      src = pkgs.fetchFromGitHub {
        owner = "iamwavecut";
        repo = "ninfer-all";
        rev = "ea7fbdafb159396806e83ce78c431f1dc42beb3f";
        hash = "sha256-nXhnomICtENPB5Zo5rHc6kSEXbU5lEyOU6kvFod5DDg=";
      };
      buildArgs = { ARCHS = "120a"; };
    } // { serveCommand = [ "serve" ]; };

    # Basalt, a Strata fork that serves Qwen3.8-Flash-Next and Inkling 2
    # Mini on Blackwell with the experts the GPU does not hold in pinned RAM.
    # It ships a Dockerfile now, but ours stays: it drops the CUDA
    # forward-compatibility libraries that break CUDA on GeForce cards and
    # keeps `bin/basalt` as the entrypoint the services' argv assumes.
    basalt = mkSourceImage {
      name = "basalt";
      src = pkgs.runCommand "basalt-context" {
        src = pkgs.fetchFromGitHub {
          owner = "jesdga95";
          repo = "basalt";
          rev = "ff0b978d2ee9ff195d113b6feb80961b2d2f99ef";
          hash = "sha256-kxj1d8LjQ3y2zUzI37IJgM0khGkL6XzKxnamkr6So6w=";
        };
      } ''
        cp -r $src $out
        chmod u+w $out
        rm -f $out/Dockerfile
        cp ${./basalt.Dockerfile} $out/Dockerfile
      '';
    };
  };

  basaltIn = "/models";

  # The model roster, hoisted so both `mkAnankeConfig` (below) and
  # `clientModels` (further below) can reference it.
  models = [
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
      name = "qwen3.8-27b-nvfp4-ninfer-mtp3-c4";
      upstreamModel = "qwen3.8-27b";
      artifact = "qwen3_8_27b_nvfp4.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      # 4x concurrency against the same KV pool as the c1 text profile. Each
      # lane gets a quarter of the per-session context (45056), so four lanes
      # at full context exactly fill the 180224-token pool.
      maxContext = 45056;
      kvCapacity = 180224;
      maxConcurrency = 4;
      spec = "mtp";
      draftTokens = 3;
      description = "Qwen3.8-27B (NVFP4) served by ninfer (MTP=3, 45056 ctx x4 lanes, text-only).";
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
    # Swift 1.5 (a Qwen3.8-27B fine-tune) at IQ3_S, the largest of its GGUF
    # tiers, on ninfer-all. The ~12 GiB of weights against Qwen3.8 NVFP4's
    # larger footprint leaves room for the engine's maximum of eight lanes at
    # 45056 tokens each within the same reservation: the engine reports
    # 12.9 GiB of runtime on top of 11.6 GiB of weights. rk8v4 (int8 keys,
    # int4 values) shrinks the KV to about three quarters of int8, which the
    # 360448-token pool needs to fit; FP16 GDN state halves each lane's
    # recurrent state. The artifact carries an MTP head but no DFlash drafter.
    {
      kind = "ninfer";
      name = "swift-1.5-qwen3.8-27b-iq3s-ninfer-mtp3-c8";
      # The artifact's own model id; ninfer-all refuses any other name.
      upstreamModel = "swift-1.5-qwen3.8-27b-gsq-rco-iq3s";
      artifact = "swift15_iq3s_mtp.ninfer";
      image = images.ninferAll;
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 45056;
      kvCapacity = 360448;
      maxConcurrency = 8;
      kvDtype = "rk8v4";
      extraFlags = { "--gdn-state-fp16" = true; };
      spec = "mtp";
      draftTokens = 3;
      description = "Swift 1.5 Qwen3.8-27B (IQ3_S) served by ninfer-all (MTP=3, 45056 ctx x8 lanes, text-only).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    # Inkling 2 Mini (26.4B-A3.4B, 24 layers run as 48 visits) at UD-IQ4_XS.
    # The artifact keeps 14.6 GiB of weights and the DSpark drafter on the
    # card; DSpark only drafts one request at a time, so batch work runs
    # `--spec none`. rk4v4 (int8 keys, int4 values) stores a token's full
    # attention K/V in 8.75 KiB, which fits eight sequences at 112k context
    # in 27.8 GiB. Eight concurrent requests decode at about 60 tok/s each.
    {
      kind = "ninfer";
      name = "inkling-2-mini-iq4xs-ninfer-rk4v4-c8";
      upstreamModel = "inkling-2-mini";
      modelId = "inkling-2-mini";
      artifact = "Inkling-2-Mini-UD-IQ4_XS-ninfer-v3.ninfer";
      image = images.ninferAll;
      vramGb = 28;
      perGpuMib = 27500;
      maxContext = 114688;
      kvCapacity = 917504;
      maxConcurrency = 8;
      kvDtype = "rk4v4";
      spec = "none";
      description = "Inkling 2 Mini (UD-IQ4_XS) served by ninfer-all (112k ctx x8 lanes, rk4v4, text-only).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    # Qwen3.8-Flash-Next (125B-A6B) at GSQ-RCO IQ3_S on Basalt. The expert
    # cache takes the VRAM left after the weights, the slots' KV and
    # `vram-reserve-mib`; with the desktop holding about 4.5 GiB of the card,
    # a 1800 MiB reserve measured 25974 MiB for the engine. The experts the
    # GPU does not hold (about 26 GiB) sit in pinned RAM while it is loaded.
    # `maxContext` is per slot; the engine's `--max-context` is shared across
    # `parallel` slots, and its KV is elastic, backing each slot's cells as
    # its context grows.
    #
    # Batching barely raises throughput: with a 70-85% expert-cache hit rate
    # the RAM-resident experts bound decode, and drafting mostly stops in
    # batch windows. Replayed JC2 decomp-harness requests (7K-token prompts,
    # 1-7K tokens of reasoning before a tool call) measured 274 tok/s
    # aggregate at six slots (62 each, median) and 270 at eight (43 each), so
    # six slots keep each session well above 50 tok/s at the same total.
    {
      kind = "basalt";
      name = "qwen3.8-flash-next-iq3s-basalt-c6";
      upstreamModel = "qwen3.8-flash-next-iq3s";
      pack = "Qwen3.8-FN-GSQ-RCO-IQ3_S.basalt";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 45056;
      parallel = 6;
      vramReserveMib = 1800;
      description = "Qwen3.8-Flash-Next GSQ-RCO IQ3_S served by Basalt (45056 ctx x6 slots, text-only).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    # The same aggregate pool as the c6 profile, split eight ways instead of
    # six: 33792 tokens per slot against the shared 270336-token ceiling.
    # Throughput per session drops (see above), but eight slots suit a wider
    # fan-out of short requests.
    {
      kind = "basalt";
      name = "qwen3.8-flash-next-iq3s-basalt-c8";
      upstreamModel = "qwen3.8-flash-next-iq3s";
      pack = "Qwen3.8-FN-GSQ-RCO-IQ3_S.basalt";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 33792;
      parallel = 8;
      vramReserveMib = 1800;
      description = "Qwen3.8-Flash-Next GSQ-RCO IQ3_S served by Basalt (33792 ctx x8 slots, text-only).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    # Inkling 2 Mini (24 physical layers, 48 visits a token, 128 experts
    # top-8). The 19.7 GB pack puts about 16.3 GiB of weights and the DSpark
    # drafter on the card, with the token embedding in page-locked RAM. At
    # 262144 tokens the fp8 KV cache is about 4.5 GiB, and with the vision
    # path's buffers the service consumes around 24 GiB. `--vision dynamic`
    # uses the engine's own encoder for images. One slot: upstream has not
    # measured `--parallel` for this model.
    {
      kind = "basalt";
      name = "inkling-2-mini-q8-basalt-c1";
      upstreamModel = "inkling-2-mini";
      pack = "Inkling-2-Mini-NVFP4-q8.basalt";
      vramGb = 24;
      perGpuMib = 24500;
      maxContext = 262144;
      parallel = 1;
      kv = "fp8";
      vision = "dynamic";
      vramReserveMib = 1800;
      description = "Inkling 2 Mini (NVFP4 q8) served by Basalt (262144 ctx, vision).";
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
          image = (m.image or images.ninfer).tag;
          # Podman is the default; a model can still opt into another runtime
          # when an external compatibility workflow requires it.
          runtime = m.runtime or "podman";
          # Replaces the image's CMD, so the executable leads.
          # `--kv-capacity` defaults to `maxContext` (the per-session ceiling)
          # so the static reservation stays honest, but a model may raise it to
          # share a larger pool across concurrent lanes — ninfer's KV cache is a
          # single paged pool sized by `--kv-capacity`, independent of
          # `--max-concurrency` (which only sets the lane count).
          command = (m.image or images.ninfer).serveCommand or [ "ninfer-serve" ]
            ++ [ "${artifactsIn}/${m.artifact}" ] ++ flagArgs ({
            "--host" = "\${listen_host}";
            "--port" = "\${listen_port}";
            "--max-context" = m.maxContext;
            "--kv-capacity" = m.kvCapacity or m.maxContext;
            "--kv-dtype" = m.kvDtype or "int8";
            "--max-concurrency" = m.maxConcurrency or 1;
            "--vision" = m.vision or false;
            "--model-id" = m.modelId or null;
          } // lib.optionalAttrs (m ? spec) {
            "--spec" = m.spec;
          } // lib.optionalAttrs ((m.spec or "none") != "none") {
            "--draft-tokens" = m.draftTokens;
            "--lm-head-draft" = true;
          } // (m.extraFlags or { }));
          network = "host";
          mounts = [ (roMount "${home}/ai/ninfer" artifactsIn) ];
        };
        # `basalt serve` takes the server's options and passes every other
        # flag through to the engine.
        basalt = port: m: anankeLib.mkContainerCommandService {
          inherit (m) name vramGb perGpuMib description upstreamModel;
          inherit port;
          image = images.basalt.tag;
          command = [ "serve" ] ++ flagArgs {
            "--model" = "${basaltIn}/${m.pack}";
            "--alias" = m.upstreamModel;
            "--host" = "\${listen_host}";
            "--port" = "\${listen_port}";
            "--parallel" = m.parallel;
            "--max-context" = m.maxContext * m.parallel;
            "--kv" = m.kv or "int8";
            "--vision" = m.vision or false;
            "--vram-reserve-mib" = m.vramReserveMib;
          };
          network = "host";
          mounts = [ (roMount "${home}/ai/basalt" basaltIn) ];
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
