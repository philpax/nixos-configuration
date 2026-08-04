{ config, pkgs, ... }:

# Monado OpenXR runtime for the wired Lighthouse headsets — Valve Index and
# Bigscreen Beyond 2e.
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

    # The Lighthouse driver only registers devices that announce themselves
    # inside this window; anything later is dropped with "Cannot add device
    # after setup". At the 3000ms default a base station regularly missed the
    # cutoff, leaving Monado tracking off a single station. Widen it — the cost
    # is a few extra seconds of startup, which vr-mode already waits out.
    LH_DISCOVER_WAIT_MS = "6000";

    # Nvidia + Wayland: Monado otherwise picks its Nvidia/Xlib direct backend,
    # whose vkAcquireXlibDisplayEXT can't lease the HMD panel from niri (the DRM
    # master) and fails with VK_ERROR_UNKNOWN. Forcing the Wayland-direct backend
    # makes Monado acquire the Index via niri's wp_drm_lease protocol instead,
    # which works. niri offers the Index as a non-desktop leasable connector.
    XRT_COMPOSITOR_FORCE_WAYLAND_DIRECT = "1";

    # Defaults to false, in which case teardown only Deactivate()s the headset
    # and leaves the panels lit and warm. EnterStandby is what powers them down.
    LH_STANDBY_ON_EXIT = "1";
  };

  # Per-run overrides written by `vr-mode` (connector, IPD, ...). systemd applies
  # EnvironmentFile= after Environment=, so these beat the defaults above.
  # Leading `-` so a missing file — the normal case — isn't an error.
  systemd.user.services.monado.serviceConfig.EnvironmentFile = [ "-%t/vr-mode.env" ];

  # Bigscreen Beyond device access, for SteamVR's lighthouse driver, the Beyond
  # Utility under Proton, and Baballonia. Vendor-wide because the headset moves
  # between product IDs: 0101 headset / 4004 firmware / 1001 error / 0202 Bigeye
  # / 0282 Bigeye DFU / 0105 audio strap. The usb rule isn't redundant with the
  # hidraw one — /dev/bus/usb/... is 0664 root:root with no uaccess ACL, so
  # anything going through libusb rather than hidraw can read but not write.
  # `wheel` because common-all lists plugdev but no such group exists here.
  services.udev.extraRules = ''
    KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="35bd", MODE="0660", GROUP="wheel"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="35bd", MODE="0660", GROUP="wheel"
  '';

  # OpenVR -> OpenXR shim so SteamVR-only games (VRChat, Resonite, ...) run on
  # Monado. From nixpkgs-xr (see ../nixpkgs-xr.nix).
  environment.systemPackages = [ pkgs.xrizer ];

  # Make *every* OpenVR game route through xrizer -> OpenXR -> the active runtime
  # (monado/wivrn) with no per-game launch options. Two env vars, set session-wide
  # so Steam and every Proton game inherit them:
  #
  #   VR_OVERRIDE  — points Proton's OpenVR bridge straight at xrizer. This is the
  #     piece that actually works under the Steam Linux Runtime (sniper) container:
  #     Proton doesn't resolve our /nix/store xrizer path from openvrpaths.vrpath
  #     inside the container, but it honours VR_OVERRIDE from the environment.
  #     xrizer still requires a valid openvrpaths.vrpath to exist (vr-mode writes
  #     one) even though it isn't listed there. Interpolated from pkgs.xrizer, so
  #     it always tracks the current build — no stale path, no GC breakage.
  #
  #   PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES — imports the active OpenXR runtime
  #     into the sniper container so xrizer (and native-OpenXR games) can reach
  #     monado/wivrn. Previously set per-game in VRChat's launch options; global
  #     here so it covers everything.
  environment.sessionVariables = {
    VR_OVERRIDE = "${pkgs.xrizer}/lib/xrizer";
    PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES = "1";
  };
}
