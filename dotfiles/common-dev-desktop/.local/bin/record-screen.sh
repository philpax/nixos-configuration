#!/bin/sh
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
        gpu-screen-recorder -w region -region "$REGION" -f 60 -o "$FILENAME" &
        ;;
    *)
        echo "Usage: $0 [area|window]" >&2
        rm -f "$PATH_FILE"
        exit 1
        ;;
esac

echo $! > "$PID_FILE"
notify-send "Recording started" "$(basename "$FILENAME")"
