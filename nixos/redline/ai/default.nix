{ config, pkgs, unstable, ... }:

let
  llamaCppCuda = (unstable.llama-cpp.override { cudaSupport = true; });
in
{
  imports = [
    ./users.nix
    ./ananke.nix
  ];

  options = {
    ai = {
      llamaCppCuda = pkgs.lib.mkOption {
        type = pkgs.lib.types.package;
        description = "CUDA-enabled llama-cpp package";
        default = llamaCppCuda;
      };
    };
  };

  config = {
    ai = {
      inherit llamaCppCuda;
    };
  };
}
