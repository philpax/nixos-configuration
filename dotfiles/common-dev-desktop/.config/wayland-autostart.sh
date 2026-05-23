#!/bin/sh
# Shared autostart for Wayland compositors (niri, driftwm, etc.)

qs &
mako &

# swaybg matches outputs by connector (DP-1, HDMI-A-2, ...), but the niri config
# keys outputs by description. Resolve descriptions via `niri msg --json outputs`
# so both files can refer to monitors by the same human-readable name.
set_wallpaper() {
    desc="$1"
    image="$2"
    case "$desc" in
        eDP-*|DP-*|HDMI-*|DVI-*|LVDS-*|VGA-*)
            output="$desc" ;;
        *)
            output=$(niri msg --json outputs 2>/dev/null | jq -r --arg d "$desc" '
                to_entries[]
                | select("\(.value.make) \(.value.model) \(.value.serial)" == $d)
                | .key
            ') ;;
    esac
    if [ -n "$output" ]; then
        swaybg -o "$output" -i "$image" &
    else
        echo "wayland-autostart: no connector for '$desc'; skipping" >&2
    fi
}

set_wallpaper "Microstep MSI MAG342CQR DB6H261C01393" ~/wallpapers/21x9/wallhaven-vq72xm.png
set_wallpaper "Dell Inc. DELL U2723QE F31Q0P3" ~/wallpapers/9x16/wallhaven-7j91ee.png
set_wallpaper "eDP-1" ~/wallpapers/16x9/Half_Life_2_Episode_Three_concept_2.jpg

sunsetr &

# mindgame excluded from suspend: sleep is broken on that machine
if [ "$(hostname)" = mindgame ]; then
    swayidle -w timeout 900 'swaylock -f' &

    # Pin sunshine to the MSI ultrawide (handles DRM connector renumbering
    # across reboots). Script is defined in nixos/mindgame/services/sunshine.nix.
    sunshine-pin-output &
else
    swayidle -w timeout 900 'swaylock -f' timeout 1800 'systemctl suspend' &
fi
