#!/usr/bin/env python3
"""Generate waybar style.css with evenly-distributed pastel HSV module colors."""

import colorsys
from pathlib import Path


# --- Tunable HSV parameters ---
SATURATION = 0.60
VALUE = 0.65
ALPHA = 0.5

# Semantic state colors (H, S, V, A) — used for error/success/muted/etc.
STATE_ERROR = (0, 0.65, 0.65, 0.5)  # muted red
STATE_ERROR_BLINK = (0, 0.65, 0.65, 0.6)  # slightly more opaque for animation
STATE_SUCCESS = (130, 0.65, 0.65, 0.5)  # muted green
STATE_MUTED = (220, 0.08, 0.45, 0.5)  # desaturated grey
STATE_BALANCED = (220, 0.65, 0.65, 0.5)  # muted blue
STATE_ACTIVATED = (230, 0.20, 0.65, 0.5)  # pale blue


# --- Module order for hue distribution ---
# Ordered as they appear in the bar (left-to-right across both sides).
# Each module gets an equally-spaced hue.
MODULES = [
    "custom-media",
    "mpd",
    "idle_inhibitor",
    "custom-tailscale",
    "pulseaudio",
    "network",
    "power-profiles-daemon",
    "cpu",
    "memory",
    "custom-gpu",
    "custom-vram",
    "temperature",
    "backlight",
    "keyboard-state",
    "battery",
    "tray",
    "clock",
]

# Extra modules not in the bar but defined in CSS (get nearby hues)
EXTRA_MODULES = {
    "disk": "memory",  # slot near memory
    "wireplumber": "pulseaudio",  # same as pulseaudio
    "language": "keyboard-state",  # slot near keyboard-state
}


def hsv_to_rgba(h_deg: float, s: float, v: float, a: float = ALPHA) -> str:
    """Convert HSV (h in degrees, s/v in 0-1) to rgba() CSS string."""
    r, g, b = colorsys.hsv_to_rgb(h_deg / 360, s, v)
    return f"rgba({int(r * 255)}, {int(g * 255)}, {int(b * 255)}, {a})"


def state_rgba(state: tuple) -> str:
    """Convert a (H, S, V, A) state tuple to rgba() CSS string."""
    h, s, v, a = state
    return hsv_to_rgba(h, s, v, a)


def dim_rgba(h_deg: float, s: float, v: float) -> str:
    """A slightly dimmer variant of a module color (for paused/hover states)."""
    return hsv_to_rgba(h_deg, s, v * 0.85)


def compute_module_colors() -> dict[str, tuple[float, float, float]]:
    """Return {module_name: (hue_degrees, saturation, value)} for all modules."""
    n = len(MODULES)
    colors = {}
    for i, mod in enumerate(MODULES):
        h = (i / n) * 360
        colors[mod] = (h, SATURATION, VALUE)

    # Extra modules inherit hue from their reference module
    for mod, ref in EXTRA_MODULES.items():
        h, s, v = colors[ref]
        colors[mod] = (h, s, v)

    return colors


