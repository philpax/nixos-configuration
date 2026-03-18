#!/bin/sh
# Shared autostart for Wayland compositors (niri, driftwm, etc.)

waybar &
mako &
swaybg -o DP-4 -i ~/wallpapers/21x9/wallhaven-vq72xm.png &
swaybg -o eDP-1 -i ~/wallpapers/16x9/Half_Life_2_Episode_Three_concept_2.jpg &
sunsetr &

# mindgame excluded from suspend: sleep is broken on that machine
if [ "$(hostname)" = mindgame ]; then
    swayidle -w timeout 900 'swaylock -f' &
else
    swayidle -w timeout 900 'swaylock -f' timeout 1800 'systemctl suspend' &
fi
