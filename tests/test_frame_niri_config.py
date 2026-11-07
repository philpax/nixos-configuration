from pathlib import Path

import pytest

from frame.niri_config import adapt_config

ROOT = Path(__file__).resolve().parents[1]
SHARED_CONFIG = ROOT / "common-dev-desktop/dotfiles/.config/niri/config.kdl"


def test_adapt_shared_config_for_nested_frame() -> None:
    source = SHARED_CONFIG.read_text()
    startup = "/nix/store/frame session/bin/frame-niri-start"

    result = adapt_config(source, startup)

    assert 'mod-key-nested "Super"' in result
    assert 'mod-key-nested "Mod5"' not in result
    assert "Iso_Level3_Shift" not in result
    assert 'options "lv3:ralt_switch"' not in result
    assert "use AltGr as the mod key" not in result
    assert "Make Right Alt emit" not in result
    assert f'spawn-at-startup "{startup}"' in result
    assert "~/.config/wayland-autostart.sh" not in result
    assert 'Mod+D { spawn "fuzzel"; }' in result
    assert 'Mod+D { spawn "anyrun"; }' not in result
    assert 'Super+Alt+L { spawn "swaylock"; }' not in result
    assert "Mod+Shift+P { power-off-monitors; }" not in result

    for include in ("outputs.kdl", "machine.kdl", "workspaces.kdl"):
        assert f'include optional=true "{include}"' not in result

    # Keep upstream-accepted rules, background effects and ordinary binds intact.
    assert result.count("window-rule {") == source.count("window-rule {")
    assert result.count("background-effect {") == source.count("background-effect {")
    assert 'Mod+Return { spawn "ghostty"; }' in result
    assert "Mod+Q { close-window; }" in result
    assert 'match title="^Biome*"' in result


def test_exact_replacements_preserve_braces_in_comments_and_strings() -> None:
    source = """input {
    mod-key-nested "Iso_Level3_Shift"
    keyboard { xkb { options "lv3:ralt_switch" } }
}
include optional=true "outputs.kdl"
include optional=true "machine.kdl"
include optional=true "workspaces.kdl"
spawn-at-startup "sh" "-c" "~/.config/wayland-autostart.sh"
// The braces { and } here are only comment text.
screenshot-path "a {literal} path"
window-rule {
    match title="a {literal} title"
    nested { value "}" }
    // A closing brace in a comment: }
}
binds {
    Mod+D { spawn "anyrun"; }
    Super+Alt+L { spawn "swaylock"; }
    Mod+Shift+P { power-off-monitors; }
    Mod+Return { spawn "ghostty"; }
}
"""

    result = adapt_config(source, "/run/frame startup")

    assert 'screenshot-path "a {literal} path"' in result
    assert 'match title="a {literal} title"' in result
    assert 'nested { value "}" }' in result
    assert "// A closing brace in a comment: }" in result
    assert "// The braces { and } here are only comment text." in result
    assert "window-rule {" in result and '    nested { value "}" }' in result
    assert 'Mod+Return { spawn "ghostty"; }' in result


def test_config_drift_fails_instead_of_silently_omitting_changes() -> None:
    with pytest.raises(ValueError, match="nested mod-key setting"):
        adapt_config("", "/run/frame-start")

    with pytest.raises(ValueError, match="non-empty"):
        adapt_config(SHARED_CONFIG.read_text(), "")


def test_duplicate_expected_anchor_fails() -> None:
    source = SHARED_CONFIG.read_text()
    source += '\nMod+D { spawn "anyrun"; }\n'

    with pytest.raises(ValueError, match="expected one anyrun launcher bind, found 2"):
        adapt_config(source, "/run/frame-start")
