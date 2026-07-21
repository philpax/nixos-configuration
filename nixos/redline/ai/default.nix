{ config, pkgs, ... }:

let
  flake-compat = import (builtins.fetchTarball {
    url = "https://github.com/edolstra/flake-compat/archive/ff81ac966bb2cae68946d5ed5fc4994f96d0ffec.tar.gz";
    sha256 = "19d2z6xsvpxm184m41qrpi1bplilwipgnzv9jy17fgw421785q1m";
  });
  llamaCpp = (flake-compat { src = ./llama-flake; }).defaultNix;
  llamaCppCuda = llamaCpp.packages.${pkgs.stdenv.hostPlatform.system}.cuda;
  ikLlamaCpp = (flake-compat { src = ./ik-llama-flake; }).defaultNix;
  ikLlamaCppCuda = ikLlamaCpp.packages.${pkgs.stdenv.hostPlatform.system}.cuda;
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
      ikLlamaCppCuda = pkgs.lib.mkOption {
        type = pkgs.lib.types.package;
        description = "CUDA-enabled ik_llama.cpp (ikawrakow fork) package";
        default = ikLlamaCppCuda;
      };
    };
  };

  config = {
    ai = {
      inherit llamaCppCuda ikLlamaCppCuda;
    };
  };
}
