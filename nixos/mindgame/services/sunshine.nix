{ config, pkgs, unstable, ... }:
let
  # Pinned to the head of nixpkgs PR #521906, which updates sunshine to
  # 2026.516.143833 (adapting to upstream's FFmpeg/Boost packaging refactor).
  # https://github.com/NixOS/nixpkgs/pull/521906
  # TODO: once that PR merges, drop this pin and switch back to
  # `unstable.sunshine.override` (and remove the deadline assertion below).
  sunshinePkgs = import
    (builtins.fetchTarball https://github.com/Qubasa/nixpkgs/tarball/9672041e168ea7e431074220bb71920ddbe4106d)
    { config = config.nixpkgs.config; };

  # If the PR hasn't merged by this date, fail the rebuild so we re-check
  # rather than silently squatting on a stale fork commit forever.
  sunshinePrDeadline = 1780272000; # 2026-06-01 UTC

  # Monitor description format matches `make model serial` from
  # `niri msg --json outputs`, same pattern as wayland-autostart.sh.
  monitorDesc = "Microstep MSI MAG342CQR DB6H261C01393";

  # Resolves the MSI ultrawide's current DRM connector via niri IPC and
  # rewrites ~/.config/sunshine/sunshine.conf's output_name if it has drifted.
  # Wayland's xdg_output `name` (the connector, e.g. DP-1) is what sunshine's
  # wlgrab backend matches against, but DRM connectors can renumber across
  # reboots — the monitor description (make/model/serial) is the stable key.
  # Invoked from wayland-autostart.sh; also runnable standalone for testing.
  sunshinePinOutput = pkgs.writeShellApplication {
    name = "sunshine-pin-output";
    runtimeInputs = with pkgs; [ niri jq gnused coreutils systemd ];
    text = ''
      MONITOR_DESC="${monitorDesc}"
      SUNSHINE_CONF="$HOME/.config/sunshine/sunshine.conf"

      conn=$(niri msg --json outputs | jq -r --arg d "$MONITOR_DESC" '
        to_entries[]
        | select("\(.value.make) \(.value.model) \(.value.serial)" == $d)
        | .key
      ')
      if [ -z "$conn" ]; then
        echo "sunshine-pin-output: could not resolve '$MONITOR_DESC' via niri" >&2
        exit 0
      fi

      desired="output_name = $conn"
      current=""
      if [ -f "$SUNSHINE_CONF" ]; then
        current=$(grep -E '^output_name = ' "$SUNSHINE_CONF" || true)
      fi
      if [ "$current" = "$desired" ]; then
        echo "sunshine-pin-output: already pinned to $conn"
        exit 0
      fi

      mkdir -p "$(dirname "$SUNSHINE_CONF")"
      if [ -f "$SUNSHINE_CONF" ] && grep -qE '^output_name = ' "$SUNSHINE_CONF"; then
        sed -i "s|^output_name = .*|$desired|" "$SUNSHINE_CONF"
      else
        printf '%s\n' "$desired" >> "$SUNSHINE_CONF"
      fi
      echo "sunshine-pin-output: set output_name to $conn; restarting sunshine"
      systemctl --user restart sunshine
    '';
  };

  sunshineGamescopeStream = pkgs.writeShellApplication {
    name = "sunshine-gamescope-stream";
    runtimeInputs = with pkgs; [
      niri
      jq
      gawk
      gamescope
      procps
      coreutils
      prismlauncher
    ];
    text = ''
      MONITOR_DESC="${monitorDesc}"
      TARGET_W=2560
      TARGET_H=1440
      STATE_FILE="/tmp/sunshine-gamescope-stream.prev-mode"

      # --- mode-switch helpers ---

      resolve_connector() {
        niri msg --json outputs | jq -r --arg d "$MONITOR_DESC" '
          to_entries[]
          | select("\(.value.make) \(.value.model) \(.value.serial)" == $d)
          | .key
        '
      }

      format_mode() {
        awk '{ printf "%dx%d@%.3f\n", $1, $2, $3/1000 }'
      }

      current_mode_string() {
        niri msg --json outputs | jq -r --arg c "$1" '
          .[$c] as $o
          | $o.modes[$o.current_mode]
          | [.width, .height, .refresh_rate] | @tsv
        ' | format_mode
      }

      target_mode_string() {
        niri msg --json outputs \
          | jq -r --arg c "$1" --argjson w "$TARGET_W" --argjson h "$TARGET_H" '
              .[$c].modes
              | map(select(.width == $w and .height == $h))
              | sort_by(.refresh_rate) | reverse
              | .[0]
              | [.width, .height, .refresh_rate] | @tsv
            ' \
          | format_mode
      }

      # --- process-kill helpers ---

      # Wait up to ~18s for all named processes (any of them) to exit.
      wait_for_exit() {
        for _ in $(seq 1 60); do
          any=0
          for p in "$@"; do
            if pgrep -u "$(id -u)" -x "$p" >/dev/null; then any=1; break; fi
          done
          if [ "$any" = "0" ]; then return 0; fi
          sleep 0.3
        done
        return 1
      }

      kill_steam() {
        steam -shutdown 2>/dev/null || true
        wait_for_exit steam || echo "warn: Steam didn't exit cleanly" >&2
      }

      kill_prism() {
        pkill -TERM -u "$(id -u)" -x prismlauncher 2>/dev/null || true
        # Prism normally signals its child JVM on shutdown; give it a chance.
        if ! wait_for_exit prismlauncher java; then
          echo "warn: Prism/java didn't exit cleanly, force-killing" >&2
          pkill -KILL -u "$(id -u)" -x prismlauncher 2>/dev/null || true
          pkill -KILL -u "$(id -u)" -x java 2>/dev/null || true
        fi
      }

      # --- per-profile launch commands ---

      start_session() {
        profile="$1"
        case "$profile" in
          steam)
            kill_steam
            set -- steam -bigpicture
            ;;
          prism)
            kill_prism
            set -- prismlauncher
            ;;
          *)
            echo "unknown profile: '$profile' (expected: steam, prism)" >&2
            exit 2
            ;;
        esac

        conn="$(resolve_connector)"
        if [ -z "$conn" ]; then
          echo "could not resolve connector for '$MONITOR_DESC'" >&2
          exit 1
        fi

        prev="$(current_mode_string "$conn")"
        target="$(target_mode_string "$conn")"
        if [ -z "$target" ]; then
          echo "no ''${TARGET_W}x''${TARGET_H} mode available on $conn" >&2
          exit 1
        fi
        printf '%s %s\n' "$conn" "$prev" > "$STATE_FILE"

        niri msg output "$conn" mode "$target"

        # exec: this process becomes gamescope, so Sunshine's `cmd` waits on
        # gamescope to exit before firing `undo`.
        exec gamescope \
          -W "$TARGET_W" -H "$TARGET_H" \
          -r 144 \
          -f -e \
          -- "$@"
      }

      stop_session() {
        if [ ! -f "$STATE_FILE" ]; then
          echo "no state file at $STATE_FILE; nothing to restore" >&2
          exit 0
        fi
        read -r conn prev < "$STATE_FILE"
        if [ -n "$conn" ] && [ -n "$prev" ]; then
          niri msg output "$conn" mode "$prev"
        fi
        rm -f "$STATE_FILE"
      }

      case "''${1:-}" in
        start) start_session "''${2:-}" ;;
        stop)  stop_session ;;
        *)
          echo "usage: sunshine-gamescope-stream {start <profile>|stop}" >&2
          echo "profiles: steam, prism" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  services.sunshine = {
    enable = true;
    autoStart = true;
    capSysAdmin = false;   # niri speaks wlr-screencopy; no CAP_SYS_ADMIN needed
    openFirewall = true;
    package = sunshinePkgs.sunshine.override {
      cudaSupport = true;
      cudaPackages = sunshinePkgs.cudaPackages;
    };
  };

  assertions = [{
    assertion = builtins.currentTime <= sunshinePrDeadline;
    message = ''
      The sunshine package is pinned to nixpkgs PR #521906
      (https://github.com/NixOS/nixpkgs/pull/521906) and the 2026-06-01
      deadline for re-checking has passed.

      Has the PR merged?
        - Yes: drop the `sunshinePkgs` pin in
          nixos/mindgame/services/sunshine.nix and use `unstable.sunshine`
          (also remove this assertion).
        - No:  bump `sunshinePrDeadline` in that file to a new date.
    '';
  }];

  services.udev.extraRules = ''
    KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
  '';
  hardware.uinput.enable = true;

  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };

  environment.systemPackages = [
    pkgs.gamescope
    sunshineGamescopeStream
    sunshinePinOutput
  ];
}
