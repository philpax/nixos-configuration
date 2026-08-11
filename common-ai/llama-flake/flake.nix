{
  # Thin wrapper around upstream llama.cpp's own flake. Upstream ships a
  # flake.nix but no flake.lock, so it can't be consumed directly from our
  # channels-based config under pure evaluation. This wrapper pins it (and its
  # transitive inputs) via the committed flake.lock here, and re-exports its
  # packages. Consumed from ../configuration.nix via flake-compat, which
  # calls `lib.${system}.mkCuda` with the consuming machine's own
  # `cudaCapabilities` — there is no capability-agnostic build, and no
  # default here either: building every arch upstream supports drastically
  # inflates compile time, so each machine builds only the arch it actually
  # has.
  #
  # fattn-graph-reuse-fix.patch: fixes a tensor split crash in meta backend
  # shard registration. Applied inside `mkCuda`, so every capability variant
  # gets it.
  #
  # patch-verified-rev: 1138b851fae633e9b2e74db0dac3623b7c6fac43
  #
  # The line above is the last llama-cpp rev this patch was actually
  # confirmed to apply against — kept separate from `inputs.llama-cpp.url`
  # below because ./update.sh moves that rev on every run, but only tests
  # (and advances) patch-verified-rev when the patch still applies cleanly.
  # If the two revs differ, the patch hasn't been re-verified since the last
  # bump: check ./update.sh's output from the last run, or re-run it.
  #
  # The pinned rev is an upstream master commit, not a release tag.
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
  description = "Pinned upstream llama.cpp flake, shared across targets";

  inputs.llama-cpp.url = "github:ggml-org/llama.cpp/1138b851fae633e9b2e74db0dac3623b7c6fac43";

  outputs = { llama-cpp, ... }:
    let
      system = "x86_64-linux";
      lib = llama-cpp.inputs.nixpkgs.lib;

      # Mirror upstream's pkgsCuda instance (.devops/nix/nixpkgs-instances.nix),
      # parameterised by the capability list the caller wants instead of a
      # single hardcoded arch.
      mkCuda = { cudaCapabilities }:
        let
          pkgsCuda = import llama-cpp.inputs.nixpkgs {
            inherit system;
            config.cudaSupport = true;
            config.cudaCapabilities = cudaCapabilities;
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

          # Upstream's package.nix still asks for cudaPackages.cuda_cccl, which the
          # pinned nixpkgs has renamed to cccl and kept only as a warning alias.
          # Resolving it here keeps the eval quiet without touching the pin; the
          # alias returns the same package, so the derivation is unchanged. Drop
          # this once a bumped llama.cpp rev uses the new name.
          cudaPackages = pkgsCuda.cudaPackages // {
            cuda_cccl = pkgsCuda.cudaPackages.cccl;
          };
        in
        (llamaPackagesCuda.llama-cpp.override { inherit cudaPackages; }).overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./fattn-graph-reuse-fix.patch ];
        });
    in
    {
      lib.${system} = { inherit mkCuda; };
      packages.${system} = llama-cpp.packages.${system};
    };
}
