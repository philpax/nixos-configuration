# Shared NVIDIA driver package for machines that set videoDrivers = ["nvidia"].
# Machines add open-module patches via philpax.nvidia.extraOpenPatches rather
# than overriding hardware.nvidia.package themselves.
{ config, lib, ... }:

let
  cfg = config.philpax.nvidia;
  base = config.boot.kernelPackages.nvidiaPackages.latest;

  # Linux 7.2 dropped strncpy and renamed drm_atomic_state; nvidia-all's patch
  # applies cleanly to 595.71.05. Inert on older kernels.
  #   https://github.com/Frogging-Family/nvidia-all/blob/master/nvidia-all-patches/610/kernel-7.2.patch
  kernel7_2Patch =
    lib.optional (lib.versionAtLeast config.boot.kernelPackages.kernel.version "7.2")
      ./nvidia/kernel-7.2.patch;
in
{
  options.philpax.nvidia = {
    extraOpenPatches = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = "Extra patches for the NVIDIA open kernel modules, applied after the shared kernel-compat patches.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = base;
      description = "The unpatched driver package, for version guards on machine-specific patches.";
    };
  };

  config.hardware.nvidia.package = base // {
    open = base.open.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ kernel7_2Patch ++ cfg.extraOpenPatches;
    });
  };
}
