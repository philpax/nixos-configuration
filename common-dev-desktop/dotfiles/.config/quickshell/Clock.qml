import QtQuick
import Quickshell

Pill {
    id: root
    color: Theme.clockBg
    text: Qt.formatDateTime(clock.date, "ddd yyyy-MM-dd HH:mm:ss")

    // Whether the pointer is over the pill or the popup. Gated through
    // closeTimer below so a brief gap between the two (as the cursor moves
    // from one window to the other) doesn't collapse the popup mid-transit.
    readonly property bool wantOpen: hover.hovered || calendar.hovered

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    HoverHandler {
        id: hover
    }

    Calendar {
        id: calendar
        anchorItem: root
    }

    Timer {
        id: closeTimer
        interval: 150
        onTriggered: calendar.visible = false
    }

    onWantOpenChanged: {
        if (wantOpen) {
            closeTimer.stop();
            calendar.visible = true;
        } else {
            closeTimer.start();
        }
    }
}
