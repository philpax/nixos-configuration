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

  # LÖVR OpenXR overlay that flashes the current IPD in-view when it changes.
  ipdOverlay = pkgs.runCommand "vr-ipd-overlay" { } ''
    mkdir -p $out
    cp ${./vr-ipd-overlay/conf.lua} $out/conf.lua
    cp ${./vr-ipd-overlay/main.lua} $out/main.lua
  '';
  ipdLauncher = "${pkgs.lovr}/bin/lovr ${ipdOverlay}";

  vr-mode = pkgs.writeShellApplication {
    name = "vr-mode";
    runtimeInputs = [ pkgs.systemd pkgs.coreutils pkgs.gnugrep ];
    text = ''
      active="''${XDG_CONFIG_HOME:-$HOME/.config}/openxr/1/active_runtime.json"

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
          echo "vr-mode: index (monado) active, WayVR + IPD overlay launched"
          ;;
        wivrn)
          stop_monado
          stop_wayvr; stop_ipd   # WiVRn launches its own WayVR on session start
          mkdir -p "$(dirname "$active")"
          ln -sf "${wivrnJson}" "$active"
          systemctl --user start wivrn.service
          echo "vr-mode: wivrn (quest) active"
          ;;
        off)
          stop_monado; stop_wivrn; stop_wayvr; stop_ipd
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
