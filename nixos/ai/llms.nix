{ pkgs, utils, llmBasePort, llmBaseTargetPort, ... }:
let
  # List of models with their configuration and actual file sizes
  models = [
    # Qwen family
    {
      name = "qwen3-0.6b";
      file = "/mnt/ssd2/ai/llm/Qwen3-0.6B-UD-Q8_K_XL.gguf";
      size = 844288576;
      ctxLen = 8192;
      mode = "cpu";
    }
    {
      name = "qwen3-1.7b";
      file = "/mnt/ssd2/ai/llm/Qwen3-1.7B-UD-Q8_K_XL.gguf";
      size = 2332582464;
      ctxLen = 8192;
      mode = "cpu";
    }
    {
      name = "qwen3-8b";
      file = "/mnt/ssd2/ai/llm/Qwen3-8B-UD-Q4_K_XL.gguf";
      size = 5135722176;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "qwen3-30b-a3b-instruct-2507";
      file = "/mnt/ssd2/ai/llm/Qwen3-30B-A3B-Instruct-2507-UD-Q4_K_XL.gguf";
      size = 17690497440;
      ctxLen = 8192;
      mode = "cpu";
    }
    {
      name = "qwen3-30b-a3b-instruct-2507";
      file = "/mnt/ssd2/ai/llm/Qwen3-30B-A3B-Instruct-2507-UD-Q4_K_XL.gguf";
      size = 17690497440;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "qwen3-32b";
      file = "/mnt/ssd2/ai/llm/Qwen3-32B-UD-Q4_K_XL.gguf";
      size = 20021713440;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "qwen3-235b-a22b-instruct";
      file = "/mnt/ssd2/ai/llm/Qwen3-235B-A22B-Instruct-2507-UD-Q2_K_XL-00001-of-00002.gguf";
      size = 0; # Will be overridden by memoryOverride
      ctxLen = 16384;
      mode = "hybrid";
      split = true;
      memoryOverride = {
        cpu = 87 * 1024; # 87GB in MB
        gpu = 18.5 * 1024; # 18.5GB per GPU in MB
      };
      extraArgs = "--threads 24 -ot \".ffn_(up|down)_exps.=CPU\" --prio 3 --temp 0.7 --min-p 0.0 --top-p 0.8 --top-k 20";
    }

    # Gemma family
    {
      name = "gemma-3-1b-it";
      file = "/mnt/ssd2/ai/llm/gemma-3-1b-it-Q8_0.gguf";
      size = 1054929440;
      ctxLen = 8192;
      mode = "cpu";
    }
    {
      name = "gemma-3-27b-it";
      file = "/mnt/ssd2/ai/llm/gemma-3-27b-it-UD-Q4_K_XL.gguf";
      size = 16796522208;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "gemma-3-27b-it-abliterated";
      file = "/mnt/ssd2/ai/llm/gemma-3-27b-it-abliterated.q4_k_m.gguf";
      size = 16546688736;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "gemma-3-glitter-27b";
      file = "/mnt/ssd2/ai/llm/Gemma-3-Glitter-27B.i1-Q5_K_M.gguf";
      size = 19271392672;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "gemma-3n-e4b-it";
      file = "/mnt/ssd2/ai/llm/gemma-3n-E4B-it-Q6_K.gguf";
      size = 6272219264;
      ctxLen = 16384;
      mode = "gpu";
    }

    # GLM family
    {
      name = "glm-4-32b-0414";
      file = "/mnt/ssd2/ai/llm/GLM-4-32B-0414-UD-Q4_K_XL.gguf";
      size = 19918569760;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "glm-z1-9b-0414";
      file = "/mnt/ssd2/ai/llm/GLM-Z1-9B-0414-UD-Q4_K_XL.gguf";
      size = 6208387200;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "glm-4-32b-neon-v2";
      file = "/mnt/ssd2/ai/llm/allura-org_GLM4-32B-Neon-v2-Q4_K_M.gguf";
      size = 19680022720;
      ctxLen = 8192;
      mode = "gpu";
    }

    # Llama family
    {
      name = "llama-3.2-3b-instruct";
      file = "/mnt/ssd2/ai/llm/Llama-3.2-3B-Instruct-UD-Q4_K_XL.gguf";
      size = 2060886464;
      ctxLen = 8192;
      mode = "cpu";
    }
    {
      name = "llama-3.3-70b-instruct-abliterated";
      file = "/mnt/ssd2/ai/llm/Llama-3.3-70B-Instruct-abliterated-IQ2_XS.gguf";
      size = 21142113344;
      ctxLen = 8192;
      mode = "gpu";
    }

    # Mistral family
    {
      name = "mistral-small-3.2-24b-instruct-2506";
      file = "/mnt/ssd2/ai/llm/Mistral-Small-3.2-24B-Instruct-2506-UD-Q5_K_XL.gguf";
      size = 16765840768;
      ctxLen = 8192;
      mode = "gpu";
      jinja = true;
    }
    {
      name = "mistral-small-3.2-24b-angel";
      file = "/mnt/ssd2/ai/llm/allura-org_MS3.2-24b-Angel-Q5_K_M.gguf";
      size = 16763989696;
      ctxLen = 8192;
      mode = "gpu";
      jinja = true;
    }
    {
      name = "magistral-small-2506";
      file = "/mnt/ssd2/ai/llm/Magistral-Small-2506-UD-Q5_K_XL.gguf";
      size = 16765828640;
      ctxLen = 8192;
      mode = "gpu";
      jinja = true;
    }

    # OLMo family
    {
      name = "olmo-2-0425-1b-instruct";
      file = "/mnt/ssd2/ai/llm/OLMo-2-0425-1B-Instruct-UD-Q8_K_XL.gguf";
      size = 2242270432;
      ctxLen = 8192;
      mode = "cpu";
    }

    # Other models
    {
      name = "shuttleai-shuttle-3.5";
      file = "/mnt/ssd2/ai/llm/shuttleai_shuttle-3.5-Q4_K_M.gguf";
      size = 19762150176;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "tessa-rust-7b";
      file = "/mnt/ssd2/ai/llm/tessa-rust-7b-q8_0.gguf";
      size = 8098525024;
      ctxLen = 8192;
      mode = "gpu";
    }
    {
      name = "cassiopeia-70b";
      file = "/mnt/ssd2/ai/llm/ddh0_Cassiopeia-70B-Q4_K_M.gguf";
      size = 42520399072;
      ctxLen = 8192;
      mode = "gpu";
      split = true;
    }
  ];

  # Function to create an LLM service from a model
  mkLlm = index: model:
    let
      port = llmBasePort + index;
      targetPort = llmBaseTargetPort + index;

      # Calculate memory overhead from context length (ctxLen/4 MB)
      ctxOverheadMB = model.ctxLen / 4;
      # Use memory override if provided, otherwise calculate from file size
      memoryMB = if model.memoryOverride or null != null then
        (if model.mode == "cpu" then model.memoryOverride.cpu else model.memoryOverride.gpu)
      else
        (model.size / (1024 * 1024)) + ctxOverheadMB;
      # Calculate CPU and GPU memory requirements
      cpuMemoryMB = if model.memoryOverride or null != null then
        (if model.mode == "cpu" then memoryMB else model.memoryOverride.cpu or 0)
      else
        memoryMB;
      gpuMemoryMB = if model.memoryOverride or null != null then
        (if model.mode == "cpu" then 0 else model.memoryOverride.gpu or memoryMB)
      else
        (if model.mode == "cpu" then 0 else memoryMB);

      jinjaFlag = if model.jinja or false then "--jinja" else "";
      specialTokensFlag = if model.specialTokens or false then "-sp" else "";

      # Validate that split is only used with gpu mode
      _ = if (model.split or false) && (model.mode == "cpu") then
        throw "Error: split cannot be used with cpu mode for model ${model.name}"
      else null;
      # Split memory flag
      splitMemoryFlag = if model.split or false then "-sm layer" else "-sm none";

      # Extra arguments
      extraArgs = model.extraArgs or "";
    in utils.mkService {
      name = "${model.mode}:${model.name}";
      listenPort = port;
      targetPort = targetPort;
      command = "llama-server";
      openaiApi = true;
      args = "-m ${model.file} -c ${toString model.ctxLen} ${if model.mode == "cpu" then "--threads 24" else "-ngl 100"} ${jinjaFlag} ${specialTokensFlag} ${splitMemoryFlag} ${extraArgs} --port ${toString targetPort}";
      healthcheck = {
        command = "curl --fail http://localhost:${toString targetPort}/health";
        intervalMilliseconds = 200;
      };
      resourceRequirements = if model.mode == "cpu" then {
        RAM = builtins.ceil cpuMemoryMB;
      } else if model.mode == "gpu" then
        if model.split or false then {
          "VRAM-GPU-1" = builtins.ceil (gpuMemoryMB / 2);
          "VRAM-GPU-2" = builtins.ceil (gpuMemoryMB / 2);
        } else {
          "VRAM-GPU-1" = builtins.ceil gpuMemoryMB;
        }
      else if model.mode == "hybrid" then {
        RAM = builtins.ceil cpuMemoryMB;
        "VRAM-GPU-1" = builtins.ceil gpuMemoryMB;
      } else {

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