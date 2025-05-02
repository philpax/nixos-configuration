{ pkgs, ... }:
let
  # List of models with their configuration
  models = [
    {
      name = "Qwen3-30B-A3B-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/Qwen3-30B-A3B-UD-Q4_K_XL.gguf";
      onCpu = true;
    }
    {
      name = "Qwen3-30B-A3B-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/Qwen3-30B-A3B-UD-Q4_K_XL.gguf";
      onCpu = false;
    }
    {
      name = "gemma-3-27b-it-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/gemma-3-27b-it-UD-Q4_K_XL.gguf";
      onCpu = false;
    }
    {
      name = "GLM-4-32B-0414-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/GLM-4-32B-0414-UD-Q4_K_XL.gguf";
      onCpu = false;
    }
    {
      name = "Mistral-Small-3.1-24B-Instruct-2503-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/Mistral-Small-3.1-24B-Instruct-2503-UD-Q4_K_XL.gguf";
      onCpu = false;
    }
    {
      name = "Phi-4-mini-reasoning-UD-Q8_K_XL";
      file = "/mnt/ssd2/ai/llm/Phi-4-mini-reasoning-UD-Q8_K_XL.gguf";
      onCpu = true;
    }
    {
      name = "Phi-4-reasoning-plus-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/Phi-4-reasoning-plus-UD-Q4_K_XL.gguf";
      onCpu = false;
    }
    {
      name = "phi-4-reasoning-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/phi-4-reasoning-UD-Q4_K_XL.gguf";
      onCpu = false;
    }
    {
      name = "Qwen3-0.6B-UD-Q8_K_XL";
      file = "/mnt/ssd2/ai/llm/Qwen3-0.6B-UD-Q8_K_XL.gguf";
      onCpu = true;
    }
    {
      name = "Qwen3-32B-UD-Q4_K_XL";
      file = "/mnt/ssd2/ai/llm/Qwen3-32B-UD-Q4_K_XL.gguf";
      onCpu = false;
    }
  ];

  # Function to get file size in MB
  getFileSize = file: builtins.readFile (pkgs.runCommand "get-file-size" {} ''
    stat -c %s "${file}" > $out
  '');

  # Function to create a service from a model
  mkLlm = index: model:
    let
      port = 8200 + index;
      targetPort = 18200 + index;
      fileSizeMB = (builtins.fromJSON (getFileSize model.file)) / (1024 * 1024);
      memoryMB = fileSizeMB + 2048; # Add 2GB overhead from context length
    in {
      Name = "${model.name}${if model.onCpu then "-CPU" else "-GPU"}";
      OpenAiApi = true;
      ListenPort = toString port;
      ProxyTargetHost = "localhost";
      ProxyTargetPort = toString targetPort;
      Command = "llama-server";
      Args = "-m ${model.file} -c 8192 ${if model.onCpu then "--threads 24" else "-ngl 100"} --port ${toString targetPort}";
      HealthcheckCommand = "curl --fail http://localhost:${toString targetPort}/health";
      HealthcheckIntervalMilliseconds = 200;
      RestartOnConnectionFailure = false;
      ResourceRequirements = if model.onCpu then {
        RAM = memoryMB;
      } else {
        "VRAM-GPU-1" = memoryMB;
      };
    };

  # Generate all LLMs
  llms = builtins.map (i: mkLlm i (builtins.elemAt models i)) (builtins.genList (x: x) (builtins.length models));

in
pkgs.writeText "large-model-proxy-config.json" (builtins.toJSON {
  OpenAiApi = {
    ListenPort = "7070";
  };
  MaxTimeToWaitForServiceToCloseConnectionBeforeGivingUpSeconds = 1200;
  ShutDownAfterInactivitySeconds = 120;
  ResourcesAvailable = {
    "VRAM-GPU-1" = 24000;
    RAM = 96000;
  };
  Services = [
    {
      Name = "ComfyUI";
      ListenPort = "8188";
      ProxyTargetHost = "localhost";
      ProxyTargetPort = "18188";
      Command = "docker";
      Args = "run --rm --name comfyui --device nvidia.com/gpu=all -v /mnt/ssd2/ai/ComfyUI:/workspace -p 18188:8188 pytorch/pytorch:2.6.0-cuda12.6-cudnn9-devel /bin/bash -c 'cd /workspace && source .venv/bin/activate && apt update && apt install -y git && pip install -r requirements.txt && python main.py --listen --enable-cors-header'";
      ShutDownAfterInactivitySeconds = 600;
      RestartOnConnectionFailure = true;
      ResourceRequirements = {
        "VRAM-GPU-1" = 20000;
        RAM = 16000;
      };
    }
  ] ++ llms;
})