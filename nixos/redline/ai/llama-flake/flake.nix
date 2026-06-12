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
  #   2. fattn-graph-reuse-fix.patch (experimental, local-only): ownership
  #      refactor of the meta backend's external-view shard registrations
  #      (per-instance containers, lazy registration, scratch shards) fixing
  #      reused compute graphs executing foreign/stale K/V cache views under
  #      Gemma 4 MTP + -sm tensor (fattn.cu abort or silent corruption;
  #      upstream issues #24324/#24440, PR #24411 insufficient). Includes a
  #      diagnostic canary on the fattn abort path. Full investigation:
  #      /mnt/ssd0/ai/llm/unsloth/gemma-4-31B-it-qat-GGUF/bench/TRIALS.md.
  #      Drop the patch once upstream fixes graph reuse properly.
  #
  # The rev below is pinned to the upstream master commit the patch was
  # developed against (post-b9596, includes PR #24411), not a release tag.
  #
  # Note: NCCL was evaluated 2026-06-11 (add cudaPackages.nccl to the
  # llama-cpp buildInputs + LD_LIBRARY_PATH=/run/opengl-driver/lib for NVML)
  # and measured ~4% SLOWER than llama.cpp's internal AllReduce for 2-GPU
  # tensor split over PCIe — deliberately not enabled. See TRIALS.md above.
  #
  # To move to a newer llama.cpp rev: change the rev below (re-check that
  # fattn-graph-reuse-fix.patch still applies!), then run
  #   nix flake update llama-cpp
  # in this directory and commit the updated flake.lock.
  description = "Pinned upstream llama.cpp flake for redline's AI services";

  inputs.llama-cpp.url = "github:ggml-org/llama.cpp/ebc10770ac5a9331824c53ef0c6adad780904dc3";

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
