{ config, pkgs, ... }:

let
  folders = import ../folders.nix;
  lib = pkgs.lib;
  anankeLib = import ../../common-all/ananke-lib.nix { inherit lib; };
  inherit (anankeLib) flagArgs;
  inherit (import ../../common-all/container-images.nix { inherit pkgs lib; })
    mkOverlayImage mkImageService;

  llmDir = folders.ai.llm;
  vllmDir = folders.ai.vllm;
  anankeDir = folders.ai.ananke;

  openaiPort = anankeLib.ports.openai;
  managementPort = anankeLib.ports.management;
  comfyuiPort = 8188;
  llmBasePort = 8200;

  # Overlay source for every patched vLLM image. Pinned to club-3090's
  # 2026-05-31 v0.22.0 cut, which is the commit each overlay was rebased
  # against; bumping it means re-checking that all of them still apply.
  club3090 = pkgs.fetchFromGitHub {
    owner = "noonghunna";
    repo = "club-3090";
    rev = "b2d7d8fb7f1d04584ef5ff5376723478d6851f9a";
    hash = "sha256-FD7to76mRZBWgNbmHjZsaiZI8zTnWNDJ8a7XsKmsyuk=";
  };
  club3090Patch = model: patch: "${club3090}/models/${model}/vllm/patches/${patch}";

  # Every vLLM overlay is a patch directory whose install.sh detects an
  # already-patched image and no-ops, and fails loud on a rejected hunk. A
  # patch that stops applying breaks the build rather than yielding a
  # quietly unpatched image.
  installPatch = src: dest: { inherit src dest; install = true; };

  # Gemma 4 MTP streaming multi-tool-call fix (vLLM PR #42006). Stock
  # v0.22.0 drops the arguments of every tool call but the last when
  # streaming. Both 31B duals carry it.
  gemma4Pr42006 = installPatch
    (club3090Patch "gemma-4-31b" "vllm-pr42006-v0.22.0")
    "/etc/club3090/pr42006";

  vllmImages = {
    # No overlays; the AWQ build runs on stock v0.20.0.
    gemma4_26b = mkOverlayImage {
      name = "vllm_gemma4_26b";
      base = "vllm/vllm-openai:v0.20.0";
    };

    # Adds the froggeric chat template (fixes seven default-template bugs)
    # and PR #37750, which gives every torch.cuda.Event an explicit
    # `device=`. Without the latter, TP=2 deterministically kills rank 1
    # mid-decode on this rig — upstream vllm-project/vllm#41190.
    qwen36_27b = mkOverlayImage {
      name = "vllm_qwen36_27b";
      base = "vllm/vllm-openai:v0.22.0";
      overlays = [
        {
          src = "${club3090Patch "qwen3.6-27b" "froggeric-chat-template"}/chat_template.jinja";
          dest = "/etc/qwen-froggeric-chat-template.jinja";
        }
        (installPatch ./vllm-patches/vllm-pr37750-v0.22.0 "/etc/club3090/pr37750")
      ];
    };

    # BF16 KV: ~131K default context, ~196K pool ceiling.
    gemma4_31b_mtp = mkOverlayImage {
      name = "vllm_gemma4_31b_mtp";
      base = "vllm/vllm-openai:v0.22.0";
      overlays = [ gemma4Pr42006 ];
    };

    # INT8 per-token-head KV via PR #40391, which pads Gemma 4's global-layer
    # KV spec so page sizes unify across its two head_dims. Roughly twice the
    # BF16 pool, so 262K native context fits.
    gemma4_31b_int8 = mkOverlayImage {
      name = "vllm_gemma4_31b_int8";
      base = "vllm/vllm-openai:v0.22.0";
      overlays = [
        (installPatch
          (club3090Patch "gemma-4-31b" "vllm-pr40391-v0.22.0")
          "/etc/club3090/pr40391")
        gemma4Pr42006
      ];
    };

    # v0.22.0 serves this natively via `--runner pooling`; no overlays.
    jina_embed_v5_small = mkOverlayImage {
      name = "vllm_jina_embed_v5_small";
      base = "vllm/vllm-openai:v0.22.0";
    };
  };

  # vLLM writes model downloads and compile caches back to these, so they
  # are read-write. tmpfiles creates them: ananke does not create mount
  # sources, and Docker makes a missing one root-owned.
  hfCache = "${vllmDir}/huggingface";
  vllmCache = name: "${vllmDir}/cache/${name}";
  vllmMounts = name: [
    { source = hfCache; target = "/root/.cache/huggingface"; }
    {
      source = "${vllmCache name}/torch_compile";
      target = "/root/.cache/vllm/torch_compile_cache";
    }
    { source = "${vllmCache name}/triton"; target = "/root/.triton/cache"; }
  ];

  # Shared by every vLLM service bar the 26B, which ran without any of it.
  # `--ipc=host` is set on the container, so they use the host's /dev/shm
  # and need no shm sizing of their own.
  vllmBaseEnv = {
    VLLM_WORKER_MULTIPROC_METHOD = "spawn";
    VLLM_NO_USAGE_STATS = "1";
    OMP_NUM_THREADS = "1";
  };

  # Google's recommended sampling for Gemma 4, and Qwen's for Qwen 3.6.
  # Baked in so clients that send no sampling params still get sane values.
  gemma4Sampling = builtins.toJSON {
    temperature = 1.0;
    top_p = 0.95;
    top_k = 64;
    min_p = 0.0;
    repetition_penalty = 1.0;
  };
  qwen36Sampling = builtins.toJSON {
    temperature = 0.6;
    top_p = 0.95;
    top_k = 20;
    min_p = 0.0;
    repetition_penalty = 1.0;
  };

  # Shared by both Gemma 4 31B duals: same weights, same drafter, same
  # parsers. They differ only in KV dtype and the context that buys.
  gemma4_31bArgs = flagArgs {
    "--model" = "Intel/gemma-4-31B-it-int4-AutoRound";
    "--served-model-name" = "gemma-4-31b-autoround";
    "--tensor-parallel-size" = 2;
    # PCIe-only rig, so the custom all-reduce path is off.
    "--disable-custom-all-reduce" = true;
    "--gpu-memory-utilization" = "0.95";
    "--max-num-seqs" = 4;
    "--max-num-batched-tokens" = 4096;
    "--trust-remote-code" = true;
    "--enable-auto-tool-choice" = true;
    "--tool-call-parser" = "gemma4";
    # Routes Gemma 4's thought trace into `reasoning_content` rather than
    # letting it leak into `content`. No-ops when thinking is off.
    "--reasoning-parser" = "gemma4";
    "--chat-template" = "/vllm-workspace/examples/tool_chat_template_gemma4.jinja";
    "--speculative-config" = builtins.toJSON {
      model = "google/gemma-4-31B-it-assistant";
      num_speculative_tokens = 4;
    };
    "--override-generation-config" = gemma4Sampling;
  };

  gemma4_31bEnv = vllmBaseEnv // {
    TRITON_CACHE_DIR = "/root/.triton/cache";
    NCCL_CUMEM_ENABLE = "0";
    NCCL_P2P_DISABLE = "1";
    PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True,max_split_size_mb:512";
    VLLM_ALLOW_LONG_MAX_MODEL_LEN = "1";
  };

  # Every vLLM container binds this inside its own network namespace;
  # ananke publishes the loopback port it allocated onto it.
  vllmContainerPort = 8000;

  # ComfyUI docker container always listens on 8188; ananke proxies the
  # public port to a loopback port the start script binds for it.
  comfyuiContainerPort = 8188;
  comfyuiShared = import ../../common-all/comfyui.nix {
    inherit pkgs;
    comfyuiDir = folders.ai.comfyui;
    port = comfyuiContainerPort;
  };

  # Order determines port (llmBasePort + index). `kind` is missing or
  # "llama-cpp" for local serving; `kind = "vllm"` fronts a vLLM
  # container instead via a `template = "command"` service.
  #
  # `extras` holds ad-hoc ananke service keys (sampling, extra_args,
  # override_tensor, threads, flash_attn, cache_type_*, lifecycle,
  # placement, etc.). Everything in extras is merged into the final
  # service attrset verbatim, so keys must match ananke's config schema.

  # Gemma 4 sampling + chat-template knobs. Applied to every Gemma 4
  # variant; follows Google's recommended defaults.
  gemma4Extras = {
    context = 262144;
    flash_attn = true;
    cache_type_k = "q8_0";
    cache_type_v = "q8_0";
    sampling = {
      temperature = 1.0;
      top_p = 0.95;
      top_k = 64;
    };
    extra_args = [
      "--chat-template-kwargs"
      (builtins.toJSON { enable_thinking = true; })
    ];
  };

  # Qwen 3.6 shared knobs. Both models carry an embedded MTP head, so we
  # enable multi-token-prediction speculative decoding (composes with
  # parallel > 1 and mmproj). parallel = 2 splits the context budget
  # across slots. Context left unspecified to allow optimising
  # for what each model can handle within the VRAM.
  qwen36Extras = {
    flash_attn = true;
    cache_type_k = "q8_0";
    cache_type_v = "q8_0";
    parallel = 2;
    spec_type = "draft-mtp";
    spec_draft_n_max = 2;
    devices = { split = "tensor"; };
    sampling = {
      temperature = 0.6;
      top_p = 0.95;
      top_k = 20;
      min_p = 0.0;
      repeat_penalty = 1.0;
    };
    extra_args = [
      "--chat-template-kwargs"
      (builtins.toJSON { enable_thinking = true; preserve_thinking = true; })
    ];
  };

  # Models listed under /askchorus in paxcord's commands.lua. Ananke
  # stores this under `metadata.discord_visible` per-service; paxcord's
  # Lua runtime filters `llm.models` by the flag when building the
  # askchorus rotation.
  discordVisible = { metadata.discord_visible = true; };

  # Only one service carries `metadata.resident = true` (the default
  # model — see defaultModel below), with its metadata written inline.

  models = [
    # Qwen family.
    {
      name = "qwen3-4b-instruct";
      file = "unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-UD-Q5_K_XL.gguf";
      extras = { context = 8192; } // discordVisible;
    }
    {
      name = "qwen3.6-35b-a3b";
      file = "unsloth/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf";
      mmproj = "unsloth/Qwen3.6-35B-A3B-GGUF/mmproj-F16.gguf";
      # Double the context so both parallel slots keep the full 262144;
      # the A3B's lighter KV leaves room for this where the 27B can't.
      extras = qwen36Extras // { context = 524288; } // discordVisible;
    }
    {
      name = "qwen3.6-27b";
      file = "unsloth/Qwen3.6-27B-GGUF/Qwen3.6-27B-UD-Q5_K_XL.gguf";
      mmproj = "unsloth/Qwen3.6-27B-GGUF/mmproj-F16.gguf";
      extras = qwen36Extras // { context = 2*180*1000; } // discordVisible;
      client = {
        class = "medium";
        reasoning = { type = "none"; };
      };
    }

    # Gemma family.
    {
      name = "gemma-3-27b-it-abliterated";
      file = "mlabonne/gemma-3-27b-it-abliterated-GGUF/gemma-3-27b-it-abliterated.q4_k_m.gguf";
      extras = { context = 8192; } // discordVisible;
    }
    {
      name = "gemma-3-glitter-27b";
      file = "mradermacher/Gemma-3-Glitter-27B-i1-GGUF/Gemma-3-Glitter-27B.i1-Q5_K_M.gguf";
      extras = { context = 8192; } // discordVisible;
    }
    {
      name = "gemma-4-31b-it";
      file = "unsloth/gemma-4-31B-it-GGUF/gemma-4-31B-it-UD-Q4_K_XL.gguf";
      mmproj = "unsloth/gemma-4-31B-it-GGUF/mmproj-F16.gguf";
      extras = gemma4Extras // discordVisible;
    }
    # QAT build with a tuned 2×3090 MTP config from the model.
    {
      name = "gemma-4-31b-it-qat";
      file = "unsloth/gemma-4-31B-it-qat-GGUF/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf";
      mmproj = "unsloth/gemma-4-31B-it-qat-GGUF/mmproj-F16.gguf";
      extras = {
        context = 240000;
        flash_attn = true;
        cache_type_k = "f16";
        cache_type_v = "f16";
        parallel = 4;
        kv_unified = true;
        # Stability mitigation for the rare prompt-cache/checkpoint crash
        # race; see RECOMMENDED.md. ananke already supervises + restarts.
        cache_idle_slots = false;
        spec_type = "draft-mtp";
        spec_draft_n_max = 2;
        draft_model = "${llmDir}/unsloth/gemma-4-31B-it-qat-GGUF/mtp-gemma-4-31B-it.gguf";
        devices = { split = "tensor"; };
        # -n: server-side generation cap. With kv_unified the 4 slots share one
        # context-sized pool, and uncapped runaway generations can exhaust it,
        # which llama-server handles by asserting (observed 2026-06-12, see
        # the model dir's bench/TRIALS.md). 16384 is far above any sane reply.
        #
        # --cache-ram 0: disable the host-RAM prompt cache. Measured in prod
        # (2026-06-12): 0.8-2.6 GiB state copies froze the whole server for
        # ~18% of wall time (30s per 3min under 4-way load), while the
        # post-#24411 checkpoint-skip semantics defeat most cross-slot
        # restores anyway. Conversations at our sizes re-prefill faster than
        # the cache round-trips, without blocking other slots. Slot-local KV
        # reuse and SWA checkpoints are unaffected.
        extra_args = [ "-n" "16384" "--cache-ram" "0" "--slot-prompt-similarity" "0.5" ];
        sampling = {
          temperature = 1.0;
          top_k = 64;
          top_p = 0.95;
          min_p = 0.05;
          repeat_penalty = 1.0;
        };
        metadata = {
          discord_visible = true;
          resident = true;
        };
      };
      client = {
        class = "medium";
        reasoning = { type = "none"; };
      };
    }
    {
      name = "gemma-4-26b-a4b-it";
      file = "unsloth/gemma-4-26B-A4B-it-GGUF/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf";
      mmproj = "unsloth/gemma-4-26B-A4B-it-GGUF/mmproj-F16.gguf";
      extras = gemma4Extras // discordVisible;
    }
    {
      name = "gemma-4-e4b-it";
      file = "unsloth/gemma-4-E4B-it-GGUF/gemma-4-E4B-it-UD-Q5_K_XL.gguf";
      mmproj = "unsloth/gemma-4-E4B-it-GGUF/mmproj-F16.gguf";
      extras = gemma4Extras;
    }

    # DeepSeek family.
    # DeepSeek-V4-Flash: a ~671B-class MoE (256 experts, 6 active + 1 shared)
    # in the new `deepseek4` arch — MLA attention, an NSA "lightning indexer"
    # sparse-attention path, and hyper-connections. ~96 GiB at UD-IQ3_XXS, so
    # it runs hybrid (routed experts spill to CPU RAM, ~55 GiB). Tuned on the
    # 2×3090 box; see the model dir's bench/TRIALS.md + RECOMMENDED.md.
    #
    # `expert_offload = "auto"` lets the packer fill VRAM with expert layers
    # from the estimate. This relies on ananke's deepseek4 estimator support
    # (the CSA KV term + the ubatch-scaled NSA compute-buffer curve); without
    # it the packer would badly under-reserve and OOM at load. Generation is
    # ~3 tok/s regardless of expert count (bounded by the arch's still-
    # unoptimised indexer/sinkhorn kernels, not offload), and stays flat at
    # depth; 128k with ub512 keeps prefill fast (~90 tok/s). Sampling follows
    # DeepSeek's spec (temp 1.0, top_p 1.0, min_p 0.0; top_k disabled).
    {
      name = "deepseek-v4-flash";
      file = "unsloth/DeepSeek-V4-Flash-GGUF/UD-IQ3_XXS/DeepSeek-V4-Flash-UD-IQ3_XXS-00001-of-00004.gguf";
      extras = {
        context = 131072;
        threads = 24;
        parallel = 1;
        flash_attn = true;
        jinja = true;
        batch_size = 2048;
        ubatch_size = 512;
        numa = "distribute";
        expert_offload = "auto";
        sampling = {
          temperature = 1.0;
          top_p = 1.0;
          top_k = 0;
          min_p = 0.0;
        };
        devices = { placement = "hybrid"; };
      };
    }

    # GLM family.
    # GLM-5.2: a 744B-A40B MoE (256 experts, 8 active + 1 shared) in the
    # `glm-dsa` arch — MLA attention plus a DSA sparse-attention indexer.
    # Served by ik_llama.cpp (`ai.ikLlamaCppCuda`), which unlocks the DSA
    # path (`-dsa -fidx`, flat generation and 2.2× faster deep prefill vs
    # dense MLA) on the muzzy smol-IQ2_KS quant (205.7 GiB, ~187 GiB of
    # experts in CPU RAM under --no-mmap). Tuned overnight 2026-07-22:
    # ~8 tok/s generation flat to 58k+ depth, ~195/143 tok/s prefill
    # shallow/deep at 128k. Config rationale (incl. why -mla 1 and no
    # MTP) in the model dir's RECOMMENDED.md; trials in
    # unsloth/GLM-5.2-GGUF/bench/TRIALS.md.
    # Sampling follows Unsloth's guide (temp 1.0, top_p 0.95, min_p 0.01).
    {
      name = "glm-5.2";
      file = "muzzy/GLM-5.2-GGUF/IQ2_KS/GLM-5.2-smol-IQ2_KS-00001-of-00033.gguf";
      extras = {
        context = 131072;
        threads = 24;
        parallel = 1;
        jinja = true;
        batch_size = 2048;
        ubatch_size = 2048;
        mmap = false;
        llama_server = "${config.ai.ikLlamaCppCuda}/bin/llama-server";
        runtime = {
          kind = "ik-llama";
          mla = 1;
          dsa = true;
          attn_max_batch = 512;
        };
        expert_offload = "auto";
        sampling = {
          temperature = 1.0;
          top_p = 0.95;
          min_p = 0.01;
        };
        devices = { placement = "hybrid"; };
        # A cold 205 GiB --no-mmap load takes minutes; the default 3m
        # probe timeout killed the child mid-load.
        health = {
          http = "/health";
          timeout = "10m";
        };
        extra_args = [
          "--log-disable"
          "--parallel-tool-calls"
          "--chat-template-kwargs"
          (builtins.toJSON { reasoning_effort = "high"; })
        ];
      };
    }

    # Laguna family.
    # Laguna S 2.1: a 118B-A8B MoE (48 layers, 1 dense + 47 routed, shared
    # expert) in the `laguna` arch — variable per-layer Q head counts, plain
    # GQA KV (8 heads × 128 dim), sliding window 512. Served by ik_llama.cpp
    # (`ai.ikLlamaCppCuda`) on the unsloth UD-IQ4_NL quant (55 GiB, i-quant):
    # ik's CPU kernels make the hybrid expert dequant ~2× faster than
    # mainline at the same ~4-bit quality tier. Tuned overnight
    # 2026-07-22: ~30 tok/s gen at 2K, ~19 tok/s at 128K, ~35 tok/s on
    # coding prompts, ~1127 tok/s prefill at 8K. Config rationale and
    # DFlash findings in the model dir's RECOMMENDED.md; trials in
    # unsloth/Laguna-S-2.1-GGUF/bench/TRIALS.md.
    {
      name = "laguna-s-2.1-iq4-nl";
      file = "unsloth/Laguna-S-2.1-GGUF/UD-IQ4_NL/Laguna-S-2.1-UD-IQ4_NL-00001-of-00003.gguf";
      extras = {
        context = 131072;
        threads = 24;
        parallel = 1;
        jinja = true;
        batch_size = 2048;
        ubatch_size = 2048;
        mmap = false;
        flash_attn = true;
        cache_type_k = "q8_0";
        cache_type_v = "q8_0";
        numa = "distribute";
        llama_server = "${config.ai.ikLlamaCppCuda}/bin/llama-server";
        runtime = {
          kind = "ik-llama";
        };
        expert_offload = "auto";
        devices = { placement = "hybrid"; };
        extra_args = [ "--log-disable" ];
      };
    }

    # Mistral family.
    {
      name = "magidonia-24b-v4.3";
      file = "bartowski/TheDrummer_Magidonia-24B-v4.3-GGUF/TheDrummer_Magidonia-24B-v4.3-Q5_K_M.gguf";
      extras = { context = 8192; };
    }

    # Talkie family. Dense 13B (talkie arch) with full MHA — the estimator
    # treats it as llama-family. Native context tops out at 2048.
    {
      name = "talkie-1930-13b-it";
      file = "mradermacher/talkie-1930-13b-it-hf-GGUF/talkie-1930-13b-it-hf.Q6_K.gguf";
      extras = { context = 2048; } // discordVisible;
    }

    # vLLM-served models. `kind = "vllm"` emits a `template = "command"`
    # service whose workload is a container ananke drives itself, plus an
    # `openai_proxy` block so the model shows up in /v1/models alongside
    # the llama.cpp ones. The exposed (`-vllm` suffixed) name is what
    # clients address; `--served-model-name` is the upstream rewrite
    # target.
    #
    # `image` comes from `vllmImages` above, tagged with the hash of its
    # own definition, so a service can only ever reference an image built
    # from the config that describes it.
    {
      kind = "vllm";
      name = "qwen3.6-27b-vllm";
      image = vllmImages.qwen36_27b;
      cacheName = "qwen36_27b";
      upstream_model = "qwen3.6-27b-autoround";
      vram_gb = 44;
      per_gpu_mib = 22000;
      description = "Qwen 3.6 27B served by vLLM (TP=2, AutoRound int4).";
      env = vllmBaseEnv // {
        NCCL_CUMEM_ENABLE = "1";
        NCCL_P2P_DISABLE = "1";
        VLLM_USE_FLASHINFER_SAMPLER = "1";
        PYTORCH_CUDA_ALLOC_CONF = "max_split_size_mb:512";
      };
      args = flagArgs {
        "--model" = "Lorbus/Qwen3.6-27B-int4-AutoRound";
        "--served-model-name" = "qwen3.6-27b-autoround";
        "--quantization" = "auto_round";
        "--dtype" = "float16";
        "--tensor-parallel-size" = 2;
        "--disable-custom-all-reduce" = true;
        "--max-model-len" = 262144;
        "--gpu-memory-utilization" = "0.92";
        "--max-num-seqs" = 2;
        "--max-num-batched-tokens" = 8192;
        "--kv-cache-dtype" = "fp8_e5m2";
        "--trust-remote-code" = true;
        "--chat-template" = "/etc/qwen-froggeric-chat-template.jinja";
        "--default-chat-template-kwargs" = builtins.toJSON { enable_thinking = false; };
        "--reasoning-parser" = "qwen3";
        "--enable-auto-tool-choice" = true;
        "--tool-call-parser" = "qwen3_coder";
        "--enable-prefix-caching" = true;
        "--enable-chunked-prefill" = true;
        "--safetensors-load-strategy" = "lazy";
        "--speculative-config" = builtins.toJSON {
          method = "mtp";
          num_speculative_tokens = 3;
        };
        "--override-generation-config" = qwen36Sampling;
      };
    }
    {
      kind = "vllm";
      name = "gemma-4-26b-a4b-it-vllm";
      image = vllmImages.gemma4_26b;
      cacheName = "gemma4_26b";
      upstream_model = "cyankiwi/gemma-4-26B-A4B-it-AWQ-4bit";
      vram_gb = 46;
      per_gpu_mib = 23000;
      description = "Gemma 4 26B (A4B) served by vLLM (TP=2, AWQ 4-bit).";
      # Ran with no environment of its own, and Triton's default cache dir
      # is already the mounted /root/.triton/cache.
      env = { };
      # This one takes the model positionally rather than through `--model`.
      args = [ "cyankiwi/gemma-4-26B-A4B-it-AWQ-4bit" ] ++ flagArgs {
        "--tensor-parallel-size" = 2;
        "--max-model-len" = 32768;
        "--limit-mm-per-prompt" = builtins.toJSON { image = 0; audio = 0; };
        "--enable-prefix-caching" = true;
        "--max-num-batched-tokens" = 4096;
        "--gpu-memory-utilization" = "0.9";
        "--max-num-seqs" = 128;
        "--safetensors-load-strategy" = "lazy";
        "--default-chat-template-kwargs" = builtins.toJSON { enable_thinking = false; };
      };
    }
    # Gemma 4 31B has two vLLM variants (after club-3090's 2026-05-31
    # v0.22.0 cut at commit b2d7d8f) — both AutoRound INT4 weights +
    # MTP n=4 on stable v0.22.0; pick by context budget. Both carry
    # PR #42006 (Gemma 4 streaming multi-tool-call fix) as a shared
    # build-time overlay:
    #   mtp:  BF16 KV, 131K default ctx (BF16 pool ~196K tok ceiling).
    #         Stable long-ctx path; the int8 sibling is the fuller-ctx
    #         option.
    #   int8: INT8 per-token-head KV via vendored PR #40391 (lean
    #         ~240-line diff-apply, not 7-file copy), 262K native
    #         default (INT8 PTH pool ~354K-455K tok). Long-ctx path.
    #
    # BF16 KV is pinned on the `mtp` variant because the alternatives don't
    # work here: fp8_e5m2 fails an allowlist assert in gemma4_mm.py, fp8_e4m3
    # needs a Triton kernel that wants sm_89+ (these are Ampere sm_86), and
    # int8_per_token_head is exactly what the `int8` sibling's PR #40391
    # overlay exists to enable.
    {
      kind = "vllm";
      name = "gemma-4-31b-it-mtp-vllm";
      image = vllmImages.gemma4_31b_mtp;
      cacheName = "gemma4_31b_mtp";
      upstream_model = "gemma-4-31b-autoround";
      vram_gb = 45;
      per_gpu_mib = 22500;
      description = "Gemma 4 31B served by vLLM (TP=2, AutoRound int4, MTP drafter n=4, BF16 KV).";
      env = gemma4_31bEnv;
      # 131K leaves ~65K of pool headroom against the ~196K BF16 ceiling.
      args = gemma4_31bArgs ++ [ "--max-model-len" "131072" ];
    }
    {
      kind = "vllm";
      name = "gemma-4-31b-it-int8-vllm";
      image = vllmImages.gemma4_31b_int8;
      cacheName = "gemma4_31b_int8";
      upstream_model = "gemma-4-31b-autoround";
      vram_gb = 45;
      per_gpu_mib = 22500;
      description = "Gemma 4 31B served by vLLM (TP=2, AutoRound int4, MTP drafter n=4, INT8 PTH KV — long-context variant).";
      env = gemma4_31bEnv;
      # The INT8 PTH pool is roughly twice the BF16 one, so the model's
      # native 262144 fits with room for short-request concurrency.
      args = gemma4_31bArgs ++ flagArgs {
        "--max-model-len" = 262144;
        "--kv-cache-dtype" = "int8_per_token_head";
      };
    }
    # Embedding service. Pinned to GPU 1 alone (gpu_indices = [ 1 ]);
    # ananke injects `--device nvidia.com/gpu=1` from that same list, so
    # its pledge and the container's reality cannot disagree.
    # modality = "embedding" is a first-class field in ananke's
    # config (parsed into ananke_api::Modality, propagated through
    # /v1/models + /api/services, rendered as a badge in the
    # ServicesTable + ServiceDetail).
    #
    # The model itself is tiny (~1.3 GiB bf16, Qwen3-0.6B backbone); the
    # footprint is almost all KV pool (~110 KiB/token). Capping inputs at
    # 16384 needs ~1.7 GiB KV → util 0.16 (~3.9 GiB total) per the script's
    # two-point calibration, vs the 32K/util-0.25 (~7 GiB) default.
    #
    # That cap dates from co-tenanting GPU 1 with the 200K-context
    # qwen3.6-27b-lowvram-vllm variant, which was pruned in #22. The
    # surviving qwen3.6-27b-vllm pledges 22000 MiB/GPU, so it and the
    # embedder no longer fit on GPU 1 together — ananke evicts one for the
    # other rather than co-scheduling them. The 16384/0.16 sizing is
    # therefore conservative rather than required; raising it toward the
    # 32K/util-0.25 default is now free, at the cost of giving up any
    # future co-tenancy path.
    {
      kind = "vllm";
      name = "jina-embeddings-v5-text-small-retrieval-vllm";
      image = vllmImages.jina_embed_v5_small;
      cacheName = "jina_embed_v5_small";
      upstream_model = "jina-embeddings-v5-text-small-retrieval";
      vram_gb = 4;
      per_gpu_mib = 4000;
      gpu_indices = [ 1 ];
      modality = "embedding";
      description = "Jina v5 text-small (retrieval merged adapter) served by vLLM (pooling runner, 1024-dim, 16K ctx — sized to co-run with qwen 200K). GPU 1 only.";
      env = vllmBaseEnv // {
        TRITON_CACHE_DIR = "/root/.triton/cache";
        PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True,max_split_size_mb:512";
      };
      # `--runner pooling` loads the model in embedding mode; without it
      # vLLM tries the Qwen3-0.6B backbone as a generation model.
      args = flagArgs {
        "--model" = "jinaai/jina-embeddings-v5-text-small-retrieval";
        "--served-model-name" = "jina-embeddings-v5-text-small-retrieval";
        "--runner" = "pooling";
        "--dtype" = "bfloat16";
        "--max-model-len" = 16384;
        "--gpu-memory-utilization" = "0.16";
        "--trust-remote-code" = true;
      };
    }

    # LFM2.5 embedder (llama.cpp-served, 1024-dim). The model's trained
    # max_seq_length is 512 tokens — longer inputs are rejected by the
    # server's physical batch limit, which is the correct behaviour (route
    # long documents to the jina embedder instead). Context is 4 slots ×
    # 512 so concurrent indexing requests don't queue. ~0.7 GiB on one card.
    {
      name = "lfm2.5-embedding-350m";
      file = "LiquidAI/LFM2.5-Embedding-350M-GGUF/LFM2.5-Embedding-350M-Q8_0.gguf";
      extras = {
        context = 2048;
        modality = "embedding";
      };
    }
  ];

  # Bind per-service reverse proxies on 0.0.0.0 too, so clients can reach
  # a model directly via `<host>:<port>` instead of just the multiplexer.
  inherit (anankeLib.mkAnankeConfig {
    inherit pkgs openaiPort managementPort anankeDir;
    allowExternalServices = true;
    services = anankeLib.mkIndexedServices {
      basePort = llmBasePort;
      inherit models;
      builders.llama-cpp = port: m: anankeLib.mkLlmService {
        inherit (m) name;
        inherit port;
        model = "${llmDir}/${m.file}";
        mmproj = if m ? mmproj then "${llmDir}/${m.mmproj}" else null;
        extra = { jinja = true; } // (m.extras or { });
      };
      # ananke drives the container itself, so the lifecycle, logs,
      # cleanup, and crash recovery are its rather than a shell script's.
      #
      # Bridge networking with a fixed container port: every vLLM image's
      # entrypoint binds `${listen_host}:${listen_port}`, which resolves to
      # `0.0.0.0:8000` inside, and ananke publishes the allocated loopback
      # port onto it.
      builders.vllm = port: m: anankeLib.mkContainerCommandService {
        inherit (m) name description;
        inherit port;
        image = m.image.tag;
        # The image declares its own ENTRYPOINT, so the argv is flags only.
        command = m.args ++ flagArgs {
          "--host" = "\${listen_host}";
          "--port" = "\${listen_port}";
        };
        network = "bridge";
        containerPort = vllmContainerPort;
        # vLLM's workers communicate through shared memory, which needs the
        # host's /dev/shm rather than the 64 MB default.
        ipc = "host";
        mounts = vllmMounts m.cacheName;
        inherit (m) env;
        upstreamModel = m.upstream_model;
        vramGb = m.vram_gb;
        perGpuMib = m.per_gpu_mib;
        gpuIndices = m.gpu_indices or [ 0 1 ];
        modality = m.modality or null;
      };
    } ++ [
      # `${port}` is the loopback port ananke allocates, passed through
      # to `docker run -p` onto the container's fixed 8188. Dynamic VRAM
      # so other models can share the pool while ComfyUI is idle.
      {
        template = "command";
        name = "comfyui";
        port = comfyuiPort;
        command = [
          "${comfyuiShared.comfyuiStartScript}/bin/comfyui-start"
          "--foreground"
          "--port"
          "\${port}"
        ];
        shutdown_command = [
          "${comfyuiShared.comfyuiStopScript}/bin/comfyui-stop"
        ];
        idle_timeout = "30m";
        allocation = {
          mode = "dynamic";
          min_vram_gb = 2.0;
          max_vram_gb = 20.0;
        };
        # Without this the container's cgroup is invisible to the
        # snapshotter and the dynamic pledge stays frozen at
        # `min_vram_gb`. Matches the `--cgroup-parent` the wrapper
        # script passes to `docker run`.
        tracking = {
          cgroup_parent = "/ananke.slice/ananke-comfyui.slice";
        };
        health = {
          http = "/system_stats";
        };
      }
    ];
  }) configFile;

  firewallPorts =
    [ openaiPort managementPort comfyuiPort ]
    ++ (lib.imap0 (i: _: llmBasePort + i) models);

  # The single resident model is the default LLM for everything else;
  # findSingle enforces exactly-one at eval time (paxcord checks at runtime).
  defaultModel =
    (lib.findSingle (m: m.extras.metadata.resident or false)
      (throw "ananke: no model carries metadata.resident = true")
      (throw "ananke: multiple models carry metadata.resident = true")
      models).name;

  # The subset of `models` exposed to makima/Polytoken clients, projected into
  # the client-facing shape by `anankeLib.mkClientModel` (which derives
  # `context_window` and `supports_vision` from the runtime fields). Consumed
  # by `update-ai.py` via `nix eval`.
  clientModels = builtins.map anankeLib.mkClientModel (builtins.filter (m: m ? client) models);
