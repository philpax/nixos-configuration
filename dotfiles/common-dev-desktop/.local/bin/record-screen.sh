#!/usr/bin/env bash
set -eu

PID_FILE="/tmp/screen-recorder.pid"
PATH_FILE="/tmp/screen-recorder.path"
RECORDING_DIR="$HOME/Videos/Recordings"

# If already recording, stop it
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    kill -INT "$(cat "$PID_FILE")"
    wait "$(cat "$PID_FILE")" 2>/dev/null || true
    SAVED_PATH="$(cat "$PATH_FILE" 2>/dev/null || echo "")"
    rm -f "$PID_FILE" "$PATH_FILE"
    if [ -n "$SAVED_PATH" ]; then
        printf '%s' "$SAVED_PATH" | wl-copy
        notify-send "Recording saved" "$(basename "$SAVED_PATH")"
    else
        notify-send "Recording stopped"
    fi
    exit 0
fi

MODE="${1:-area}"
mkdir -p "$RECORDING_DIR"
FILENAME="$RECORDING_DIR/recording-$(date +%Y%m%d-%H%M%S).mp4"

echo "$FILENAME" > "$PATH_FILE"

case "$MODE" in
    area)
        GEOMETRY="$(slurp)" || exit 1
        wf-recorder -g "$GEOMETRY" -f "$FILENAME" &
        ;;
    window)
        WIN="$(niri msg --json focused-window)"
        IS_FLOATING="$(printf '%s' "$WIN" | jq -r '.is_floating')"
        if [ "$IS_FLOATING" != "true" ]; then
            notify-send "Recording" "Focused window is not floating; window-record only supports floating windows."
            rm -f "$PATH_FILE"
            exit 1
        fi
        WS_ID="$(printf '%s' "$WIN" | jq -r '.workspace_id')"
        OUTPUT_NAME="$(niri msg --json workspaces | jq -r --argjson id "$WS_ID" '.[] | select(.id == $id) | .output')"
        OUTPUTS="$(niri msg --json outputs)"
        REGION="$(jq -nr \
            --argjson win "$WIN" \
            --argjson outputs "$OUTPUTS" \
            --arg name "$OUTPUT_NAME" \
            '($outputs[$name] // ($outputs | to_entries[] | select(.value.name == $name) | .value)) as $o
             | ($win.layout.tile_pos_in_workspace_view[0] + $o.logical.x | floor) as $x
             | ($win.layout.tile_pos_in_workspace_view[1] + $o.logical.y | floor) as $y
             | "\($win.layout.window_size[0])x\($win.layout.window_size[1])+\($x)+\($y)"')"
        # Find PipeWire audio streams belonging to this window. Strategy:
        #   1. PID-ancestry match (works for Wayland-native apps where niri's
        #      reported window pid is also the app's process).
        #   2. app_id fallback (works for X11/Xwayland windows where niri only
        #      sees the xwayland-satellite pid). Match window app_id, case-
        #      insensitively, against application.name / node.name / binary.
        AUDIO_ARGS=()
        declare -A SEEN=()
        WIN_PID="$(printf '%s' "$WIN" | jq -r '.pid // empty')"
        WIN_APP_ID="$(printf '%s' "$WIN" | jq -r '.app_id // empty' | tr '[:upper:]' '[:lower:]')"
        STREAMS="$(pw-dump 2>/dev/null | jq -r '
            . as $all
            | ($all
                | map(select(.type == "PipeWire:Interface:Client"))
                | map({key: (.id | tostring), value: {
                    pid: (.info.props["application.process.id"] // null),
                    binary: (.info.props["application.process.binary"] // null)
                  }})
                | from_entries) as $clients
            | $all[]
            | select(.type == "PipeWire:Interface:Node")
            | select(.info.props["media.class"] == "Stream/Output/Audio")
            | .info.props as $p
            | ($clients[($p["client.id"] | tostring)] // {}) as $c
            | ($p["application.process.id"] // $c.pid // "") as $pid
            | ($p["application.process.binary"] // $c.binary // "") as $binary
            | (($p["application.name"] // "") | tostring) as $appname
            | (if ($appname == "" or ($appname | startswith("PipeWire ALSA")))
               then ($p["node.name"] // "")
               else $appname end) as $name
            | [($pid | tostring), $name, ($binary | tostring), ($p["node.name"] // "")]
            | @tsv' | sort -u)"
        add_stream() {
            local name="$1"
            [ -n "$name" ] || return 0
            if [ -z "${SEEN[$name]:-}" ]; then
                AUDIO_ARGS+=(-a "app:$name")
                SEEN[$name]=1
            fi
        }
        while IFS=$'\t' read -r SPID SNAME SBIN SNODENAME; do
            [ -n "$SNAME" ] || continue
            # 1. PID ancestry
            if [ -n "$WIN_PID" ] && [ -n "$SPID" ]; then
                p="$SPID"
                while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ]; do
                    if [ "$p" = "$WIN_PID" ]; then
                        add_stream "$SNAME"
                        break
                    fi
                    [ -r "/proc/$p/status" ] || break
                    p="$(awk '/^PPid:/ {print $2; exit}' "/proc/$p/status" 2>/dev/null || true)"
                done
            fi
            # 2. app_id substring match (case-insensitive, either direction)
            if [ -n "$WIN_APP_ID" ]; then
                for cand in "$SNAME" "$SBIN" "$SNODENAME"; do
                    [ -n "$cand" ] || continue
                    cand_lc="$(printf '%s' "$cand" | tr '[:upper:]' '[:lower:]')"
                    case "$cand_lc" in
                        *"$WIN_APP_ID"*) add_stream "$SNAME"; break ;;
                    esac
                    case "$WIN_APP_ID" in
                        *"$cand_lc"*) add_stream "$SNAME"; break ;;
                    esac
                done
            fi
        done <<< "$STREAMS"
        if [ ${#AUDIO_ARGS[@]} -eq 0 ]; then
            notify-send "Recording" "No audio streams found for this window; recording video only."
        fi
        gpu-screen-recorder -w region -region "$REGION" -f 60 -q high "${AUDIO_ARGS[@]}" -o "$FILENAME" &
        ;;
    *)
        echo "Usage: $0 [area|window]" >&2
        rm -f "$PATH_FILE"
        exit 1
        ;;
esac

echo $! > "$PID_FILE"
notify-send "Recording started" "$(basename "$FILENAME")"
