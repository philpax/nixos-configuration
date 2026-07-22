{
  # Thin wrapper around Poolside's llama.cpp fork (laguna branch), mirroring
  # ../ik-llama-flake. The fork carries full Laguna support including DFlash
  # speculative decoding (`--spec-type draft-dflash`); base Laguna support
  # is also in upstream review (ggml-org/llama.cpp#25165) but not yet merged
  # at our pin. See the Laguna S 2.1 GGUF model card for serving details.
  #
  # The fork ships a flake.nix but no flake.lock (same as upstream), so it
  # can't be consumed directly from our channels-based config under pure
  # evaluation. This wrapper pins it (and its transitive inputs) via the
  # committed flake.lock here, and re-exports its packages. Consumed from
  # ../default.nix via flake-compat.
  #
  # The `cuda` package is rebuilt here rather than re-exported so CUDA
  # architectures can be pinned to SM 8.6 (RTX 3090); the fork's flake
  # builds every supported arch, which drastically inflates compile time.
  #
  # isfinite-cmath-include.patch: adds missing `#include <cmath>` for `std::isfinite` in DFlash code.
  # fattn-graph-reuse-fix.patch (shared via ../patches/): fixes tensor split crash in meta backend shard registration. Duplicated in ../llama-flake/ — keep in sync.
  # tensor-split-axis0-fix.patch: allows SUM_ROWS on axis-0 split tensors (AllReduce instead of assert).
  #
  # The rev below is pinned to a fork laguna-branch commit (2026-07-22,
  # 04b2b72c), not a release tag.
  #
  # To move to a newer poolside llama.cpp rev: run ./update.sh [ref] in this
  # directory (defaults to laguna). It resolves the ref, rewrites the rev
  # below, and relocks. Commit this file and the updated flake.lock
  # afterwards. (The rev can't live in a separate file: flake inputs must
  # be literal strings, so readFile-based interpolation is rejected by nix.)
  description = "Pinned Poolside llama.cpp (laguna) flake for redline's AI services";

  inputs.poolside-llama-cpp.url = "github:poolsideai/llama.cpp/04b2b72cb54048ead292884adbe11f284e3ec950";

  outputs = { poolside-llama-cpp, ... }:
    let
      system = "x86_64-linux";
      lib = poolside-llama-cpp.inputs.nixpkgs.lib;

      # Mirror the fork's pkgsCuda instance (.devops/nix/nixpkgs-instances.nix),
      # plus the SM 8.6 specialisation.
      pkgsCuda = import poolside-llama-cpp.inputs.nixpkgs {
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

      llamaPackagesCuda = pkgsCuda.callPackage "${poolside-llama-cpp}/.devops/nix/scope.nix" {
        llamaVersion = "0.0.0";
      };

      cuda = llamaPackagesCuda.llama-cpp.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ./isfinite-cmath-include.patch
          ./fattn-graph-reuse-fix.patch
          ./tensor-split-axis0-fix.patch
        ];
      });
    in
    {
      packages.${system} = poolside-llama-cpp.packages.${system} // {
        inherit cuda;
      };
    };
}