def generate_css() -> str:
    colors = compute_module_colors()

    def bg(mod: str) -> str:
        h, s, v = colors[mod]
        return hsv_to_rgba(h, s, v)

    def bg_dim(mod: str) -> str:
        h, s, v = colors[mod]
        return dim_rgba(h, s, v)

    # All modules that participate in the shared padding rule
    shared_modules = [
        "#clock", "#battery", "#cpu", "#memory", "#disk", "#temperature",
        "#backlight", "#network", "#pulseaudio", "#wireplumber",
        "#custom-media", "#custom-gpu", "#custom-vram", "#custom-tailscale",
        "#tray", "#mode", "#idle_inhibitor", "#scratchpad",
        "#power-profiles-daemon", "#mpd",
    ]
    shared_selector = ",\n".join(shared_modules)

    return f"""\
* {{
    /* `otf-font-awesome` is required to be installed for icons */
    font-family: Cozette;
    font-size: 12px;
}}

window#waybar {{
    background-color: rgba(43, 48, 59, 0.5);
    border-bottom: 3px solid rgba(100, 114, 125, 0.5);
    color: #ffffff;
    transition-property: background-color;
    transition-duration: .5s;
}}

window#waybar.hidden {{
    opacity: 0.2;
}}

/*
window#waybar.empty {{
    background-color: transparent;
}}
window#waybar.solo {{
    background-color: #FFFFFF;
}}
*/

window#waybar.termite {{
    background-color: #3F3F3F;
}}

window#waybar.chromium {{
    background-color: #000000;
    border: none;
}}

button {{
    /* Use box-shadow instead of border so the text isn't offset */
    box-shadow: inset 0 -3px transparent;
    /* Avoid rounded borders under each button name */
    border: none;
    border-radius: 0;
}}

/* https://github.com/Alexays/Waybar/wiki/FAQ#the-workspace-buttons-have-a-strange-hover-effect */
button:hover {{
    background: inherit;
    box-shadow: inset 0 -3px #ffffff;
}}

/* you can set a style on hover for any module like this */
#pulseaudio:hover {{
    background-color: {bg_dim("pulseaudio")};
}}

#workspaces button {{
    padding: 0 5px;
    background-color: transparent;
    color: #ffffff;
}}

#workspaces button:hover {{
    background: rgba(0, 0, 0, 0.2);
    font-weight: normal;
    text-shadow: none;
}}

#workspaces button.focused, #workspaces button.active {{
    background-color: #64727D;
    box-shadow: inset 0 -3px #ffffff;
}}

#workspaces button.urgent {{
    background-color: #eb4d4b;
}}

#mode {{
    background-color: #64727D;
    box-shadow: inset 0 -3px #ffffff;
}}

{shared_selector} {{
    padding: 0 8px;
    color: #ffffff;
    box-shadow: inset 0 -3px rgba(100, 114, 125, 0.5);
}}

#window,
#workspaces {{
    margin: 0 4px;
}}

/* If workspaces is the leftmost module, omit left margin */
.modules-left > widget:first-child > #workspaces {{
    margin-left: 0;
}}

/* If workspaces is the rightmost module, omit right margin */
.modules-right > widget:last-child > #workspaces {{
    margin-right: 0;
}}

#clock {{
    background-color: {bg("clock")};
}}

#battery {{
    background-color: {bg("battery")};
}}

#battery.charging, #battery.plugged {{
    background-color: {state_rgba(STATE_SUCCESS)};
}}

@keyframes blink {{
    to {{
        background-color: {state_rgba(STATE_ERROR_BLINK)};
    }}
}}

/* Using steps() instead of linear as a timing function to limit cpu usage */
#battery.critical:not(.charging) {{
    background-color: {state_rgba(STATE_ERROR)};
    animation-name: blink;
    animation-duration: 0.5s;
    animation-timing-function: steps(12);
    animation-iteration-count: infinite;
    animation-direction: alternate;
}}

#power-profiles-daemon {{
    padding-right: 15px;
}}

#power-profiles-daemon.performance {{
    background-color: {state_rgba(STATE_ERROR)};
}}

#power-profiles-daemon.balanced {{
    background-color: {state_rgba(STATE_BALANCED)};
}}

#power-profiles-daemon.power-saver {{
    background-color: {state_rgba(STATE_SUCCESS)};
}}

label:focus {{
    background-color: #000000;
}}

#cpu {{
    background-color: {bg("cpu")};
}}

#memory {{
    background-color: {bg("memory")};
}}

#custom-gpu {{
    background-color: {bg("custom-gpu")};
}}

#custom-vram {{
    background-color: {bg("custom-vram")};
}}

#disk {{
    background-color: {bg("disk")};
}}

#backlight {{
    background-color: {bg("backlight")};
}}

#network {{
    background-color: {bg("network")};
}}

#network.disconnected {{
    background-color: {state_rgba(STATE_ERROR)};
}}

#pulseaudio {{
    background-color: {bg("pulseaudio")};
}}

#pulseaudio.muted {{
    background-color: {state_rgba(STATE_MUTED)};
}}

#wireplumber {{
    background-color: {bg("wireplumber")};
}}

#wireplumber.muted {{
    background-color: {state_rgba(STATE_ERROR)};
}}

#custom-media {{
    background-color: {bg("custom-media")};
    min-width: 100px;
}}

#custom-media.custom-spotify {{
    background-color: {bg("custom-media")};
}}

#custom-media.custom-vlc {{
    background-color: {bg_dim("custom-media")};
}}

#temperature {{
    background-color: {bg("temperature")};
}}

#temperature.critical {{
    background-color: {state_rgba(STATE_ERROR)};
}}

#tray {{
    background-color: {bg("tray")};
}}

#tray > .passive {{
    -gtk-icon-effect: dim;
}}

#tray > .needs-attention {{
    -gtk-icon-effect: highlight;
    background-color: {state_rgba(STATE_ERROR)};
}}

#idle_inhibitor {{
    background-color: {bg("idle_inhibitor")};
}}

#idle_inhibitor.activated {{
    background-color: {state_rgba(STATE_ACTIVATED)};
}}

#mpd {{
    background-color: {bg("mpd")};
}}

#mpd.disconnected {{
    background-color: {state_rgba(STATE_ERROR)};
}}

#mpd.stopped {{
    background-color: {state_rgba(STATE_MUTED)};
}}

#mpd.paused {{
    background-color: {bg_dim("mpd")};
}}

#language {{
    background: {bg("language")};
    color: #ffffff;
    padding: 0 5px;
    margin: 0 5px;
    min-width: 16px;
}}

#keyboard-state {{
    background: {bg("keyboard-state")};
    color: #ffffff;
    padding: 0 0px;
    margin: 0 5px;
    min-width: 16px;
}}

#keyboard-state > label {{
    padding: 0 5px;
}}

#keyboard-state > label.locked {{
    background: rgba(0, 0, 0, 0.2);
}}

#scratchpad {{
    background: rgba(0, 0, 0, 0.2);
}}

#scratchpad.empty {{
\tbackground-color: transparent;
}}

#privacy {{
    padding: 0;
}}

#privacy-item {{
    padding: 0 5px;
    color: white;
}}

#privacy-item.screenshare {{
    background-color: rgba(207, 87, 0, 0.5);
}}

#privacy-item.audio-in {{
    background-color: rgba(28, 160, 0, 0.5);
}}

#privacy-item.audio-out {{
    background-color: rgba(0, 105, 212, 0.5);
}}

#custom-tailscale {{
    background-color: {bg("custom-tailscale")};
}}

#custom-tailscale.on {{
    background-color: {state_rgba(STATE_SUCCESS)};
}}

#custom-tailscale.off {{
    background-color: {state_rgba(STATE_MUTED)};
}}

#custom-tailscale.error {{
    background-color: {state_rgba(STATE_ERROR)};
}}
"""


if __name__ == "__main__":
    out = Path(__file__).parent / "style.css"
    css = generate_css()
    out.write_text(css)
    print(f"Wrote {out}")
