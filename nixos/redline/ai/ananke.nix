{ config, pkgs, ... }:

let
  folders = import ../folders.nix;
  lib = pkgs.lib;

  llmDir = folders.ai.llm;
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
  # the model actually needs are set; mkLlmService folds them into a
  # well-formed ananke [[service]] block.
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
        lifecycle = "persistent";
        metadata = {
          discord_visible = true;
          resident = true;
        };
      };
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
      extras = gemma4Extras // { lifecycle = "persistent"; } // discordVisible;
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

  llmServices = lib.imap0 mkLlmService models;

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
    health = {
      http = "/system_stats";
    };
  };

  ananke_config = {
    daemon = {
      management_listen = "0.0.0.0:${toString managementPort}";
      allow_external_management = true;
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
