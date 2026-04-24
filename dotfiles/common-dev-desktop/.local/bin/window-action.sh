#!/usr/bin/env bash
resolutions=(
    "resize 1280x720"
    "resize 1600x900"
    "resize 1920x1080"
    center
)
res=$(printf '%s\n' "${resolutions[@]}" | fuzzel --dmenu --prompt "Window action:")
[ -z "$res" ] && exit 0
if [ "$res" = "center" ]; then
    niri msg action center-column
    exit 0
fi
res=${res#resize }
w=${res%x*}
h=${res#*x}
[ -z "$w" ] || [ -z "$h" ] && exit 1
niri msg action set-column-width "$w"
niri msg action set-window-height "$h"
