# Shared llama.cpp/ik_llama.cpp CUDA packages. `ai.cudaCapabilities` has no
# default: every consumer must state which GPU architecture(s) to build for,
# since building every arch upstream supports drastically inflates compile
# time and there is no sane machine-independent default.
{ config, lib, pkgs, ... }:

let
  flake-compat = import (builtins.fetchTarball {
    url = "https://github.com/edolstra/flake-compat/archive/ff81ac966bb2cae68946d5ed5fc4994f96d0ffec.tar.gz";
    sha256 = "19d2z6xsvpxm184m41qrpi1bplilwipgnzv9jy17fgw421785q1m";
  });
  system = pkgs.stdenv.hostPlatform.system;

  llamaCpp = (flake-compat { src = ./llama-flake; }).defaultNix;
  ikLlamaCpp = (flake-compat { src = ./ik-llama-flake; }).defaultNix;

  cudaCapabilities = config.ai.cudaCapabilities;
in
{
  options.ai = {
    cudaCapabilities = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "CUDA architectures (nixpkgs cudaCapabilities format) to build ai.llamaCppCuda/ikLlamaCppCuda for. Required: no default, since it must match the machine's actual GPU.";
    };
    llamaCppCuda = lib.mkOption {
      type = lib.types.package;
      description = "CUDA-enabled llama-cpp package, built for ai.cudaCapabilities.";
      default = llamaCpp.lib.${system}.mkCuda { inherit cudaCapabilities; };
    };
    ikLlamaCppCuda = lib.mkOption {
      type = lib.types.package;
      description = "CUDA-enabled ik_llama.cpp (ikawrakow fork) package, built for ai.cudaCapabilities.";
      default = ikLlamaCpp.lib.${system}.mkCuda { inherit cudaCapabilities; };
    };
  };
}
