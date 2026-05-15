pragma Singleton
import QtQuick

QtObject {
    // Bar shell
    readonly property color barBg: "#802b303b"
    readonly property color barBorder: "#80646e7d"
    readonly property int barHeight: 24
    readonly property int barBorderHeight: 3

    // Module colours (rgba with 0.5 alpha → 80 hex prefix)
    readonly property color clockBg:        "#80a54265"
    readonly property color batteryBg:      "#809f42a5"
    readonly property color batteryCharging: "#803aa54b"
    readonly property color batteryCritical: "#80a53a3a"
    readonly property color cpuBg:          "#8042a571"
    readonly property color memoryBg:       "#8042a594"
    readonly property color gpuBg:          "#804294a5"
    readonly property color vramBg:         "#804271a5"
    readonly property color backlightBg:    "#805942a5"
    readonly property color networkBg:      "#8059a542"
    readonly property color networkDown:    "#80a53a3a"
    readonly property color audioBg:        "#807ca542"
    readonly property color audioMuted:     "#80696c72"
    readonly property color tempBg:         "#80424da5"
    readonly property color tempCritical:   "#80a53a3a"
    readonly property color trayBg:         "#80a54288"
    readonly property color idleBg:         "#80a58842"
    readonly property color idleActive:     "#80848aa5"
    readonly property color powerPerf:      "#80a53a3a"
    readonly property color powerBalanced:  "#80425da5"
    readonly property color powerSaver:     "#803aa54b"
    readonly property color mprisBg:        "#80a54242"
    readonly property color tailscaleBg:    "#80a54242"
    readonly property color tailscaleOn:    "#803aa54b"
    readonly property color langBg:         "#80646e7d"

    readonly property string fontFamily: "Cozette"
    readonly property string fontStyle: "Regular"
    readonly property int fontSize: 13
    readonly property color fg: "#ffffff"
}
