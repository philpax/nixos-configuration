import QtQuick
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.SystemTray

Pill {
    id: tray
    color: Theme.trayBg
    visible: SystemTray.items.values.length > 0
    contentWidth: row.implicitWidth

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: 8
        spacing: 6

        Repeater {
            model: SystemTray.items
            delegate: Item {
                required property SystemTrayItem modelData
                implicitWidth: Theme.barHeight - 4
                implicitHeight: Theme.barHeight

                IconImage {
                    anchors.centerIn: parent
                    width: Theme.barHeight - 8
                    height: Theme.barHeight - 8
                    source: modelData.icon
                    smooth: false
                }

                MouseArea {
                    id: mouseArea
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: function(mouse) {
                        if (mouse.button === Qt.LeftButton) {
                            modelData.activate();
                        } else if (mouse.button === Qt.MiddleButton) {
                            modelData.secondaryActivate();
                        } else {
                            const win = tray.QsWindow.window;
                            const pos = mouseArea.mapToItem(win.contentItem, 0, mouseArea.height);
                            modelData.display(win, pos.x, pos.y);
                        }
                    }
                }
            }
        }
    }
}
