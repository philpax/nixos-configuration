{ config, pkgs, ... }:

let
  folders = import ../folders.nix;
  lib = pkgs.lib;

  llmDir = folders.ai.llm;
  vllmDir = folders.ai.vllm;
  anankeDir = folders.ai.ananke;

  # Public ports.
  openaiPort = 7070;
  managementPort = 7071;
  comfyuiPort = 8188;
  llmBasePort = 8200;

  # ComfyUI docker container always listens on 8188; ananke proxies the
  # public port to a loopback port the start script binds for it.
  comfyuiContainerPort = 8188;
  comfyuiShared = import ../../common-all/comfyui.nix {
    inherit pkgs;
    comfyuiDir = folders.ai.comfyui;
    port = comfyuiContainerPort;
  };

  # Model list. Order determines port: llmBasePort + index. Only fields
  # the model actually needs are set; mkService folds them into a
  # well-formed ananke [[service]] block.
  #
  # Each entry has an optional `kind` discriminator that picks the right
  # mkXService builder. `kind` is missing or "llama-cpp" for the local
  # llama.cpp serving path; `kind = "vllm"` defers to mkVllmService and
  # generates a `template = "command"` service that fronts a vLLM
  # container via the OpenAI proxy.
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

  # Only one service carries `metadata.resident = true` today (Qwen
  # 3.6); it's inlined at the use-site rather than pulled from a helper
  # because Nix's `//` operator shallow-merges — combining two
  # `{ metadata.foo = ...; }` attrsets would drop one of the metadata
  # keys. If a second flag ever needs stacking on top of
  # `discordVisible`, write the full metadata table inline too.

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
      extras = qwen36Extras // {
        context = 524288;
        metadata = {
          discord_visible = true;
          resident = true;
        };
      };
    }
    {
      name = "qwen3.6-27b";
      file = "unsloth/Qwen3.6-27B-GGUF/Qwen3.6-27B-UD-Q5_K_XL.gguf";
      mmproj = "unsloth/Qwen3.6-27B-GGUF/mmproj-F16.gguf";
      extras = qwen36Extras // { context = 2*180*1000; } // discordVisible;
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
        extra_args = [ "-n" "16384" "--cache-ram" "0" ];
        sampling = {
          temperature = 1.0;
          top_k = 64;
          top_p = 0.95;
          min_p = 0.05;
          repeat_penalty = 1.0;
        };
      } // discordVisible;
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
    # unsloth/GLM-5.2-GGUF/bench/TRIALS.md. ananke computes the
    # --gpu-fit-margin companions for `fit` from the same calibration.
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
          fit = true;
          attn_max_batch = 512;
        };
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
          "--parallel-tool-calls"
          "--chat-template-kwargs"
          (builtins.toJSON { reasoning_effort = "high"; })
        ];
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

    # vLLM-served models. `kind = "vllm"` routes through mkVllmService,
    # which emits a `template = "command"` service that wraps the
    # corresponding shell script and registers an `openai_proxy` block
    # so the model shows up in /v1/models alongside the llama.cpp ones.
    # The exposed (`-vllm` suffixed) name is what clients address; the
    # script's `--served-model-name` is the upstream rewrite target.
    {
      kind = "vllm";
      name = "qwen3.6-27b-vllm";
      script = "${vllmDir}/qwen36_27b.sh";
      upstream_model = "qwen3.6-27b-autoround";
      vram_gb = 44;
      per_gpu_mib = 22000;
      description = "Qwen 3.6 27B served by vLLM (TP=2, AutoRound int4).";
    }
    {
      kind = "vllm";
      name = "gemma-4-26b-a4b-it-vllm";
      script = "${vllmDir}/gemma4_26b.sh";
      upstream_model = "cyankiwi/gemma-4-26B-A4B-it-AWQ-4bit";
      vram_gb = 46;
      per_gpu_mib = 23000;
      description = "Gemma 4 26B (A4B) served by vLLM (TP=2, AWQ 4-bit).";
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
    {
      kind = "vllm";
      name = "gemma-4-31b-it-mtp-vllm";
      script = "${vllmDir}/gemma4_31b_mtp.sh";
      upstream_model = "gemma-4-31b-autoround";
      vram_gb = 45;
      per_gpu_mib = 22500;
      description = "Gemma 4 31B served by vLLM (TP=2, AutoRound int4, MTP drafter n=4, BF16 KV).";
    }
    {
      kind = "vllm";
      name = "gemma-4-31b-it-int8-vllm";
      script = "${vllmDir}/gemma4_31b_int8.sh";
      upstream_model = "gemma-4-31b-autoround";
      vram_gb = 45;
      per_gpu_mib = 22500;
      description = "Gemma 4 31B served by vLLM (TP=2, AutoRound int4, MTP drafter n=4, INT8 PTH KV — long-context variant).";
    }
    # Embedding service. Pinned to GPU 1 alone (gpu_indices = [ 1 ]);
    # the script's --device nvidia.com/gpu=1 enforces the same on the
    # container side, so ananke's pledge and the container's reality
    # agree. modality = "embedding" is a first-class field in ananke's
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
      script = "${vllmDir}/jina_embed_v5_small.sh";
      upstream_model = "jina-embeddings-v5-text-small-retrieval";
      vram_gb = 4;
      per_gpu_mib = 4000;
      gpu_indices = [ 1 ];
      modality = "embedding";
      extra_env = {
        MAX_MODEL_LEN = "16384";
        GPU_MEMORY_UTILIZATION = "0.16";
      };
      description = "Jina v5 text-small (retrieval merged adapter) served by vLLM (pooling runner, 1024-dim, 16K ctx — sized to co-run with qwen 200K). GPU 1 only.";
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

  mkLlmService = index: m:
    let
      base = {
        template = "llama-cpp";
        name = m.name;
        port = llmBasePort + index;
        model = "${llmDir}/${m.file}";
        jinja = true;
      };
      mmprojAttrs = lib.optionalAttrs (m ? mmproj) {
        mmproj = "${llmDir}/${m.mmproj}";
      };
    in base // mmprojAttrs // (m.extras or { });

  # vLLM scripts run docker in the foreground, accept the host port as
  # their first arg (`{port}` → `-p $PORT:8000`), and shut down via a
  # SIGTERM trap that calls `docker stop`. ananke supervises the
  # foreground shell; that's enough for the lifecycle. Static allocation
  # pinned per-GPU because the containers run without `--cgroup-parent`,
  # so the snapshotter can't observe them — the pledge is the source
  # of truth for VRAM accounting.
  #
  # `env.PATH` is required because ananke's spawner calls env_clear()
  # before exec for reproducibility, and these are user-authored shell
  # scripts that use bare `mkdir`/`docker` (unlike comfyui, which is a
  # Nix-built wrapper with baked-in paths). HOME points docker at the
  # ai user's `~/.docker` so credential helpers work. A service can add
  # to this via `extra_env` (merged in mkVllmService) to feed its script
  # tunables like MAX_MODEL_LEN / GPU_MEMORY_UTILIZATION / CONTAINER_SUFFIX.
  vllmEnv = {
    PATH = lib.makeBinPath [ pkgs.docker pkgs.coreutils pkgs.bash ];
    HOME = "/home/ai";
  };
  mkVllmService = index: m:
    let
      # gpu_indices defaults to [ 0 1 ] for the dual-card services that
      # made up the entire vLLM section before the embedding entry
      # landed. Single-card services (the embedding model on GPU 1)
      # pass `gpu_indices = [ 1 ]` to skip the gpu:0 pledge.
      gpuIndices = m.gpu_indices or [ 0 1 ];
      mkPlacementEntry = idx: lib.nameValuePair "gpu:${toString idx}" m.per_gpu_mib;
      placementOverride = lib.listToAttrs (map mkPlacementEntry gpuIndices);
      # Optional typed modality field. Folded in via lib.optionalAttrs
      # so chat services emit no `modality` key at all (ananke defaults
      # to chat, and the validator parses missing/`"chat"` identically),
      # keeping the generated TOML identical to what shipped before the
      # embedding service landed.
      modalityAttrs = lib.optionalAttrs (m ? modality) { modality = m.modality; };
      base = {
        template = "command";
        name = m.name;
        port = llmBasePort + index;
        description = m.description;
        command = [ m.script "{port}" ];
        # Explicit container teardown. The script's own EXIT/TERM trap can
        # race ananke's SIGTERM→SIGKILL window (10s) — `docker stop` itself
        # waits up to 10s for the container, and if the shell is killed
        # mid-stop the orphaned `docker stop` client may not complete the
        # request, leaving the container (and its VRAM) alive. Running
        # `--stop` after the main child exits gets the explicit teardown
        # under ananke's 30s shutdown-command grace.
        shutdown_command = [ m.script "--stop" ];
        env = vllmEnv // (m.extra_env or { });
        idle_timeout = "60m";
        # vLLM cold-start is multi-minute (see `health.timeout` below), so
        # losing one to an eviction contest with a default-priority llama.cpp
        # model is expensive — the next vLLM request pays the full warm-up
        # tax again. Bumping above the default 50 keeps the llama.cpp herd
        # from displacing a resident vLLM service. Anything that genuinely
        # should preempt vLLM (a hand-tagged high-priority model) can still
        # set a higher value.
        priority = 70;
        allocation = {
          mode = "static";
          vram_gb = m.vram_gb;
        };
        devices = {
          placement = "gpu-only";
          placement_override = placementOverride;
        };
        # vLLM cold start is in the multi-minute range: docker image
        # bring-up, NCCL init, two weight loads (target + drafter), and
        # torch.compile graph load. Default 3-minute timeout is tight; bump
        # to 10 to leave headroom for cache misses (fresh torch.compile
        # cache, evicted page cache, …).
        health = {
          http = "/health";
          timeout = "10m";
        };
        openai_proxy = {
          upstream_model = m.upstream_model;
        };
      };
    in base // modalityAttrs;

  mkService = index: m:
    if (m.kind or "llama-cpp") == "vllm"
    then mkVllmService index m
    else mkLlmService index m;

  llmServices = lib.imap0 mkService models;

  # ComfyUI is an external command; ananke starts/stops the host-side
  # docker wrapper. `{port}` resolves to the private loopback port ananke
  # allocates, which the start script passes through to `docker run -p`
  # to map onto the container's fixed 8188. Dynamic VRAM so other models
  # can share the pool while ComfyUI is loaded but idle.
  comfyuiService = {
    template = "command";
    name = "comfyui";
    port = comfyuiPort;
    command = [
      "${comfyuiShared.comfyuiStartScript}/bin/comfyui-start"
      "--foreground"
      "--port"
      "{port}"
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
    # ComfyUI runs inside Docker, so its container is reparented out of
    # ananke's process tree. Without this hint the snapshotter can't see
    # the workload's VRAM and the dynamic pledge stays frozen at
    # `min_vram_gb`. The wrapper script passes `--cgroup-parent
    # ananke-comfyui.slice` to `docker run`; systemd treats `-` as a
    # path separator in slice names, so `ananke-comfyui.slice` lives at
    # `/ananke.slice/ananke-comfyui.slice/` (NOT under `/system.slice/`).
    # ananke matches by prefix on the v2 cgroup path.
    tracking = {
      cgroup_parent = "/ananke.slice/ananke-comfyui.slice";
    };
    health = {
      http = "/system_stats";
    };
  };

  ananke_config = {
    daemon = {
      management_listen = "0.0.0.0:${toString managementPort}";
      allow_external_management = true;
      # Bind per-service reverse proxies on 0.0.0.0 too — we open the
      # LLM port range in the firewall, so clients can reach an
      # individual model via `<host>:<port>` without routing through
      # the OpenAI multiplexer on 7070.
      allow_external_services = true;
      data_dir = "${anankeDir}/data";
    };
    openai_api = {
      listen = "0.0.0.0:${toString openaiPort}";
    };
    service = llmServices ++ [ comfyuiService ];
  };

  tomlFormat = pkgs.formats.toml { };
  configFile = tomlFormat.generate "ananke-config.toml" ananke_config;

  firewallPorts =
    [ openaiPort managementPort comfyuiPort ]
    ++ (lib.imap0 (i: _: llmBasePort + i) models);
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

  systemd.services.ananke = {
    description = "Ananke";
    after = [ "docker.service" "network.target" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.ai.llamaCppCuda pkgs.docker pkgs.curl pkgs.bash ];

    environment = {
      # nvml-wrapper dlopen()s libnvidia-ml from the driver lib dir; without
      # this the daemon logs "NVML init failed" and falls back to CPU-only.
      LD_LIBRARY_PATH = "/run/opengl-driver/lib";
    };

    serviceConfig = {
      User = "ai";
      Group = "ai";
      WorkingDirectory = anankeDir;
      ExecStart = "${anankeDir}/target/debug/ananke --config ${configFile}";
      Restart = "always";
      RestartSec = "10s";
    };
  };

  networking.firewall.allowedTCPPorts = firewallPorts;

  environment.systemPackages = [
    comfyuiShared.comfyuiRebuildScript
    comfyuiShared.comfyuiStartScript
    comfyuiShared.comfyuiStopScript
  ];
  };
}
