import QtQuick

// Claude Code weekly (7-day, all-models) usage-limit utilisation.
Pill {
    color: Theme.claudeWklyBg
    visible: poll.value !== ""
    text: "cc wk " + poll.value + "%"
    widthSample: "cc wk 100%"
    Poller {
        id: poll
        interval: 60000
        command: ["sh", "-c", "$HOME/.config/quickshell/scripts/cc-usage.sh seven_day"]
    }
}
