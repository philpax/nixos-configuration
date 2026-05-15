import QtQuick

// Workspace list for one screen. Pass screenName="DP-1" (or similar) to
// filter to that niri output; empty string shows all.
Pill {
    id: ws
    property string screenName: ""
    color: "transparent"
    contentWidth: row.implicitWidth
    leftPadding: 0
    rightPadding: 0

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        spacing: 12

        Repeater {
            model: NiriIPC.workspaces
            delegate: Item {
                id: wsItem
                required property var model
                required property int index

                visible: ws.screenName === "" || wsItem.model.output === ws.screenName
                implicitWidth: content.implicitWidth + 12
                implicitHeight: Theme.barHeight

                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 1
                    color: "#ffffff"
                    visible: wsItem.model.isActive
                }

                // TextMetrics queries the underlying font geometry, which is
                // more reliable than Text.implicitWidth when the requested
                // pixelSize falls outside Cozette's bitmap strikes.
                TextMetrics {
                    id: nameMetrics
                    font: nameLabel.font
                    text: nameLabel.text
                }
                TextMetrics {
                    id: indexMetrics
                    font: indexLabel.font
                    text: indexLabel.text
                }

                Item {
                    id: content
                    anchors.centerIn: parent
                    implicitWidth: nameMetrics.advanceWidth + (indexLabel.visible ? indexMetrics.advanceWidth + 2 : 0)
                    implicitHeight: nameLabel.implicitHeight

                    BitmapText {
                        id: nameLabel
                        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                        text: wsItem.model.name || String(wsItem.model.index)
                        color: wsItem.model.isFocused ? "#ffffff" : "#aaaaaa"
                    }
                    // Numeric subscript — suppressed when the workspace has no
                    // name (the index would duplicate what's in nameLabel).
                    BitmapText {
                        id: indexLabel
                        visible: !!wsItem.model.name && wsItem.model.name !== String(wsItem.model.index)
                        anchors {
                            left: nameLabel.right
                            leftMargin: 2
                            baseline: nameLabel.baseline
                            baselineOffset: 4
                        }
                        text: String(wsItem.model.index)
                        color: "#80ffffff"
                        font.pixelSize: Math.max(Theme.fontSize - 4, 8)
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: NiriIPC.focusWorkspaceById(wsItem.model.id)
                }
            }
        }
    }
}
