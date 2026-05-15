import QtQuick
import Quickshell.Io

// Periodic command poller. Spawns `command` every `interval` ms, captures
// stdout, exposes trimmed result as `value`. Use for /proc and CLI-tool
// modules where event-driven data isn't available.
Item {
    id: poller
    property var command: []
    property int interval: 5000
    property string value: ""
    property bool active: true

    Process {
        id: proc
        command: poller.command
        stdout: StdioCollector {
            onStreamFinished: poller.value = this.text.trim()
        }
    }

    Timer {
        interval: poller.interval
        running: poller.active
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!proc.running) proc.running = true
    }
}
