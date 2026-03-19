#!/bin/sh
set -eu

PID_FILE="/tmp/wf-recorder.pid"
PATH_FILE="/tmp/wf-recorder.path"
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

case "$MODE" in
    area)
        GEOMETRY="$(slurp)" || exit 1
        ;;
    window)
        GEOMETRY="$(niri msg --json windows | jq -r '.[] | "\(.x),\(.y) \(.width)x\(.height)"' | slurp)" || exit 1
        ;;
    *)
        echo "Usage: $0 [area|window]" >&2
        exit 1
        ;;
esac

echo "$FILENAME" > "$PATH_FILE"
wf-recorder -g "$GEOMETRY" -f "$FILENAME" &
echo $! > "$PID_FILE"
notify-send "Recording started" "$(basename "$FILENAME")"
