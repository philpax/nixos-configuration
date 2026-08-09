{ config, lib, pkgs, ... }:

# Bigscreen Beyond DSC fixes for the NVIDIA open kernel modules — "rainbow
# static" artifacts and intermittent link training failures. Both of the
# headset's modes use DSC at 8bpp/8bpc (its DisplayID block declares 5088x2544
# @75 and 3840x1920@90 as DSC pass-through), so all three patches are live in
# either mode.
#
# The LVRA wiki calls this nvidia-bsb-dsc-fix.patch; upstream ships it as three
# commits plus a squashed bsb-dsc-fix.patch, which we don't use because the
# middle one needs a version guard. Vendored under ./nvidia-bsb-dsc/ so the GPU
# driver doesn't depend on a third-party repo staying up.
#
#   https://github.com/triple-groove/nvidia-bsb-dsc-fix
let
  base = config.boot.kernelPackages.nvidiaPackages.latest;

  bsbPatches =
    [
      # DSC rate-control tables vs VESA DSC 1.1 Table E-5. The only one of the
      # three with reach beyond this headset: it edits global tables in
      # nvt_dsc_pps.c rather than gating on a device. Narrow in practice — the
      # QP edits are at exactly 8.00bpp/8bpc, and ofs_und8[11] covers 6-12bpp —
      # but not zero, so it would touch another DSC display at that operating
      # point. Nothing else here is one.
      ./nvidia-bsb-dsc/0001-fix-dsc-correct-RC-parameter-tables-to-match-VESA-DS.patch
    ]
    ++
      # flatness_det_thresh computed as 2 << (bitsPerPixelX16 - 8), a shift by
      # ~376 — undefined behaviour, truncating to 0 in a 10-bit field. NVIDIA
      # carried an "XXX: I'm pretty sure that this is wrong." above it and then
      # fixed it themselves in 610, so this stops applying there. Guard it
      # rather than discovering the conflict mid-rebuild after a channel bump.
      lib.optional (lib.versionOlder base.version "610")
        ./nvidia-bsb-dsc/0002-fix-dsc-use-bits_per_component-for-flatnessDetThresh.patch
    ++ [
      # Forces 4 lanes HBR2, gated on EDID 0x2709/0x1234 in the DisplayPort
      # workaround database, so it can't affect any other display. Confirmed to
      # match the 2e: its EDID has 09 27 at bytes 8-9, and getManufId() reads
      # those as (data[9] << 8) | data[8].
      ./nvidia-bsb-dsc/0003-fix-dp-add-Bigscreen-Beyond-VR-headset-to-WAR-databa.patch
    ];
in
{
  # hardware.nvidia.open is set in configuration.nix, so the module builds from
  # `package.open`. Splice a patched derivation into that attribute and leave
  # the rest of the package set (bin, settings, persistenced) alone.
  hardware.nvidia.package = base // {
    open = base.open.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ bsbPatches;
    });
  };
}
