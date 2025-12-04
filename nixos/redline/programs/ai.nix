{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # AI/ML tools
    (whisper-cpp.override { cudaSupport = true; })
    config.ai.llamaCppCuda
  ];
}