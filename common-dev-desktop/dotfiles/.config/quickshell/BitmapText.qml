import QtQuick

// Text node configured for pixel-perfect bitmap fonts.
// NativeRendering is the only renderType that respects antialiasing:false
// and hintingPreference — required for Cozette's embedded bitmap strikes.
Text {
    renderType: Text.NativeRendering
    antialiasing: false
    font.family: Theme.fontFamily
    font.styleName: Theme.fontStyle
    font.pixelSize: Theme.fontSize
    font.hintingPreference: Font.PreferFullHinting
    color: Theme.fg
    verticalAlignment: Text.AlignVCenter
}
