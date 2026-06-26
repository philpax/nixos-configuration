import QtQuick
import Quickshell

// Top-anchored bar matching the waybar layout: workspaces+focused-window on the
// left, system stats on the right. One instance per screen via Variants.
PanelWindow {
    id: bar
    required property var modelData
    screen: modelData

    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: Theme.barHeight + Theme.barBorderHeight
    color: "transparent"

    Rectangle {
        anchors.fill: parent
        color: Theme.barBg

        // 3px bottom border, matching waybar's border-bottom.
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: Theme.barBorderHeight
            color: Theme.barBorder
        }

        // Left: workspaces, focused window.
        Row {
            anchors {
                left: parent.left
                top: parent.top
                bottom: parent.bottom
                bottomMargin: Theme.barBorderHeight
            }
            spacing: 0
            Workspaces { screenName: bar.screen ? bar.screen.name : "" }
            FocusedWindow {}
        }

        // Right: status modules. Order matches the waybar modules-right list.
        Row {
            anchors {
                right: parent.right
                top: parent.top
                bottom: parent.bottom
                bottomMargin: Theme.barBorderHeight
            }
            spacing: 0
            // Mpris {}
            IdleInhibitor {}
            Tailscale {}
            Audio {}
            Network {}
            PowerProfile {}
            ClaudeSession {}
            ClaudeWeekly {}
            UmansUsage {}
            Cpu {}
            Memory {}
            Disk {}
            Gpu {}
            Vram {}
            Backlight {}
            Battery {}
            Tray {}
            Clock {}
        }
    }
}
