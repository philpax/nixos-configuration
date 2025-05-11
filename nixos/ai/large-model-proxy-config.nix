{ pkgs, ... }:
let
  # Port definitions
  openaiPort = 7070;
  managementPort = 7071;
  comfyuiPort = 8188;
  comfyuiTargetPort = 18188;

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
      name = "qwen3-4b";
      file = "/mnt/ssd2/ai/llm/Qwen3-4B-UD-Q4_K_XL.gguf";
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
      name = "gemma-3-4b-it";
      file = "/mnt/ssd2/ai/llm/gemma-3-4b-it-UD-Q4_K_XL.gguf";
      size = 2544288896;
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
      name = "mistral-small-3.1-24b-instruct-2503";
      file = "/mnt/ssd2/ai/llm/Mistral-Small-3.1-24B-Instruct-2503-UD-Q4_K_XL.gguf";
      size = 15301055392;
      ctxLen = 8192;
      onCpu = false;
    }

    # Phi family
    {
      name = "phi-4-mini-reasoning";
      file = "/mnt/ssd2/ai/llm/Phi-4-mini-reasoning-UD-Q8_K_XL.gguf";
      size = 5088418720;
      ctxLen = 8192;
      onCpu = true;
      specialTokens = true;
    }
    {
      name = "phi-4-reasoning";
      file = "/mnt/ssd2/ai/llm/phi-4-reasoning-UD-Q4_K_XL.gguf";
      size = 8947338528;
      ctxLen = 8192;
      onCpu = false;
      specialTokens = true;
    }
    {
      name = "phi-4-reasoning-plus";
      file = "/mnt/ssd2/ai/llm/Phi-4-reasoning-plus-UD-Q4_K_XL.gguf";
      size = 8947337920;
      ctxLen = 8192;
      onCpu = false;
      specialTokens = true;
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
    {
      name = "mn-12b-mag-mell-r1";
      file = "/mnt/ssd2/ai/llm/MN-12B-Mag-Mell-R1.i1-Q4_K_M.gguf";
      size = 7477206400;
      ctxLen = 8192;
      onCpu = false;
    }
  ];

  # Helper function to create a service configuration
  mkService = {
    name, listenPort, targetPort, command, killCommand ? null, args, healthcheck ? null, restartOnConnectionFailure ? false,
    resourceRequirements, shutDownAfterInactivitySeconds ? 120, openaiApi ? false
  }: {
    Name = name;
    ListenPort = toString listenPort;
    ProxyTargetHost = "localhost";
    ProxyTargetPort = toString targetPort;
    Command = command;
    Args = args;
    KillCommand = killCommand;
    OpenAiApi = openaiApi;
    RestartOnConnectionFailure = restartOnConnectionFailure;
    ResourceRequirements = resourceRequirements;
    ShutDownAfterInactivitySeconds = shutDownAfterInactivitySeconds;
  } // (if healthcheck != null then {
    HealthcheckCommand = healthcheck.command;
    HealthcheckIntervalMilliseconds = healthcheck.intervalMilliseconds;
  } else {});

  # Function to create an LLM service from a model
  mkLlm = index: model:
    let
      port = 8200 + index;
      targetPort = 18200 + index;
      # Calculate memory overhead from context length (ctxLen/4 MB)
      ctxOverheadMB = model.ctxLen / 4;
      memoryMB = (model.size / (1024 * 1024)) + ctxOverheadMB;
      specialTokensFlag = if model.specialTokens or false then "-sp" else "";
    in mkService {
      name = "${if model.onCpu then "cpu" else "gpu"}:${model.name}";
      listenPort = port;
      targetPort = targetPort;
      command = "llama-server";
      openaiApi = true;
      args = "-m ${model.file} -c ${toString model.ctxLen} ${if model.onCpu then "--threads 24" else "-ngl 100"} ${specialTokensFlag} --port ${toString targetPort}";
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

  # Generate the configuration
  config = {
    OpenAiApi = {
      ListenPort = toString openaiPort;
    };
    ManagementApi = {
      ListenPort = toString managementPort;
    };
    MaxTimeToWaitForServiceToCloseConnectionBeforeGivingUpSeconds = 1200;
    ShutDownAfterInactivitySeconds = 120;
    ResourcesAvailable = {
      "VRAM-GPU-1" = 24000;
      RAM = 96000;
    };
    Services = [
      (mkService {
        name = "ComfyUI";
        listenPort = comfyuiPort;
        targetPort = comfyuiTargetPort;
        command = "docker";
        args = "run --rm --name comfyui --device nvidia.com/gpu=all -v /mnt/ssd2/ai/ComfyUI:/workspace -p ${toString comfyuiTargetPort}:${toString comfyuiPort} pytorch/pytorch:2.6.0-cuda12.6-cudnn9-devel /bin/bash -c 'cd /workspace && source .venv/bin/activate && apt update && apt install -y git && pip install -r requirements.txt && python main.py --listen --enable-cors-header'";
        killCommand = "docker kill comfyui";
        restartOnConnectionFailure = true;
        shutDownAfterInactivitySeconds = 30;
        resourceRequirements = {
          "VRAM-GPU-1" = 20000;
          RAM = 16000;
        };
      })
    ] ++ llms;
  };

  # Generate the JSON file
  jsonFile = pkgs.writeText "large-model-proxy-config.json" (builtins.toJSON config);

  # Extract all ports from the configuration
  ports = [openaiPort managementPort] ++ (builtins.map (s: builtins.fromJSON s.ListenPort) config.Services);
in
{
  inherit jsonFile ports;
}