{ pkgs, ... }:
let
  # Port definitions
  openaiPort = 7070;
  comfyuiPort = 8188;
  comfyuiTargetPort = 18188;

  # List of models with their configuration and actual file sizes
  models = [
    {
      name = "Qwen3-30B-A3B-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/Qwen3-30B-A3B-UD-Q4_K_XL.gguf";
      size = 17715663200;
      ctxLen = 8192;
      onCpu = true;
    }
    {
      name = "Qwen3-30B-A3B-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/Qwen3-30B-A3B-UD-Q4_K_XL.gguf";
      size = 17715663200;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "gemma-3-27b-it-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/gemma-3-27b-it-UD-Q4_K_XL.gguf";
      size = 16796522208;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "GLM-4-32B-0414-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/GLM-4-32B-0414-UD-Q4_K_XL.gguf";
      size = 19918569760;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "Mistral-Small-3.1-24B-Instruct-2503-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/Mistral-Small-3.1-24B-Instruct-2503-UD-Q4_K_XL.gguf";
      size = 15301055392;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "Phi-4-mini-reasoning-UD-Q8_K_XL";
      file = "/mnt/ssd2/ai/llm/Phi-4-mini-reasoning-UD-Q8_K_XL.gguf";
      size = 5088418720;
      ctxLen = 8192;
      onCpu = true;
    }
    {
      name = "Phi-4-reasoning-plus-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/Phi-4-reasoning-plus-UD-Q4_K_XL.gguf";
      size = 8947337920;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "phi-4-reasoning-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/phi-4-reasoning-UD-Q4_K_XL.gguf";
      size = 8947338528;
      ctxLen = 8192;
      onCpu = false;
    }
    {
      name = "Qwen3-0.6B-UD-Q8_K_XL";
      file = "/mnt/ssd2/ai/llm/Qwen3-0.6B-UD-Q8_K_XL.gguf";
      size = 844288480;
      ctxLen = 8192;
      onCpu = true;
    }
    {
      name = "Qwen3-32B-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/Qwen3-32B-UD-Q4_K_XL.gguf";
      size = 20021713344;
      ctxLen = 8192;
      onCpu = false;
    }
  ];

  # Helper function to create a service configuration
  mkService = {
    name, listenPort, targetPort, command, args, healthcheck ? null, restartOnConnectionFailure ? false,
    resourceRequirements, shutDownAfterInactivitySeconds ? 120, openaiApi ? false
  }: {
    Name = name;
    ListenPort = toString listenPort;
    ProxyTargetHost = "localhost";
    ProxyTargetPort = toString targetPort;
    Command = command;
    Args = args;
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
    in mkService {
      name = "${model.name}${if model.onCpu then "-CPU" else "-GPU"}";
      listenPort = port;
      targetPort = targetPort;
      command = "llama-server";
      openaiApi = true;
      args = "-m ${model.file} -c ${toString model.ctxLen} ${if model.onCpu then "--threads 24" else "-ngl 100"} --port ${toString targetPort}";
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
  llms = builtins.map (i: mkLlm i (builtins.elemAt models i)) (builtins.genList (x: x) (builtins.length models));

  # Generate the configuration
  config = {
    OpenAiApi = {
      ListenPort = toString openaiPort;
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
        restartOnConnectionFailure = true;
        shutDownAfterInactivitySeconds = 600;
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
  ports = [openaiPort] ++ (builtins.map (s: builtins.fromJSON s.ListenPort) config.Services);
in
{
  inherit jsonFile ports;
}