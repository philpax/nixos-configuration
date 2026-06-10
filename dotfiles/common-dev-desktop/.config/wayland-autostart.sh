#!/bin/sh
# Shared autostart for Wayland compositors (niri, driftwm, etc.)

qs &
mako &

# Work around a post-update DRM plane bug on the MSI ultrawide (DP-1): at boot it
# comes up at 144Hz (DSC) with a stale 2560-wide plane source, which makes
# gpu-screen-recorder's region capture squash recordings by 2560/3440 (0.744x) —
# windows end up shrunk and offset within the frame. Forcing a clean modeset
# (bounce 60Hz -> 144Hz) reconfigures the plane to its true 3440 width. The 60Hz
# step is what guarantees a real modeset; a same-mode reapply may be a no-op. If a
# single reapply turns out to suffice, the 60Hz line can be dropped. No-op on
# machines without this monitor.
fix_msi_plane() {
    connector=$(niri msg --json outputs 2>/dev/null | jq -r '
        to_entries[]
        | select("\(.value.make) \(.value.model) \(.value.serial)"
                 == "Microstep MSI MAG342CQR DB6H261C01393")
        | .key')
    [ -n "$connector" ] || return 0
    niri msg output "$connector" mode 3440x1440@60.000  >/dev/null 2>&1
    niri msg output "$connector" mode 3440x1440@144.000 >/dev/null 2>&1
}
fix_msi_plane

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
