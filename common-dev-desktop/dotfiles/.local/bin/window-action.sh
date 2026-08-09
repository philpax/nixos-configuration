#!/usr/bin/env bash
actions=(
    "resize 1280x720"
    "resize 1600x900"
    "resize 1920x1080"
    center
)
res=$(printf '%s\n' "${actions[@]}" | fuzzel --dmenu --prompt "Window action:")
[ -z "$res" ] && exit 0
if [ "$res" = "center" ]; then
    niri msg action center-column
    exit 0
fi
res=${res#resize }
if [[ ! "$res" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    notify-send "window-action" "Invalid resolution: $res (expected WxH, e.g. 1280x960)"
    exit 1
fi
w=${BASH_REMATCH[1]}
h=${BASH_REMATCH[2]}
niri msg action set-column-width "$w"
niri msg action set-window-height "$h"
