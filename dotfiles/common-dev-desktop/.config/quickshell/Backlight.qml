import QtQuick

Pill {
    color: Theme.backlightBg
    visible: poll.value !== "" && poll.value !== "n/a"
    text: "bri " + poll.value + "%"
    widthSample: "bri 100%"
    Poller {
        id: poll
        interval: 10000
        command: ["sh", "-c", "for d in /sys/class/backlight/*/brightness; do [ -r \"$d\" ] || continue; m=${d%/brightness}/max_brightness; b=$(cat \"$d\"); x=$(cat \"$m\"); echo $((b*100/x)); exit; done; echo n/a"]
    }
}
