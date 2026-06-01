{ config, pkgs, ... }:

let
  # llama.cpp consumed straight from upstream's own flake (./llama-flake,
  # pinned to tag b9444) rather than nixpkgs' llama-cpp. flake-compat evaluates
  # that flake from this channels-based config; its `cuda` output is built
  # against llama.cpp's own pinned nixpkgs with cudaSupport enabled. See
  # ./llama-flake/flake.nix for how to bump the pinned tag.
  flake-compat = import (builtins.fetchTarball {
    url = "https://github.com/edolstra/flake-compat/archive/ff81ac966bb2cae68946d5ed5fc4994f96d0ffec.tar.gz";
    sha256 = "19d2z6xsvpxm184m41qrpi1bplilwipgnzv9jy17fgw421785q1m";
  });
  llamaCpp = (flake-compat { src = ./llama-flake; }).defaultNix;
  llamaCppCuda = llamaCpp.packages.${pkgs.system}.cuda;
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
