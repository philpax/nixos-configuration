{
  # Thin wrapper around upstream llama.cpp's own flake. Upstream ships a
  # flake.nix but no flake.lock, so it can't be consumed directly from our
  # channels-based config under pure evaluation. This wrapper pins it (and its
  # transitive inputs) via the committed flake.lock here, and re-exports its
  # packages. Consumed from ../default.nix via flake-compat.
  #
  # The `cuda` package is rebuilt here rather than re-exported, for two reasons:
  #   1. CUDA architectures pinned to SM 8.6 (RTX 3090); upstream builds every
  #      supported arch, which drastically inflates compile time.
  #   2. fattn-graph-reuse-fix.patch: fixes tensor split crash in meta backend shard registration. Duplicated in ../poolside-llama-flake/ — keep in sync.
  #
  # The rev below is pinned to an upstream master commit (2026-07-10,
  # c749cb04), not a release tag. The patch was rebased onto it after upstream
  # reordered the contiguity asserts in the meta buffer set/get_tensor paths.
  #
  # Note: NCCL was evaluated 2026-06-11 (add cudaPackages.nccl to the
  # llama-cpp buildInputs + LD_LIBRARY_PATH=/run/opengl-driver/lib for NVML)
  # and measured ~4% SLOWER than llama.cpp's internal AllReduce for 2-GPU
  # tensor split over PCIe — deliberately not enabled. See TRIALS.md above.
  #
  # To move to a newer llama.cpp rev: run ./update.sh [ref] in this directory
  # (defaults to master). It resolves the ref, rewrites the rev below, and
  # relocks. Commit this file and the updated flake.lock afterwards.
  # (The rev can't live in a separate file: flake inputs must be literal
  # strings, so readFile-based interpolation is rejected by nix.)
  description = "Pinned upstream llama.cpp flake for redline's AI services";

  inputs.llama-cpp.url = "github:ggml-org/llama.cpp/571d0d540df04f25298d0e159e520d9fc62ed121";

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

      cuda = llamaPackagesCuda.llama-cpp.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./fattn-graph-reuse-fix.patch ];
      });
    in
    {
      packages.${system} = llama-cpp.packages.${system} // {
        inherit cuda;
      };
    };
}
