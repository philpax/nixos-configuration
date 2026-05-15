import QtQuick
import Quickshell.Io

// Click to toggle. While active, holds a systemd-inhibit lock against idle/sleep
// so swayidle's timer can't fire.
Pill {
    id: inhibit
    property bool active: false
    color: active ? Theme.idleActive : Theme.idleBg
    text: active ? "idl on" : "idl"

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
