pragma Singleton
import QtQuick

QtObject {
    // Bar shell
    readonly property color barBg: "#802b303b"
    readonly property color barBorder: "#80646e7d"
    readonly property int barHeight: 24
    readonly property int barBorderHeight: 3

    // Module colours. Nearly every pill sits on one saturation/value "shell"
    // (S=0.6, V=0.647, 50% alpha) and differs only by hue, so we generate each
    // from a single helper and a named hue. The system-metric cluster
    // (cpu→vram) is an even green→cyan→blue sweep; the rest pick distinct hues.
    function hsv(hue) { return Qt.hsva(hue / 360.0, 0.6, 0.647, 0.5) }

    // Every hue-shell pill gets an even slice of the full colour wheel, indexed
    // in the order it appears along the bar — so the bar reads as one rainbow.
    // To add a pill, insert an index, shift the rest, and bump pillCount.
    readonly property int pillCount: 17
    function pillColor(i) { return hsv(360.0 * i / pillCount) }

    readonly property color idleBg:         pillColor(0)
    readonly property color tailscaleBg:    pillColor(1)
    readonly property color audioBg:        pillColor(2)
    readonly property color networkBg:      pillColor(3)
    readonly property color claude5hBg:     pillColor(4)
    readonly property color claudeWklyBg:   pillColor(5)
    readonly property color umansUsageBg:   pillColor(6)
    readonly property color cpuBg:          pillColor(7)
    readonly property color memoryBg:       pillColor(8)
    readonly property color diskBg:         pillColor(9)
    readonly property color gpuBg:          pillColor(10)
    readonly property color vramBg:         pillColor(11)
    readonly property color tempBg:         pillColor(12)
    readonly property color backlightBg:    pillColor(13)
    readonly property color batteryBg:     pillColor(14)
    readonly property color trayBg:        pillColor(15)
    readonly property color clockBg:       pillColor(16)
    readonly property color mprisBg:        hsv(0)  // commented out in Bar.qml

    // Semantic accent states — own saturation, deliberately off the hue shell.
    readonly property color good:           "#803aa54b"  // green
    readonly property color critical:       "#80a53a3a"  // red
    readonly property color muted:          "#80696c72"  // grey
    readonly property color batteryCharging: good
    readonly property color batteryCritical: critical
    readonly property color networkDown:    critical
    readonly property color audioMuted:     muted
    readonly property color tempCritical:   critical
    readonly property color idleActive:     "#80848aa5"
    readonly property color powerPerf:      critical
    readonly property color powerBalanced:  hsv(222)
    readonly property color powerSaver:     good
    readonly property color tailscaleOn:    good
    readonly property color langBg:         "#80646e7d"  // neutral grey, off-shell

    readonly property string fontFamily: "Cozette"
    readonly property string fontStyle: "Regular"
    readonly property int fontSize: 13
    readonly property color fg: "#ffffff"
}
