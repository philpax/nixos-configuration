import QtQuick
import Quickshell

// Month-view calendar popup, anchored below the item passed as `anchorItem`.
// Intended for hover-triggered display (see Clock.qml).
PopupWindow {
    id: popup
    required property Item anchorItem
    readonly property alias hovered: contentHover.hovered

    // Months offset from the current month; reset back to 0 whenever the
    // popup is closed so it always reopens showing the current month.
    property int monthOffset: 0
    onVisibleChanged: if (!visible) monthOffset = 0

    implicitWidth: 200
    implicitHeight: 230
    color: "transparent"
    visible: false
    grabFocus: false

    anchor {
        item: anchorItem
        edges: Edges.Bottom
        gravity: Edges.Bottom
        adjustment: PopupAdjustment.Slide
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Theme.barBg.r, Theme.barBg.g, Theme.barBg.b, 0.9)
        border.color: Theme.barBorder
        border.width: 1
        radius: 4

        HoverHandler {
            id: contentHover
        }

        Column {
            id: column
            anchors.centerIn: parent
            spacing: 6

            readonly property date today: new Date()
            readonly property date monthDate: new Date(today.getFullYear(), today.getMonth() + popup.monthOffset, 1)
            readonly property int firstWeekday: monthDate.getDay()

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10

                BitmapText {
                    text: "‹"
                    anchors.verticalCenter: parent.verticalCenter
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: popup.monthOffset -= 1
                    }
                }

                BitmapText {
                    width: 110
                    horizontalAlignment: Text.AlignHCenter
                    text: Qt.formatDate(column.monthDate, "MMMM yyyy")

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: popup.monthOffset !== 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: popup.monthOffset = 0
                    }
                }

                BitmapText {
                    text: "›"
                    anchors.verticalCenter: parent.verticalCenter
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: popup.monthOffset += 1
                    }
                }
            }

            Grid {
                columns: 7
                spacing: 4

                Repeater {
                    model: ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
                    delegate: BitmapText {
                        width: 22
                        horizontalAlignment: Text.AlignHCenter
                        opacity: 0.6
                        text: modelData
                    }
                }

                Repeater {
                    model: 42
                    delegate: Item {
                        id: cell
                        required property int index
                        readonly property int dayOffset: index - column.firstWeekday
                        readonly property date cellDate: new Date(column.monthDate.getFullYear(), column.monthDate.getMonth(), dayOffset + 1)
                        readonly property bool inMonth: cellDate.getMonth() === column.monthDate.getMonth()
                        readonly property bool isToday: cellDate.toDateString() === column.today.toDateString()
                        width: 22
                        height: 20

                        Rectangle {
                            anchors.fill: parent
                            radius: 3
                            color: Theme.good
                            visible: cell.isToday
                        }

                        BitmapText {
                            anchors.centerIn: parent
                            opacity: cell.inMonth ? 1.0 : 0.3
                            text: cell.cellDate.getDate()
                        }
                    }
                }
            }
        }
    }
}
