{ config, pkgs, ... }:

# `vr-mode` — pick which OpenXR runtime is active. Nothing runs at startup
# (wivrn autoStart is off, monado is socket-activated); this is how you turn a
# runtime on and off, so exactly one — or neither — is ever active.
#
#   vr-mode index    # Valve Index via Monado (+ WayVR desktop overlay)
#   vr-mode wivrn    # Quest via WiVRn (WiVRn launches its own WayVR)
#   vr-mode off      # stop everything, no runtime active
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

  vr-mode = pkgs.writeShellApplication {
    name = "vr-mode";
    runtimeInputs = [ pkgs.systemd pkgs.coreutils pkgs.gnugrep pkgs.pulseaudio ];
    text = ''
      active="''${XDG_CONFIG_HOME:-$HOME/.config}/openxr/1/active_runtime.json"

      # The Index takes audio over the GPU's DisplayPort link, not USB. That
      # output is only exposed once the GB202's audio card is in its "Pro Audio"
      # profile, where the HMD panel's PCM shows up as the "Pro 8" sink
      # (pro-output-8). See https://wiki.vronlinux.org/docs/hardware/#valve-index-quirks
      index_card="alsa_card.pci-0000_01_00.1"
      index_sink="alsa_output.pci-0000_01_00.1.pro-output-8"
      prev_sink_file="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vr-mode.prev-sink"

      # Route default audio to the Index panel, remembering what was default so
      # off/wivrn can put it back.
      index_audio_on() {
        local cur routed=0
        cur=$(pactl get-default-sink 2>/dev/null || true)
        # Don't clobber the saved sink if we're already pointed at the Index.
        if [ -n "$cur" ] && [ "$cur" != "$index_sink" ]; then
          printf '%s\n' "$cur" > "$prev_sink_file"
        fi
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

      # Restore the pre-Index default sink and free the GPU audio card again.
      index_audio_off() {
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

      # Monado needs several seconds to probe Lighthouse devices and lease the
      # Index panel before it accepts OpenXR clients, and it stays systemd-active
      # even when the compositor fails (IPC_EXIT_ON_DISCONNECT=off) — so is-active
      # is not a readiness signal. Poll this run's journal for the compositor-up
      # marker, bailing early on the failure marker.
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

      case "''${1:-status}" in
        index)
          stop_wivrn; stop_wayvr; stop_ipd
          mkdir -p "$(dirname "$active")"
          ln -sf "${monadoJson}" "$active"
          write_openvrpaths
          # The SteamVR-LH driver intermittently fails device creation, so retry.
          # Each attempt starts from a clean socket: a stale/unlinked
          # monado_comp_ipc (e.g. from an unclean exit) leaves the unit "active"
          # but clients get ENOENT, so a plain restart wouldn't recover it.
          ok=0
          for attempt in 1 2 3; do
            systemctl --user stop monado.service monado.socket 2>/dev/null || true
            systemctl --user reset-failed monado.service monado.socket 2>/dev/null || true
            rm -f "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/monado_comp_ipc" 2>/dev/null || true
            systemctl --user start monado.service
            if monado_ready; then ok=1; break; fi
            echo "vr-mode: monado init failed (attempt $attempt/3), retrying..." >&2
            sleep 2
          done
          if [ "$ok" != 1 ]; then
            echo "vr-mode: monado could not bring up the Index." >&2
            echo "  check: journalctl --user -u monado.service -e" >&2
            exit 1
          fi
          # Monado has no built-in app launcher; bring up the WayVR desktop
          # overlay ourselves so the Index isn't a black void (mirrors WiVRn).
          systemctl --user reset-failed vr-wayvr.service 2>/dev/null || true
          systemd-run --user --unit=vr-wayvr --collect -- "${wayvr}"
          # IPD heads-up overlay (LÖVR, composites on top of WayVR).
          systemctl --user reset-failed vr-ipd-overlay.service 2>/dev/null || true
          systemd-run --user --unit=vr-ipd-overlay --collect -- ${ipdLauncher}
          index_audio_on
          echo "vr-mode: index (monado) active, WayVR + IPD overlay launched"
          ;;
        wivrn)
          stop_monado
          stop_wayvr; stop_ipd   # WiVRn launches its own WayVR on session start
          index_audio_off        # Quest uses its own audio; give the desktop sink back
          mkdir -p "$(dirname "$active")"
          ln -sf "${wivrnJson}" "$active"
          write_openvrpaths
          systemctl --user start wivrn.service
          echo "vr-mode: wivrn (quest) active"
          ;;
        off)
          stop_monado; stop_wivrn; stop_wayvr; stop_ipd
          index_audio_off
          rm -f "$active"
          echo "vr-mode: all runtimes stopped"
          ;;
        status)
          if [ -L "$active" ] || [ -e "$active" ]; then
            case "$(readlink -f "$active" || echo "$active")" in
              *openxr_monado.json) echo "active runtime: index (monado)" ;;
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
          echo "usage: vr-mode {index|wivrn|off|status}" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  # lovr is also exposed directly so the overlay can be run/tweaked by hand.
  environment.systemPackages = [ vr-mode pkgs.lovr ];
}
