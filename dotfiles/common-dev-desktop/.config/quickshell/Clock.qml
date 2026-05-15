import QtQuick
import Quickshell

Pill {
    color: Theme.clockBg
    text: Qt.formatDateTime(clock.date, "ddd yyyy-MM-dd HH:mm:ss")

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }
}