in
{
  # Expose ananke's port constants as read-only options so other modules
  # (e.g. grafana.nix) can reference them without hardcoding.
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
    comfyuiPort = lib.mkOption {
      type = lib.types.port;
      default = comfyuiPort;
      readOnly = true;
      description = "Port ananke exposes ComfyUI on.";
    };
    llmBasePort = lib.mkOption {
      type = lib.types.port;
      default = llmBasePort;
      readOnly = true;
      description = "Base port for ananke's per-model LLM services (port = base + index).";
    };
    defaultModel = lib.mkOption {
      type = lib.types.str;
      default = defaultModel;
      readOnly = true;
      description = "Name of the model carrying metadata.resident = true — the default LLM for services that don't pick one explicitly.";
    };
    clientModels = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = clientModels;
      description = "Models exposed to makima/Polytoken clients, with context_window and supports_vision derived from the runtime config. Consumed by update-ai.py.";
    };
  };

  config = {
  # Sibling slice that holds the ComfyUI Docker container. The
  # `comfyui-start` wrapper passes `--cgroup-parent ananke-comfyui.slice`
  # so the resulting `docker-<id>.scope` lands inside this slice;
  # ananke's snapshotter watches the subtree to attribute VRAM/RSS to
  # the comfyui service. Declaring the slice here ensures it exists at
  # boot — relying on docker's lazy creation can race the first
  # `comfyui-start` invocation on some cgroup-driver setups.
  systemd.slices."ananke-comfyui" = {
    description = "Cgroup parent for ananke's ComfyUI container";
  };

  # The mount sources every vLLM service shares. ananke does not create
  # them, and Docker makes a missing bind source root-owned, which the
  # container then cannot write its compile caches into.
  systemd.tmpfiles.rules =
    [ "d ${hfCache} 0755 ai ai - -" ]
    ++ lib.concatMap
      (m: [
        "d ${vllmCache m.cacheName} 0755 ai ai - -"
        "d ${vllmCache m.cacheName}/torch_compile 0755 ai ai - -"
        "d ${vllmCache m.cacheName}/triton 0755 ai ai - -"
      ])
      (lib.filter (m: (m.kind or "") == "vllm") models);

  systemd.services.container-images = mkImageService {
    images = lib.attrValues vllmImages;
  };

  systemd.services.ananke = anankeLib.mkAnankeSystemdService {
    inherit anankeDir configFile;
    user = "ai";
    group = "ai";
    after = [ "docker.service" "network.target" ];
    requires = [ "docker.service" ];
    path = [ config.ai.llamaCppCuda pkgs.docker pkgs.curl pkgs.bash ];
    # nvml-wrapper dlopen()s libnvidia-ml from the driver lib dir; without
    # this the daemon logs "NVML init failed" and falls back to CPU-only.
    environment.LD_LIBRARY_PATH = "/run/opengl-driver/lib";
  };

  networking.firewall.allowedTCPPorts = firewallPorts;

  environment.systemPackages = [
    comfyuiShared.comfyuiRebuildScript
    comfyuiShared.comfyuiStartScript
    comfyuiShared.comfyuiStopScript
  ];
  };
}
