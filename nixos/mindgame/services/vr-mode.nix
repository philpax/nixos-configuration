{ config, pkgs, ... }:

# `vr-mode` — pick which OpenXR runtime is active. Nothing runs at startup
# (wivrn autoStart is off, monado is socket-activated); this is how you turn a
# runtime on and off, so exactly one — or neither — is ever active.
#
#   vr-mode index    # Valve Index via Monado (+ WayVR desktop overlay)
#   vr-mode beyond   # Bigscreen Beyond 2e via Monado (+ WayVR)
#   vr-mode wivrn    # Quest via WiVRn (WiVRn launches its own WayVR)
#   vr-mode off      # stop everything, no runtime active
#   vr-mode quiesce  # wake headsets just long enough to tell them to sleep
#   vr-mode status   # show current runtime + service state
#
# Switching sets the per-user active_runtime.json (~/.config wins over /etc/xdg)
# and starts the matching service, stopping the other so they never fight over
# the runtime slot or the headset.
let
  monadoJson = "${config.services.monado.package}/share/openxr/1/openxr_monado.json";
  wivrnJson = "${config.services.wivrn.package}/share/openxr/1/openxr_wivrn.json";
  wayvr = "${pkgs.wayvr}/bin/wayvr";

  # xrizer's OpenVR runtime dir (contains bin/linux64/vrclient.so). Pinned to the
  # built package so the path stays valid across nix-collect-garbage — a
  # hand-written openvrpaths.vrpath pointing at an ephemeral store path silently
  # rots when that path is GC'd.
  xrizerRuntime = "${pkgs.xrizer}/lib/xrizer";

  # LÖVR OpenXR overlay that flashes the current IPD in-view when it changes.
  ipdOverlay = pkgs.runCommand "vr-ipd-overlay" { } ''
    mkdir -p $out
    cp ${./vr-ipd-overlay/conf.lua} $out/conf.lua
    cp ${./vr-ipd-overlay/main.lua} $out/main.lua
  '';
  ipdLauncher = "${pkgs.lovr}/bin/lovr ${ipdOverlay}";

  # The Beyond 2e's lenses are positioned by hand with a hex tool and there's no
  # encoder behind them, so Monado has no way to discover the IPD — it has to be
  # told. Update this if you move the lenses.
  beyondIpdMm = "68.3";

  # The Beyond's DisplayPort connector. Only load-bearing when the Index is
  # plugged in alongside it: Monado otherwise leases "the first available
  # connector", which with two headsets attached is a coin flip.
  beyondConnector = "DP-2";

  vr-mode = pkgs.writeShellApplication {
    name = "vr-mode";
    runtimeInputs = [ pkgs.systemd pkgs.coreutils pkgs.gnugrep pkgs.pulseaudio ];
    text = ''
      active="''${XDG_CONFIG_HOME:-$HOME/.config}/openxr/1/active_runtime.json"

      # Per-run overrides for monado.service, via its EnvironmentFile drop-in
      # (see monado.nix). Every mode rewrites or removes this, so one run's
      # overrides can't leak into the next.
      env_file="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vr-mode.env"
      write_env() {
        : > "$env_file"
        for kv in "$@"; do printf '%s\n' "$kv" >> "$env_file"; done
      }

      # The Index takes audio over the GPU's DisplayPort link, not USB. That
      # output is only exposed once the GB202's audio card is in its "Pro Audio"
      # profile, where the HMD panel's PCM shows up as the "Pro 8" sink
      # (pro-output-8). See https://wiki.vronlinux.org/docs/hardware/#valve-index-quirks
      index_card="alsa_card.pci-0000_01_00.1"
      index_sink="alsa_output.pci-0000_01_00.1.pro-output-8"
      prev_sink_file="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vr-mode.prev-sink"

      # The strap is an ordinary USB audio device, so none of the Index's
      # DisplayPort/pro-audio machinery applies. Prefix-matched because the node
      # name is generated from the USB descriptors.
      beyond_sink_prefix="alsa_output.usb-Bigscreen_Beyond_Audio_Strap"

      # Remember the current default sink, unless we're already pointed at the
      # headset, so off/wivrn can put it back.
      remember_sink() {
        local cur
        cur=$(pactl get-default-sink 2>/dev/null || true)
        if [ -n "$cur" ] && [ "$cur" != "$1" ]; then
          printf '%s\n' "$cur" > "$prev_sink_file"
        fi
      }

      # Route default audio to the Index panel.
      index_audio_on() {
        local routed=0
        remember_sink "$index_sink"
        pactl set-card-profile "$index_card" pro-audio 2>/dev/null \
          || echo "vr-mode: could not put $index_card into pro-audio" >&2
        # The Pro 8 sink can take a beat to register after a profile change.
        for _ in 1 2 3 4 5; do
          if pactl set-default-sink "$index_sink" 2>/dev/null; then routed=1; break; fi
          sleep 0.3
        done
        if [ "$routed" = 1 ]; then
          echo "vr-mode: audio routed to Index (Pro 8)"
        else
          echo "vr-mode: Index sink $index_sink not available" >&2
        fi
      }

      # Route default audio to the Beyond's audio strap.
      beyond_audio_on() {
        local sink
        sink=$(pactl list short sinks 2>/dev/null | grep -m1 "$beyond_sink_prefix" | cut -f2 || true)
        if [ -z "$sink" ]; then
          echo "vr-mode: Beyond audio strap sink not found (is the strap attached?)" >&2
          return
        fi
        remember_sink "$sink"
        if pactl set-default-sink "$sink" 2>/dev/null; then
          echo "vr-mode: audio routed to Beyond audio strap"
        else
          echo "vr-mode: could not route audio to $sink" >&2
        fi
      }

      # Shared by both headsets; the card-profile reset is a no-op when the
      # Index isn't the one in use.
      audio_off() {
        if [ -f "$prev_sink_file" ]; then
          local prev; prev=$(cat "$prev_sink_file")
          if [ -n "$prev" ]; then pactl set-default-sink "$prev" 2>/dev/null || true; fi
          rm -f "$prev_sink_file"
        fi
        pactl set-card-profile "$index_card" off 2>/dev/null || true
      }

      # SteamVR-only games (VRChat, Resonite, ...) reach VR through the OpenVR
      # API, which resolves its runtime from openvrpaths.vrpath. Point that at
      # xrizer (the OpenVR -> OpenXR shim) so those games route through whichever
      # OpenXR runtime is active (monado/wivrn) instead of launching SteamVR —
      # SteamVR can't lease the Index panel out from under monado, so the game
      # would drop to flatscreen. SteamVR rewrites this file and re-registers
      # itself as the first runtime whenever it runs, so we (re)assert xrizer as
      # the sole runtime on every activation rather than trusting it to stick.
      write_openvrpaths() {
        local steam="$HOME/.local/share/Steam"
        local f="''${XDG_CONFIG_HOME:-$HOME/.config}/openvr/openvrpaths.vrpath"
        mkdir -p "$(dirname "$f")"
        printf '{\n\t"config" : [ "%s/config" ],\n\t"external_drivers" : null,\n\t"jsonid" : "vrpathreg",\n\t"log" : [ "%s/logs" ],\n\t"runtime" : [ "%s" ],\n\t"version" : 1\n}\n' \
          "$steam" "$steam" "${xrizerRuntime}" > "$f"
        echo "vr-mode: openvrpaths -> xrizer (OpenVR games route through OpenXR)"
      }

      # Stop the socket too, so nothing socket-activates monado while it's meant
      # to be off / while WiVRn is active.
      stop_monado() { systemctl --user stop monado.service monado.socket 2>/dev/null || true; }
      stop_wivrn()  { systemctl --user stop wivrn.service  2>/dev/null || true; }
      # WayVR + the IPD overlay run as transient user units so we can stop them cleanly.
      stop_wayvr()  { systemctl --user stop vr-wayvr.service 2>/dev/null || true; }
      stop_ipd()    { systemctl --user stop vr-ipd-overlay.service 2>/dev/null || true; }
      # The login-time quiesce holds monado briefly; don't race it.
      stop_quiesce() { systemctl --user stop vr-quiesce.service 2>/dev/null || true; }

      # Monado needs several seconds to probe Lighthouse devices and lease the
      # headset panel before it accepts OpenXR clients, and it stays
      # systemd-active even when the compositor fails (IPC_EXIT_ON_DISCONNECT=off)
      # — so is-active is not a readiness signal. Poll this run's journal for the
      # compositor-up marker, bailing early on the failure markers.
      monado_ready() {
        local inv log
        inv=$(systemctl --user show -p InvocationID --value monado.service 2>/dev/null)
        for _ in $(seq 1 40); do
          log=$(journalctl --user -u monado.service _SYSTEMD_INVOCATION_ID="$inv" --no-pager 2>/dev/null)
          if printf '%s' "$log" | grep -q "Started vblank event thread"; then return 0; fi
          if printf '%s' "$log" | grep -qE "create_system failed|Failed to init compositor"; then return 1; fi
          sleep 0.5
        done
        return 1
      }

      # Bring monado up and wait until it's actually usable. The SteamVR-LH
      # driver intermittently fails device creation, so retry; each attempt
      # starts from a clean socket, because a stale/unlinked monado_comp_ipc
      # (e.g. from an unclean exit) leaves the unit "active" while clients get
      # ENOENT, which a plain restart wouldn't recover from.
      start_monado() {
        local attempt
        for attempt in 1 2 3; do
          systemctl --user stop monado.service monado.socket 2>/dev/null || true
          systemctl --user reset-failed monado.service monado.socket 2>/dev/null || true
          rm -f "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/monado_comp_ipc" 2>/dev/null || true
          systemctl --user start monado.service
          if monado_ready; then return 0; fi
          echo "vr-mode: monado init failed (attempt $attempt/3), retrying..." >&2
          sleep 2
        done
        return 1
      }

      # Monado has no built-in app launcher, so bring up the WayVR desktop
      # overlay ourselves — otherwise the headset is a black void. (WiVRn starts
      # its own, which is why the wivrn path doesn't call this.)
      start_wayvr() {
        systemctl --user reset-failed vr-wayvr.service 2>/dev/null || true
        systemd-run --user --unit=vr-wayvr --collect -- "${wayvr}"
      }

      # Without this, quiesce spins monado up at every login only to time out
      # when nothing is plugged in. The Index HMD and its controllers share
      # 28de:2300, so the product string is what tells them apart; the Beyond is
      # matched on vendor alone, since it moves between product IDs.
      hmd_present() {
        local d vid prod
        for d in /sys/bus/usb/devices/*; do
          [ -r "$d/idVendor" ] || continue
          vid=$(cat "$d/idVendor")
          prod=$(cat "$d/product" 2>/dev/null || true)
          case "$vid:$prod" in
            "28de:Index HMD") return 0 ;;
            35bd:*)           return 0 ;;
          esac
        done
        return 1
      }

      case "''${1:-status}" in
        index)
          stop_quiesce; stop_wivrn; stop_wayvr; stop_ipd
          write_env   # no overrides: use monado.service's own environment
          mkdir -p "$(dirname "$active")"
          ln -sf "${monadoJson}" "$active"
          write_openvrpaths
          if ! start_monado; then
            echo "vr-mode: monado could not bring up the Index." >&2
            echo "  check: journalctl --user -u monado.service -e" >&2
            exit 1
          fi
          start_wayvr
          # IPD heads-up overlay (LÖVR, composites on top of WayVR). Index-only:
          # it exists to surface changes in the motorised IPD, and the Beyond's
          # is a fixed mechanical setting with nothing to report.
          systemctl --user reset-failed vr-ipd-overlay.service 2>/dev/null || true
          systemd-run --user --unit=vr-ipd-overlay --collect -- ${ipdLauncher}
          index_audio_on
          echo "vr-mode: index (monado) active, WayVR + IPD overlay launched"
          ;;
        beyond)
          stop_quiesce; stop_wivrn; stop_wayvr; stop_ipd
          write_env \
            "XRT_COMPOSITOR_WAYLAND_CONNECTOR=${beyondConnector}" \
            "LH_OVERRIDE_IPD_MM=${beyondIpdMm}"
          mkdir -p "$(dirname "$active")"
          ln -sf "${monadoJson}" "$active"
          write_openvrpaths
          if ! start_monado; then
            echo "vr-mode: monado could not bring up the Beyond." >&2
            echo "  check: journalctl --user -u monado.service -e" >&2
            exit 1
          fi
          start_wayvr
          beyond_audio_on
          echo "vr-mode: beyond (monado) active, WayVR launched"
          ;;
        wivrn)
          stop_quiesce; stop_monado
          stop_wayvr; stop_ipd   # WiVRn launches its own WayVR on session start
          audio_off              # Quest uses its own audio; give the desktop sink back
          mkdir -p "$(dirname "$active")"
          ln -sf "${wivrnJson}" "$active"
          write_openvrpaths
          systemctl --user start wivrn.service
          echo "vr-mode: wivrn (quest) active"
          ;;
        off)
          stop_quiesce; stop_monado; stop_wivrn; stop_wayvr; stop_ipd
          audio_off
          rm -f "$active" "$env_file"
          echo "vr-mode: all runtimes stopped"
          ;;
        quiesce)
          # A wired Lighthouse HMD powers its panels on by default and is only
          # ever told to sleep when the driver tears the device down. Nothing
          # activates it at boot, so it sits lit, black and warm until the first
          # `vr-mode index` ... `vr-mode off` cycle. Do that cycle once at login
          # so it starts the day asleep.
          #
          # Lighter than a real session: no WayVR, no IPD overlay, no audio, no
          # active_runtime change. Still waits for full readiness before
          # stopping, though — tearing down on the earlier "Found lighthouse
          # HMD" marker raced Context::create and segfaulted driver_lighthouse,
          # which left the panels lit anyway.
          if [ "$(systemctl --user is-active monado.service 2>/dev/null || true)" = active ] \
            || [ "$(systemctl --user is-active wivrn.service 2>/dev/null || true)" = active ]; then
            echo "vr-mode: a runtime is already active, nothing to quiesce"
            exit 0
          fi
          if ! hmd_present; then
            echo "vr-mode: no wired HMD attached, nothing to quiesce"
            exit 0
          fi
          # Base stations don't matter here, only that the HMD announces itself,
          # so don't sit through the widened discovery window.
          write_env "LH_DISCOVER_WAIT_MS=1500"
          systemctl --user reset-failed monado.service monado.socket 2>/dev/null || true
          systemctl --user start monado.service
          if monado_ready; then
            echo "vr-mode: headset up, putting it back to sleep"
          else
            # Still tear down — if a device was created late we want it asleep,
            # and if none was there's nothing lit to worry about either way.
            echo "vr-mode: no headset activated during quiesce" >&2
          fi
          stop_monado
          rm -f "$env_file"
          # stop_monado takes the socket down with the service; put it back so
          # the session returns to its normal idle, socket-activated state.
          systemctl --user start monado.socket 2>/dev/null || true
          ;;
        status)
          if [ -L "$active" ] || [ -e "$active" ]; then
            case "$(readlink -f "$active" || echo "$active")" in
              # Both headsets run on monado, so the runtime symlink alone can't
              # tell them apart — the per-run env file is what distinguishes them.
              *openxr_monado.json)
                if grep -q "${beyondConnector}" "$env_file" 2>/dev/null; then
                  echo "active runtime: beyond (monado)"
                else
                  echo "active runtime: index (monado)"
                fi
                ;;
              *openxr_wivrn.json)  echo "active runtime: wivrn (quest)"  ;;
              *) echo "active runtime: unknown" ;;
            esac
          else
            echo "active runtime: none"
          fi
          echo "  monado.service:        $(systemctl --user is-active monado.service 2>/dev/null || true)"
          echo "  wivrn.service:         $(systemctl --user is-active wivrn.service 2>/dev/null || true)"
          echo "  vr-wayvr.service:      $(systemctl --user is-active vr-wayvr.service 2>/dev/null || true)"
          echo "  vr-ipd-overlay.service:$(systemctl --user is-active vr-ipd-overlay.service 2>/dev/null || true)"
          echo "  default sink:          $(pactl get-default-sink 2>/dev/null || echo unknown)"
          ;;
        *)
          echo "usage: vr-mode {index|beyond|wivrn|off|quiesce|status}" >&2
          exit 2
          ;;
      esac
    '';
  };
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
