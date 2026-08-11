# Both GPUs are RTX 3090s (sm_86).
{ ... }:
{
  imports = [
    ./users.nix
    ./ananke.nix
  ];

  config.ai.cudaCapabilities = [ "8.6" ];
}
