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
  sunshinePrDeadline = 1780876800; # 2026-06-08 UTC

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

  # Wrapper that runs INSIDE gamescope. Starting these in-band (rather than
  # blocking start_session on a graceful shutdown of the existing instance)
  # means the mode switch and the stream start are immediate; the launcher
  # then drains the old process and execs the new one as gamescope's payload.
  innerSteam = pkgs.writeShellApplication {
    name = "sunshine-gamescope-inner-steam";
    runtimeInputs = with pkgs; [ procps coreutils ];
    text = ''
      # Old Steam was sent `-shutdown` outside gamescope; wait for it to drain
      # so Steam's single-instance check relays our launch to the new process.
      for _ in $(seq 1 60); do
        pgrep -u "$(id -u)" -x steam >/dev/null || break
        sleep 0.3
      done
      pkill -KILL -u "$(id -u)" -x steam 2>/dev/null || true
      exec steam -bigpicture
    '';
  };

  innerPrism = pkgs.writeShellApplication {
    name = "sunshine-gamescope-inner-prism";
    runtimeInputs = with pkgs; [ procps coreutils prismlauncher ];
    text = ''
      for _ in $(seq 1 60); do
        if ! pgrep -u "$(id -u)" -x prismlauncher >/dev/null \
           && ! pgrep -u "$(id -u)" -x java >/dev/null; then
          break
        fi
        sleep 0.3
      done
      pkill -KILL -u "$(id -u)" -x prismlauncher 2>/dev/null || true
      pkill -KILL -u "$(id -u)" -x java 2>/dev/null || true
      exec prismlauncher
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
      wlinhibit
    ];
    text = ''
      MONITOR_DESC="${monitorDesc}"
      TARGET_W=2560
      TARGET_H=1440
      # Fallback mode used by `reset` and by `stop` when state is missing/garbled.
      NATIVE_MODE="3440x1440@144.000"

      RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/tmp/sunshine-gamescope-$(id -u)}"
      mkdir -p "$RUNTIME_DIR"
      STATE_FILE="$RUNTIME_DIR/sunshine-gamescope-stream.prev-mode"
      LOG_FILE="$RUNTIME_DIR/sunshine-gamescope-stream.log"

      log() {
        printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2
      }

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

      # niri occasionally swallows mode-set commands (we saw at least one case
      # where stop reported success but the output stayed at 1440p). Verify the
      # change actually took, and retry a couple of times if not.
      set_mode_verified() {
        conn="$1"
        desired="$2"
        attempt=1
        while [ "$attempt" -le 3 ]; do
          niri msg output "$conn" mode "$desired" 2>&1 | sed 's/^/  niri: /' | tee -a "$LOG_FILE" >&2 || true
          sleep 0.3
          actual="$(current_mode_string "$conn")"
          if [ "$actual" = "$desired" ]; then
            log "set $conn → $desired (attempt $attempt)"
            return 0
          fi
          log "set $conn attempt $attempt: still at '$actual' (wanted '$desired'), retrying"
          attempt=$((attempt + 1))
        done
        log "ERROR: failed to set $conn to $desired after 3 attempts (current: $(current_mode_string "$conn"))"
        return 1
      }

      # --- subcommands ---

      start_session() {
        profile="$1"
        case "$profile" in
          steam)
            log "start steam: signalling any running Steam to shut down"
            steam -shutdown >/dev/null 2>&1 || true
            set -- ${innerSteam}/bin/sunshine-gamescope-inner-steam
            ;;
          prism)
            log "start prism: signalling any running Prism/JVM"
            pkill -TERM -u "$(id -u)" -x prismlauncher 2>/dev/null || true
            set -- ${innerPrism}/bin/sunshine-gamescope-inner-prism
            ;;
          *)
            log "ERROR: unknown profile: '$profile' (expected: steam, prism)"
            exit 2
            ;;
        esac

        conn="$(resolve_connector)"
        if [ -z "$conn" ]; then
          log "ERROR: could not resolve connector for '$MONITOR_DESC'"
          exit 1
        fi

        prev="$(current_mode_string "$conn")"
        target="$(target_mode_string "$conn")"
        if [ -z "$target" ]; then
          log "ERROR: no ''${TARGET_W}x''${TARGET_H} mode available on $conn"
          exit 1
        fi
        if [ -z "$prev" ]; then
          log "WARN: empty current mode for $conn; will fall back to $NATIVE_MODE on stop"
          prev="$NATIVE_MODE"
        fi
        printf '%s %s\n' "$conn" "$prev" > "$STATE_FILE"
        log "saved state: '$conn $prev' to $STATE_FILE"

        set_mode_verified "$conn" "$target" || log "WARN: mode set failed, continuing anyway"

        # Hold a Wayland idle-inhibit lock so niri stops emitting idle events
        # for the streaming session's lifetime — this is what actually keeps
        # swayidle's timer from firing (systemd-inhibit would not, since
        # swayidle's timeout is driven by the compositor's idle-notify
        # protocol, not by logind inhibitors).
        wlinhibit &
        inhibit_pid=$!
        trap 'kill "$inhibit_pid" 2>/dev/null || true' EXIT
        log "spawned wlinhibit (pid $inhibit_pid)"

        # Sunshine's `cmd` waits on this script to exit before firing `undo`.
        # We can't `exec gamescope` here because the EXIT trap needs to run
        # to release the idle-inhibit lock after gamescope is done.
        log "running gamescope at ''${TARGET_W}x''${TARGET_H} → $*"
        gamescope \
          -W "$TARGET_W" -H "$TARGET_H" \
          -r 144 \
          -f -e \
          -- "$@"
      }

      stop_session() {
        log "stop invoked"
        conn=""
        prev=""
        if [ -f "$STATE_FILE" ]; then
          read -r conn prev < "$STATE_FILE"
          log "read state: conn='$conn' prev='$prev'"
        else
          log "no state file at $STATE_FILE"
        fi
        if [ -z "$conn" ]; then
          conn="$(resolve_connector)"
          log "fallback connector resolution: '$conn'"
        fi
        if [ -z "$prev" ]; then
          prev="$NATIVE_MODE"
          log "fallback mode: '$prev'"
        fi
        if [ -n "$conn" ]; then
          set_mode_verified "$conn" "$prev" || true
        else
          log "ERROR: cannot restore — no connector available"
        fi
        rm -f "$STATE_FILE"
      }

      reset_session() {
        log "reset: forcing $MONITOR_DESC to $NATIVE_MODE"
        conn="$(resolve_connector)"
        if [ -z "$conn" ]; then
          log "ERROR: could not resolve $MONITOR_DESC"
          exit 1
        fi
        set_mode_verified "$conn" "$NATIVE_MODE" || exit 1
        rm -f "$STATE_FILE"
      }

      case "''${1:-}" in
        start) start_session "''${2:-}" ;;
        stop)  stop_session ;;
        reset) reset_session ;;
        *)
          echo "usage: sunshine-gamescope-stream {start <profile>|stop|reset}" >&2
          echo "profiles: steam, prism" >&2
          echo "reset: force the MSI back to $NATIVE_MODE (use when stuck)" >&2
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

  # Workarounds for two known sunshine bugs hitting us on this host:
  #
  # 1. https://github.com/LizardByte/Sunshine/issues/5038 — regression in
  #    2026.415.34134+ (we're on 2026.516.143833) where the DRM-FD/NVENC path
  #    leaks file descriptors per session on Wayland/NVIDIA. The systemd
  #    default soft NOFILE of 1024 isn't enough for even a few connect/
  #    disconnect cycles. Bump it generously until the upstream regression is
  #    fixed; revisit when issue 5038 closes.
  #
  # 2. https://github.com/LizardByte/Sunshine/issues/3668 — sunshine fails to
  #    detect an existing pulseaudio/pipewire-pulse instance and spawns a
  #    duplicate that loops trying to grab the (already-claimed) hardware,
  #    burning CPU and FDs until the soft limit hits. The fix is to point
  #    sunshine at the existing socket explicitly. `%t` is the systemd
  #    runtime-directory specifier; in a user unit it expands to
  #    /run/user/<uid>.
  systemd.user.services.sunshine = {
    serviceConfig.LimitNOFILE = 65536;
    environment.PULSE_SERVER = "%t/pulse/native";
  };

  assertions = [{
    assertion = builtins.currentTime <= sunshinePrDeadline;
    message = ''
      The sunshine package is pinned to nixpkgs PR #521906
      (https://github.com/NixOS/nixpkgs/pull/521906) and the 2026-06-08
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
