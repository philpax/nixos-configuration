# Shared NVIDIA driver package for machines that set videoDrivers = ["nvidia"].
# Machines add open-module patches via philpax.nvidia.extraOpenPatches rather
# than overriding hardware.nvidia.package themselves.
{ config, lib, ... }:

let
  cfg = config.philpax.nvidia;
  base = config.boot.kernelPackages.nvidiaPackages.latest;

  # Linux 7.2 renamed drm_atomic_state and removed strncpy. The drm shim is
  # needed on every driver; the strncpy replacements only on open modules older
  # than 595.112.07. Those still call strncpy (nvkms_strncpy,
  # nvswitch_os_strncpy, os_get_current_process_name and the UVM chunk cache),
  # while 595.112.07 already uses strscpy/snprintf and refuses the hunks.
  # Both patches are inert before kernel 7.2.
  #   https://github.com/Frogging-Family/nvidia-all/blob/master/nvidia-all-patches/610/kernel-7.2.patch
  linux7_2 = lib.versionAtLeast config.boot.kernelPackages.kernel.version "7.2";
  kernel7_2Patch =
    lib.optional linux7_2 ./nvidia/kernel-7.2.patch;
  kernel7_2StrncpyPatch =
    lib.optional (linux7_2 && lib.versionOlder base.version "595.112.07")
      ./nvidia/kernel-7.2-strncpy.patch;
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
      patches = (old.patches or [ ]) ++ kernel7_2Patch ++ kernel7_2StrncpyPatch ++ cfg.extraOpenPatches;
    });
  };
}
