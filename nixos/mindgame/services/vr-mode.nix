{ config, pkgs, ... }:

# `vr-mode` — pick which OpenXR runtime is active, and set up the headset for
# it. See vr-mode.py for what each mode does; this file only supplies the store
# paths and the handful of machine-specific constants.
#
#   vr-mode index    # Valve Index via Monado (+ WayVR desktop overlay)
#   vr-mode beyond   # Bigscreen Beyond 2e via Monado (+ WayVR)
#   vr-mode wivrn    # Quest via WiVRn (WiVRn launches its own WayVR)
#   vr-mode off      # stop everything, no runtime active
#   vr-mode quiesce  # wake headsets just long enough to tell them to sleep
#   vr-mode status   # show current runtime + service state
#   vr-mode fan N    # set the Beyond's fan directly
#   vr-mode telemetry [secs]  # watch the Beyond's status reports
let
  # LÖVR OpenXR overlay that flashes the current IPD in-view when it changes.
  ipdOverlay = pkgs.runCommand "vr-ipd-overlay" { } ''
    mkdir -p $out
    cp ${./vr-ipd-overlay/conf.lua} $out/conf.lua
    cp ${./vr-ipd-overlay/main.lua} $out/main.lua
  '';

  # Config is handed to the script through the environment rather than
  # substituted into it, so vr-mode.py stays a plain, runnable file.
  wrapperEnv = {
    MONADO_JSON = "${config.services.monado.package}/share/openxr/1/openxr_monado.json";
    WIVRN_JSON = "${config.services.wivrn.package}/share/openxr/1/openxr_wivrn.json";
    WAYVR = "${pkgs.wayvr}/bin/wayvr";
    IPD_LAUNCHER = "${pkgs.lovr}/bin/lovr ${ipdOverlay}";

    # xrizer's OpenVR runtime dir (contains bin/linux64/vrclient.so). Pinned to
    # the built package so the path stays valid across nix-collect-garbage — a
    # hand-written openvrpaths.vrpath pointing at an ephemeral store path
    # silently rots when that path is GC'd.
    XRIZER_RUNTIME = "${pkgs.xrizer}/lib/xrizer";

    # Defaults live in vr-mode.py; these are the authoritative values.
    BEYOND_IPD_MM = 68.3;

    FAN_IDLE = 40;   # Beyond not in use, but still powered
    FAN_ACTIVE = 70; # on a face
  };

  unwrapped = pkgs.writers.writePython3Bin "vr-mode-unwrapped"
    { flakeIgnore = [ "E501" ]; } (builtins.readFile ./vr-mode.py);

  vr-mode = pkgs.runCommand "vr-mode"
    { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
      makeWrapper ${unwrapped}/bin/vr-mode-unwrapped $out/bin/vr-mode \
        --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.systemd pkgs.pulseaudio ]} \
        ${pkgs.lib.concatStringsSep " \\\n    "
          (pkgs.lib.mapAttrsToList (k: v: ''--set VR_MODE_${k} "${toString v}"'') wrapperEnv)}
    '';

in
{
  # lovr is also exposed directly so the overlay can be run/tweaked by hand.
  environment.systemPackages = [ vr-mode pkgs.lovr ];

  # Without this a wired headset spends the whole session lit and warm: nothing
  # ever activates it, so nothing ever tears it down. Costs a few seconds and a
  # flash of the panels, since the driver offers no way to reach standby without
  # activating the device first.
  systemd.user.services.vr-quiesce = {
    description = "Put idle VR headsets to sleep";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${vr-mode}/bin/vr-mode quiesce";
    };
  };
}
