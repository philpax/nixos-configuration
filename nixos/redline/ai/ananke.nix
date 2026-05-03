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

  qwen36Extras = {
    context = 262144;
    flash_attn = true;
    cache_type_k = "q8_0";
    cache_type_v = "q8_0";
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
      file = "Qwen3-4B-Instruct-2507-UD-Q5_K_XL.gguf";
      extras = { context = 8192; } // discordVisible;
    }
    {
      name = "qwen3-30b-a3b-instruct-2507";
      file = "Qwen3-30B-A3B-Instruct-2507-UD-Q4_K_XL.gguf";
      extras = { context = 8192; } // discordVisible;
    }
    {
      name = "qwen3-30b-a3b-thinking-2507";
      file = "Qwen3-30B-A3B-Thinking-2507-UD-Q4_K_XL.gguf";
      extras = { context = 8192; };
    }
    {
      name = "qwen3-30b-a3b-coder-2507";
      file = "Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf";
      extras = { context = 8192; };
    }
    {
      name = "qwen3-32b";
      file = "Qwen3-32B-UD-Q4_K_XL.gguf";
      extras = { context = 8192; } // discordVisible;
    }
    {
      name = "qwen3-235b-a22b-instruct";
      file = "Qwen3-235B-A22B-Instruct-2507-UD-Q2_K_XL-00001-of-00002.gguf";
      extras = {
        context = 16384;
        threads = 24;
        override_tensor = [ ".ffn_(up|down)_exps.=CPU" ];
        sampling = {
          temperature = 0.7;
          top_p = 0.8;
          top_k = 20;
          min_p = 0.0;
        };
        extra_args = [ "--prio" "3" ];
        devices = { placement = "hybrid"; };
      };
    }
    {
      name = "qwen3-vl-30b-a3b-instruct";
      file = "Qwen3-VL-30B-A3B-Instruct-UD-Q4_K_XL.gguf";
      mmproj = "Qwen3-VL-30B-A3B-Instruct-UD-Q4_K_XL-mmproj-F16.gguf";
      extras = { context = 8192; };
    }
    {
      name = "qwen3.6-35b-a3b";
      file = "Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf";
      mmproj = "Qwen3.6-35B-A3B-GGUF-mmprog-F16.gguf";
      extras = qwen36Extras // {
        metadata = {
          discord_visible = true;
          resident = true;
        };
      };
    }
    {
      name = "qwen3.6-27b";
      file = "Qwen3.6-27B-UD-Q5_K_XL.gguf";
      mmproj = "Qwen3.6-27B-GGUF-mmproj-F16.gguf";
      extras = qwen36Extras // discordVisible;
    }

    # Gemma family.
    {
      name = "gemma-3-27b-it";
      file = "gemma-3-27b-it-UD-Q4_K_XL.gguf";
      extras = { context = 8192; } // discordVisible;
    }
    {
      name = "gemma-3-27b-it-abliterated";
      file = "gemma-3-27b-it-abliterated.q4_k_m.gguf";
      extras = { context = 8192; } // discordVisible;
    }
    {
      name = "gemma-3-glitter-27b";
      file = "Gemma-3-Glitter-27B.i1-Q5_K_M.gguf";
      extras = { context = 8192; } // discordVisible;
    }
    {
      name = "gemma-3n-e4b-it";
      file = "gemma-3n-E4B-it-UD-Q4_K_XL.gguf";
      extras = { context = 16384; } // discordVisible;
    }
    {
      name = "gemma-4-31b-it";
      file = "gemma-4-31B-it-UD-Q4_K_XL.gguf";
      mmproj = "gemma-4-31B-it-GGUF-mmproj-F16.gguf";
      extras = gemma4Extras // discordVisible;
    }
    {
      name = "gemma-4-26b-a4b-it";
      file = "gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf";
      mmproj = "gemma-4-26B-A4B-it-GGUF-mmproj-F16.gguf";
      extras = gemma4Extras // discordVisible;
    }
    {
      name = "gemma-4-e4b-it";
      file = "gemma-4-E4B-it-UD-Q5_K_XL.gguf";
      mmproj = "gemma-4-E4B-it-GGUF-mmproj-F16.gguf";
      extras = gemma4Extras;
    }

    # GLM family.
    {
      name = "glm-4-32b-0414";
      file = "GLM-4-32B-0414-UD-Q4_K_XL.gguf";
      extras = { context = 8192; } // discordVisible;
    }
    {
      name = "glm-z1-9b-0414";
      file = "GLM-Z1-9B-0414-UD-Q4_K_XL.gguf";
      extras = { context = 8192; };
    }
    {
      name = "glm-4-5-air";
      file = "GLM-4.5-Air-UD-Q3_K_XL-00001-of-00002.gguf";
      extras = {
        context = 16384;
        threads = 24;
        override_tensor = [ "\\.([0-9][0-9])\\.ffn_(up|down)_exps.=CPU" ];
        devices = { placement = "hybrid"; };
      };
    }

    # Llama family.
    {
      name = "llama-3.3-70b-instruct-abliterated";
      file = "Llama-3.3-70B-Instruct-abliterated-IQ2_XS.gguf";
      extras = { context = 8192; };
    }
    {
      name = "llama-3.3-nemotron-super-49b-v1_5";
      file = "Llama-3_3-Nemotron-Super-49B-v1_5-UD-Q4_K_XL.gguf";
      extras = { context = 8192; };
    }

    # Mistral family.
    {
      name = "mistral-small-3.2-24b-instruct-2506";
      file = "Mistral-Small-3.2-24B-Instruct-2506-UD-Q5_K_XL.gguf";
      extras = { context = 8192; } // discordVisible;
    }
    {
      name = "magidonia-24b-v4.3";
      file = "TheDrummer_Magidonia-24B-v4.3-Q5_K_M.gguf";
      extras = { context = 8192; };
    }

    # GPT-OSS family.
    {
      name = "gpt-oss-20b";
      file = "gpt-oss-20b-UD-Q4_K_XL.gguf";
      extras = { context = 8192; } // discordVisible;
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
  # ai user's `~/.docker` so credential helpers work.
  vllmEnv = {
    PATH = lib.makeBinPath [ pkgs.docker pkgs.coreutils pkgs.bash ];
    HOME = "/home/ai";
  };
  mkVllmService = index: m: {
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
    env = vllmEnv;
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
      placement_override = {
        "gpu:0" = m.per_gpu_mib;
        "gpu:1" = m.per_gpu_mib;
      };
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
    idle_timeout = "30s";
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
}
