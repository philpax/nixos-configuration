import QtQuick

// Claude Code 5-hour ("session") usage-limit utilisation.
Pill {
    color: Theme.claude5hBg
    visible: poll.value !== ""
    text: "cc 5h " + poll.value + "%"
    widthSample: "cc 5h 100%"
    Poller {
        id: poll
        interval: 60000
        command: ["sh", "-c", "$HOME/.config/quickshell/scripts/cc-usage.sh five_hour"]
    }
}
