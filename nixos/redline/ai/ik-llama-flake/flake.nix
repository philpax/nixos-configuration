{
  # Thin wrapper around ik_llama.cpp's flake, mirroring ../llama-flake.
  # ik_llama.cpp (ikawrakow's fork) forked llama.cpp's flake structure, so
  # the same wrapper approach applies: it ships a flake.nix but no
  # flake.lock, so it can't be consumed directly from our channels-based
  # config under pure evaluation. This wrapper pins it (and its transitive
  # inputs) via the committed flake.lock here, and re-exports its packages.
  # Consumed from ../default.nix via flake-compat.
  #
  # The `cuda` package is rebuilt here rather than re-exported so CUDA
  # architectures can be pinned to SM 8.6 (RTX 3090); the fork's flake
  # builds every supported arch, which drastically inflates compile time.
  #
  # Why the fork exists alongside mainline: CPU-optimised kernels for
  # IQ/KT/KS quants (row-interleaved repacking, `-rtr`), plus glm-dsa
  # features mainline lacks as of 2026-07: MTP speculative decoding
  # (`--spec-type mtp:...`), the DSA sparse-attention path (`-dsa -fidx`),
  # and `-sm graph` multi-GPU graph parallelism. Serves the GLM-5.2
  # hybrid setup; see /mnt/ssd0/ai/llm/unsloth/GLM-5.2-GGUF/bench/TRIALS.md.
  #
  # The rev below is pinned to a fork master commit (2026-07-18, 9d07d868),
  # not a release tag.
  #
  # To move to a newer ik_llama.cpp rev: run ./update.sh [ref] in this
  # directory (defaults to main). It resolves the ref, rewrites the rev
  # below, and relocks. Commit this file and the updated flake.lock
  # afterwards. (The rev can't live in a separate file: flake inputs must
  # be literal strings, so readFile-based interpolation is rejected by nix.)
  description = "Pinned ik_llama.cpp flake for redline's AI services";

  inputs.ik-llama-cpp.url = "github:ikawrakow/ik_llama.cpp/9d07d8681ece159a89fb4e16a1f9c9f3a5fac20f";

  outputs = { ik-llama-cpp, ... }:
    let
      system = "x86_64-linux";
      lib = ik-llama-cpp.inputs.nixpkgs.lib;

      # Mirror the fork's pkgsCuda instance (.devops/nix/nixpkgs-instances.nix),
      # plus the SM 8.6 specialisation.
      pkgsCuda = import ik-llama-cpp.inputs.nixpkgs {
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

      llamaPackagesCuda = pkgsCuda.callPackage "${ik-llama-cpp}/.devops/nix/scope.nix" {
        llamaVersion = "0.0.0";
      };

      cuda = llamaPackagesCuda.llama-cpp;
    in
    {
      packages.${system} = ik-llama-cpp.packages.${system} // {
        inherit cuda;
      };
    };
}
