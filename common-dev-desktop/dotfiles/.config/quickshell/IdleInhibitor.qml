import QtQuick
import Quickshell.Io

// Click to toggle. While active, holds a systemd-inhibit lock against idle/sleep
// so swayidle's timer can't fire.
//
// Quickshell restarts in place after a crash, so an inhibitor from the previous
// instance survives as an untracked child while this one starts inactive.
// Clear any such leftover on startup so the pill and the lock agree.
Pill {
    id: inhibit
    property bool active: false
    color: active ? Theme.idleActive : Theme.idleBg
    text: active ? "idl on" : "idl"

    Process {
        running: true
        command: ["pkill", "-f", "--", "^[^ ]*systemd-inhibit .*--why=quickshell idle inhibitor"]
    }

    Process {
        running: inhibit.active
        command: ["systemd-inhibit", "--what=idle:sleep:handle-lid-switch", "--why=quickshell idle inhibitor",
                  "sh", "-c", "while :; do sleep 86400; done"]
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: inhibit.active = !inhibit.active
    }
}
