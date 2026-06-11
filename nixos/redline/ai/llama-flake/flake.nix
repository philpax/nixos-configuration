{
  # Thin wrapper around upstream llama.cpp's own flake. Upstream ships a
  # flake.nix but no flake.lock, so it can't be consumed directly from our
  # channels-based config under pure evaluation. This wrapper pins it (and its
  # transitive inputs) via the committed flake.lock here, and re-exports its
  # packages. Consumed from ../default.nix via flake-compat.
  #
  # The `cuda` package is rebuilt here rather than re-exported so we can pin
  # CUDA architectures to SM 8.6 (RTX 3090); upstream builds for every
  # supported arch, which drastically inflates compile time.
  #
  # Note: NCCL was evaluated 2026-06-11 (add cudaPackages.nccl to the
  # llama-cpp buildInputs + LD_LIBRARY_PATH=/run/opengl-driver/lib for NVML)
  # and measured ~4% SLOWER than llama.cpp's internal AllReduce for 2-GPU
  # tensor split over PCIe — deliberately not enabled. See
  # /mnt/ssd0/ai/llm/unsloth/gemma-4-31B-it-qat-GGUF/bench/TRIALS.md.
  #
  # To move to a newer llama.cpp tag: change the rev below, then run
  #   nix flake update llama-cpp
  # in this directory and commit the updated flake.lock.
  description = "Pinned upstream llama.cpp flake for redline's AI services";

  inputs.llama-cpp.url = "github:ggml-org/llama.cpp/b9592";

  outputs = { llama-cpp, ... }:
    let
      system = "x86_64-linux";
      lib = llama-cpp.inputs.nixpkgs.lib;

      # Mirror upstream's pkgsCuda instance (.devops/nix/nixpkgs-instances.nix),
      # plus the SM 8.6 specialisation.
      pkgsCuda = import llama-cpp.inputs.nixpkgs {
        inherit system;
        config.cudaSupport = true;
        config.cudaCapabilities = [ "8.6" ];
        config.cudaEnableForwardCompat = false;
        config.allowUnfreePredicate =
          p:
          builtins.all (
            license:
            license.free
            || builtins.elem license.shortName [
              "CUDA EULA"
              "cuDNN EULA"
            ]
          ) (p.meta.licenses or (lib.toList p.meta.license));
      };

      llamaPackagesCuda = pkgsCuda.callPackage "${llama-cpp}/.devops/nix/scope.nix" {
        llamaVersion = "0.0.0";
      };
    in
    {
      packages.${system} = llama-cpp.packages.${system} // {
        cuda = llamaPackagesCuda.llama-cpp;
      };
    };
}
