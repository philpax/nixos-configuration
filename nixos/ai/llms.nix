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
      onCpu = true;
    }
    {
      name = "qwen3-1.7b";
      file = "/mnt/ssd2/ai/llm/Qwen3-1.7B-UD-Q8_K_XL.gguf";
      size = 2332582464;
      ctxLen = 8192;
      onCpu = true;
    }
    {
      name = "qwen3-8b";
      file = "/mnt/ssd2/ai/llm/Qwen3-8B-UD-Q4_K_XL.gguf";
      size = 5135722176;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "qwen3-30b-a3b";
      file = "/mnt/ssd2/ai/llm/Qwen3-30B-A3B-UD-Q4_K_XL.gguf";
      size = 17715663296;
      ctxLen = 8192;
      onCpu = true;
    }
    {
      name = "qwen3-30b-a3b";
      file = "/mnt/ssd2/ai/llm/Qwen3-30B-A3B-UD-Q4_K_XL.gguf";
      size = 17715663296;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "qwen3-32b";
      file = "/mnt/ssd2/ai/llm/Qwen3-32B-UD-Q4_K_XL.gguf";
      size = 20021713440;
      ctxLen = 8192;
      onCpu = false;
    }

    # Gemma family
    {
      name = "gemma-3-1b-it";
      file = "/mnt/ssd2/ai/llm/gemma-3-1b-it-Q8_0.gguf";
      size = 1054929440;
      ctxLen = 8192;
      onCpu = true;
    }
    {
      name = "gemma-3-27b-it";
      file = "/mnt/ssd2/ai/llm/gemma-3-27b-it-UD-Q4_K_XL.gguf";
      size = 16796522208;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "gemma-3-27b-it-abliterated";
      file = "/mnt/ssd2/ai/llm/gemma-3-27b-it-abliterated.q4_k_m.gguf";
      size = 16546688736;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "gemma-3-glitter-27b";
      file = "/mnt/ssd2/ai/llm/Gemma-3-Glitter-27B.i1-Q5_K_M.gguf";
      size = 19271392672;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "gemma-3n-e4b-it";
      file = "/mnt/ssd2/ai/llm/gemma-3n-E4B-it-Q6_K.gguf";
      size = 6272219264;
      ctxLen = 16384;
      onCpu = false;
    }

    # GLM family
    {
      name = "glm-4-32b-0414";
      file = "/mnt/ssd2/ai/llm/GLM-4-32B-0414-UD-Q4_K_XL.gguf";
      size = 19918569760;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "glm-z1-9b-0414";
      file = "/mnt/ssd2/ai/llm/GLM-Z1-9B-0414-UD-Q4_K_XL.gguf";
      size = 6208387200;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "glm-4-32b-neon-v2";
      file = "/mnt/ssd2/ai/llm/allura-org_GLM4-32B-Neon-v2-Q4_K_M.gguf";
      size = 19680022720;
      ctxLen = 8192;
      onCpu = false;
    }

    # Llama family
    {
      name = "llama-3.2-3b-instruct";
      file = "/mnt/ssd2/ai/llm/Llama-3.2-3B-Instruct-UD-Q4_K_XL.gguf";
      size = 2060886464;
      ctxLen = 8192;
      onCpu = true;
    }
    {
      name = "llama-3.3-70b-instruct-abliterated";
      file = "/mnt/ssd2/ai/llm/Llama-3.3-70B-Instruct-abliterated-IQ2_XS.gguf";
      size = 21142113344;
      ctxLen = 8192;
      onCpu = false;
    }

    # Mistral family
    {
      name = "mistral-small-3.2-24b-instruct-2506";
      file = "/mnt/ssd2/ai/llm/Mistral-Small-3.2-24B-Instruct-2506-UD-Q5_K_XL.gguf";
      size = 16765840768;
      ctxLen = 8192;
      onCpu = false;
      jinja = true;
    }
    {
      name = "mistral-small-3.2-24b-angel";
      file = "/mnt/ssd2/ai/llm/allura-org_MS3.2-24b-Angel-Q5_K_M.gguf";
      size = 16763989696;
      ctxLen = 8192;
      onCpu = false;
      jinja = true;
    }
    {
      name = "magistral-small-2506";
      file = "/mnt/ssd2/ai/llm/Magistral-Small-2506-UD-Q5_K_XL.gguf";
      size = 16765828640;
      ctxLen = 8192;
      onCpu = false;
      jinja = true;
    }

    # OLMo family
    {
      name = "olmo-2-0425-1b-instruct";
      file = "/mnt/ssd2/ai/llm/OLMo-2-0425-1B-Instruct-UD-Q8_K_XL.gguf";
      size = 2242270432;
      ctxLen = 8192;
      onCpu = true;
    }

    # Other models
    {
      name = "shuttleai-shuttle-3.5";
      file = "/mnt/ssd2/ai/llm/shuttleai_shuttle-3.5-Q4_K_M.gguf";
      size = 19762150176;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "tessa-rust-7b";
      file = "/mnt/ssd2/ai/llm/tessa-rust-7b-q8_0.gguf";
      size = 8098525024;
      ctxLen = 8192;
      onCpu = false;
    }
  ];

  # Function to create an LLM service from a model
  mkLlm = index: model:
    let
      port = llmBasePort + index;
      targetPort = llmBaseTargetPort + index;
      # Calculate memory overhead from context length (ctxLen/4 MB)
      ctxOverheadMB = model.ctxLen / 4;
      memoryMB = (model.size / (1024 * 1024)) + ctxOverheadMB;
      jinjaFlag = if model.jinja or false then "--jinja" else "";
      specialTokensFlag = if model.specialTokens or false then "-sp" else "";
    in utils.mkService {
      name = "${if model.onCpu then "cpu" else "gpu"}:${model.name}";
      listenPort = port;
      targetPort = targetPort;
      command = "llama-server";
      openaiApi = true;
      args = "-m ${model.file} -c ${toString model.ctxLen} ${if model.onCpu then "--threads 24" else "-ngl 100"} ${jinjaFlag} ${specialTokensFlag} --port ${toString targetPort}";
      healthcheck = {
        command = "curl --fail http://localhost:${toString targetPort}/health";
        intervalMilliseconds = 200;
      };
      resourceRequirements = if model.onCpu then {
        RAM = memoryMB;
      } else {
        "VRAM-GPU-1" = memoryMB;
      };
    };

  # Generate all LLMs
  llms = let
    # Sort models so GPU models come first (onCpu = false)
    sortedModels = builtins.sort (a: b: !a.onCpu && b.onCpu) models;
  in builtins.map (i: mkLlm i (builtins.elemAt sortedModels i)) (builtins.genList (x: x) (builtins.length models));
in
{
  inherit llms;
}