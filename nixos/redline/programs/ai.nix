{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # AI/ML tools
    (openai-whisper-cpp.override { cudaSupport = true; })
    config.ai.llamaCppCuda
  ];
}