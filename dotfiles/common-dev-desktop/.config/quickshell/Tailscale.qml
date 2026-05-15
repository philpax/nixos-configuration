import QtQuick
import Quickshell.Io

Pill {
    id: ts
    color: parsed.cls === "on" ? Theme.tailscaleOn : Theme.tailscaleBg
    text: parsed.text

    QtObject {
        id: parsed
        property string text: "ts"
        property string tooltip: ""
        property string cls: ""
    }

    Poller {
        interval: 2000
        command: ["sh", "-c", "fish $HOME/.config/quickshell/scripts/tailscale-exit.fish"]
        onValueChanged: {
            if (!value) return;
            try {
                const j = JSON.parse(value);
                parsed.text = j.text ?? "ts";
                parsed.tooltip = j.tooltip ?? "";
                parsed.cls = j.class ?? "";
            } catch (e) {}
        }
    }

    Process {
        id: toggleProc
        command: ["sh", "-c", "fish $HOME/.config/quickshell/scripts/tailscale-exit.fish toggle"]
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: toggleProc.running = true
    }
}
