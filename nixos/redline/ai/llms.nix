{ pkgs, utils, llmBasePort, llmBaseTargetPort, folders, ... }:
let
  llmDir = folders.ai.llm;

  # List of models with their configuration and actual file sizes
  models = [
    # Qwen family
    {
      name = "qwen3-4b-instruct";
      file = "Qwen3-4B-Instruct-2507-UD-Q5_K_XL.gguf";
      size = 2899221600;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "qwen3-30b-a3b-instruct-2507";
      file = "Qwen3-30B-A3B-Instruct-2507-UD-Q4_K_XL.gguf";
      size = 17690497440;
      ctxLen = 8192;
      mode = "cpu";
    }
    {
      name = "qwen3-30b-a3b-instruct-2507";
      file = "Qwen3-30B-A3B-Instruct-2507-UD-Q4_K_XL.gguf";
      size = 17690497440;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "qwen3-30b-a3b-thinking-2507";
      file = "Qwen3-30B-A3B-Thinking-2507-UD-Q4_K_XL.gguf";
      size = 17715663264;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "qwen3-30b-a3b-coder-2507";
      file = "Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf";
      size = 17665334432;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "qwen3-32b";
      file = "Qwen3-32B-UD-Q4_K_XL.gguf";
      size = 20021713440;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "qwen3-235b-a22b-instruct";
      file = "Qwen3-235B-A22B-Instruct-2507-UD-Q2_K_XL-00001-of-00002.gguf";
      size = 0; # Will be overridden by memoryOverride
      ctxLen = 16384;
      mode = "hybrid";
      split = true;
      memoryOverride = {
        cpu = 87 * 1024; # 87GB in MB
        gpu1 = 18.5 * 1024; # 18.5GB on GPU-1 in MB
        gpu2 = 18.5 * 1024; # 18.5GB on GPU-2 in MB
      };
      extraArgs = "--threads 24 -ot \".ffn_(up|down)_exps.=CPU\" --prio 3 --temp 0.7 --min-p 0.0 --top-p 0.8 --top-k 20";
    }
    {
      name = "qwen3-vl-30b-a3b-instruct";
      file = "Qwen3-VL-30B-A3B-Instruct-UD-Q4_K_XL.gguf";
      mmproj = "Qwen3-VL-30B-A3B-Instruct-UD-Q4_K_XL-mmproj-F16.gguf";
      mmprojSize = 1083500096;
      size = 17715664480;
      ctxLen = 8192;
      mode = "gpu";
    }

    # Gemma family
    {
      name = "gemma-3-27b-it";
      file = "gemma-3-27b-it-UD-Q4_K_XL.gguf";
      size = 16796522208;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "gemma-3-27b-it-abliterated";
      file = "gemma-3-27b-it-abliterated.q4_k_m.gguf";
      size = 16546688736;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "gemma-3-glitter-27b";
      file = "Gemma-3-Glitter-27B.i1-Q5_K_M.gguf";
      size = 19271392672;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "gemma-3n-e4b-it";
      file = "gemma-3n-E4B-it-UD-Q4_K_XL.gguf";
      size = 5385042048;
      ctxLen = 16384;
      mode = "gpu";
    }

    # GLM family
    {
      name = "glm-4-32b-0414";
      file = "GLM-4-32B-0414-UD-Q4_K_XL.gguf";
      size = 19918569760;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "glm-z1-9b-0414";
      file = "GLM-Z1-9B-0414-UD-Q4_K_XL.gguf";
      size = 6208387200;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "glm-4-5-air";
      file = "GLM-4.5-Air-UD-Q3_K_XL-00001-of-00002.gguf";
      size = 0;
      ctxLen = 16384;
      mode = "hybrid";
      split = true;
      memoryOverride = {
        cpu = 20 * 1024;
        gpu1 = 21 * 1024;
        gpu2 = 14 * 1024;
      };
      extraArgs = "--threads 24 -ot \"\\.([0-9][0-9])\\.ffn_(up|down)_exps.=CPU\"";
    }

    # Llama family
    {
      name = "llama-3.3-70b-instruct-abliterated";
      file = "Llama-3.3-70B-Instruct-abliterated-IQ2_XS.gguf";
      size = 21142113344;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "llama-3.3-nemotron-super-49b-v1_5";
      file = "Llama-3_3-Nemotron-Super-49B-v1_5-UD-Q4_K_XL.gguf";
      size = 30363166624;
      ctxLen = 8192;
      mode = "gpu";
      split = true;
    }

    # Mistral family
    {
      name = "mistral-small-3.2-24b-instruct-2506";
      file = "Mistral-Small-3.2-24B-Instruct-2506-UD-Q5_K_XL.gguf";
      size = 16765840768;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "magidonia-24b-v4.3";
      file = "TheDrummer_Magidonia-24B-v4.3-Q5_K_M.gguf";
      size = 16763987360;
      ctxLen = 8192;
      mode = "gpu";
    }

    # GPT OSS family
    {
      name = "gpt-oss-20b";
      file = "gpt-oss-20b-UD-Q4_K_XL.gguf";
      size = 11872347328;
      ctxLen = 8192;
      mode = "gpu";
    }
  ];

  # Function to create an LLM service from a model
  mkLlm = index: model:
    let
      port = llmBasePort + index;
      targetPort = llmBaseTargetPort + index;

      # Calculate memory overhead from context length (ctxLen/4 MB)
      ctxOverheadMB = model.ctxLen / 4;
      # Include mmproj size if present
      totalModelSize = model.size + (model.mmprojSize or 0);
      # Use memory override if provided, otherwise calculate from file size
      memoryMB = if model.memoryOverride or null != null then
        (if model.mode == "cpu" then model.memoryOverride.cpu else model.memoryOverride.gpu or model.memoryOverride.gpu1 or 0)
      else
        (totalModelSize / (1024 * 1024)) + ctxOverheadMB;
      # Calculate CPU and GPU memory requirements
      cpuMemoryMB = if model.memoryOverride or null != null then
        (if model.mode == "cpu" then memoryMB else model.memoryOverride.cpu or 0)
      else
        memoryMB;
      gpu1MemoryMB = if model.memoryOverride or null != null then
        (if model.mode == "cpu" then 0 else model.memoryOverride.gpu1 or model.memoryOverride.gpu or memoryMB)
      else
        (if model.mode == "cpu" then 0 else memoryMB);
      gpu2MemoryMB = if model.memoryOverride or null != null then
        (if model.mode == "cpu" then 0 else model.memoryOverride.gpu2 or model.memoryOverride.gpu or memoryMB)
      else
        (if model.mode == "cpu" then 0 else memoryMB);

      specialTokensFlag = if model.specialTokens or false then "-sp" else "";

      # Validate that split is only used with gpu mode
      _ = if (model.split or false) && (model.mode == "cpu") then
        throw "Error: split cannot be used with cpu mode for model ${model.name}"
      else null;
      # Split memory flag
      splitMemoryFlag = if model.split or false then "-sm layer" else "-sm none";

      # Extra arguments
      extraArgs = model.extraArgs or "";

      # Multimodal projector argument
      mmprojArg = if model.mmproj or null != null then "--mmproj ${llmDir}/${model.mmproj}" else "";
    in utils.mkService {
      name = "${model.mode}:${model.name}";
      listenPort = port;
      targetPort = targetPort;
      command = "llama-server";
      openaiApi = true;
      args = "-m ${llmDir}/${model.file} ${mmprojArg} -c ${toString model.ctxLen} ${if model.mode == "cpu" then "--threads 24" else "-ngl 100"} --jinja ${specialTokensFlag} ${splitMemoryFlag} ${extraArgs} --port ${toString targetPort}";
      healthcheck = {
        command = "curl --fail http://localhost:${toString targetPort}/health";
        intervalMilliseconds = 200;
      };
      resourceRequirements = if model.mode == "cpu" then {
        RAM = builtins.ceil cpuMemoryMB;
      } else if model.mode == "gpu" then
        if model.split or false then {
          "VRAM-GPU-1" = builtins.ceil (gpu1MemoryMB / 2);
          "VRAM-GPU-2" = builtins.ceil (gpu2MemoryMB / 2);
        } else {
          "VRAM-GPU-1" = builtins.ceil gpu1MemoryMB;
        }
      else if model.mode == "hybrid" then
        if model.memoryOverride or null != null && model.memoryOverride.gpu1 or null != null && model.memoryOverride.gpu2 or null != null then {
          RAM = builtins.ceil cpuMemoryMB;
          "VRAM-GPU-1" = builtins.ceil gpu1MemoryMB;
          "VRAM-GPU-2" = builtins.ceil gpu2MemoryMB;
        } else {
          RAM = builtins.ceil cpuMemoryMB;
          "VRAM-GPU-1" = builtins.ceil gpu1MemoryMB;
        }
      else {

      };
    };

  # Generate all LLMs
  llms = let
    # Sort models so GPU models come first (mode != "cpu")
    sortedModels = builtins.sort (a: b: a.mode != "cpu" && b.mode == "cpu") models;
  in builtins.map (i: mkLlm i (builtins.elemAt sortedModels i)) (builtins.genList (x: x) (builtins.length models));
in
{
  inherit llms;
}
