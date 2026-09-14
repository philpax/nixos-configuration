import QtQuick
import Quickshell

Pill {
    color: Theme.backlightBg
    visible: poll.value !== "" && poll.value !== "n/a"
    text: "bri " + poll.value + "%"
    widthSample: "bri 100%"
    Poller {
        id: poll
        interval: 10000
        command: ["sh", "-c", "for d in /sys/class/backlight/*/brightness; do [ -r \"$d\" ] || continue; m=${d%/brightness}/max_brightness; b=$(cat \"$d\"); x=$(cat \"$m\"); echo $(((b*100+x/2)/x)); exit; done; echo n/a"]
    }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        // Step in 5% increments, snapping to the grid in the scroll direction
        // (63% goes to 65%/60%). The displayed value is updated
        // optimistically so rapid scrolling doesn't read a stale poll result.
        property int wheelAccum: 0
        onWheel: wheel => {
            const value = parseInt(poll.value);
            if (isNaN(value)) return;
            wheelAccum += wheel.angleDelta.y;
            const steps = Math.trunc(wheelAccum / 120);
            if (steps === 0) return;
            wheelAccum -= steps * 120;
            const current = steps > 0 ? Math.floor(value / 5) * 5 : Math.ceil(value / 5) * 5;
            const next = Math.max(0, Math.min(100, current + steps * 5));
            Quickshell.execDetached(["brightnessctl", "set", next + "%"]);
            poll.value = String(next);
        }
    }
}
