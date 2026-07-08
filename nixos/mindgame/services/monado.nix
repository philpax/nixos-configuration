{ config, pkgs, ... }:

# Monado OpenXR runtime for the wired Valve Index (Lighthouse tracked).
# Lives alongside services.wivrn (which drives the wireless Quest). Only one
# OpenXR runtime can be "active" at a time — use `vr-mode` to switch between
# them (see vr-mode.nix). Neither service sets defaultRuntime, so nothing
# statically owns /etc/xdg/openxr/1/active_runtime.json and the per-user
# ~/.config override written by `vr-mode` always wins.
{
  services.monado = {
    enable = true;
    defaultRuntime = false;
    highPriority = true;
  };

  systemd.user.services.monado.environment = {
    # Reuse SteamVR's Lighthouse driver for Index tracking (better than
    # libsurvive). Requires SteamVR installed via Steam and Room Setup run once
    # for floor height.
    STEAMVR_LH_ENABLE = "true";

    # Nvidia + Wayland: Monado otherwise picks its Nvidia/Xlib direct backend,
    # whose vkAcquireXlibDisplayEXT can't lease the HMD panel from niri (the DRM
    # master) and fails with VK_ERROR_UNKNOWN. Forcing the Wayland-direct backend
    # makes Monado acquire the Index via niri's wp_drm_lease protocol instead,
    # which works. niri offers the Index as a non-desktop leasable connector.
    XRT_COMPOSITOR_FORCE_WAYLAND_DIRECT = "1";
  };

  # OpenVR -> OpenXR shim so SteamVR-only games (VRChat, Resonite, ...) run on
  # Monado. From nixpkgs-xr (see ../nixpkgs-xr.nix).
  environment.systemPackages = [ pkgs.xrizer ];
}
