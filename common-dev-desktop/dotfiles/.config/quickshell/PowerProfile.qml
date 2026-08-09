import QtQuick

Pill {
    visible: poll.value !== "" && poll.value !== "n/a"
    color: {
        switch (poll.value) {
        case "performance": return Theme.powerPerf;
        case "balanced":    return Theme.powerBalanced;
        case "power-saver": return Theme.powerSaver;
        default:            return "transparent";
        }
    }
    text: "pwr"
    Poller {
        id: poll
        interval: 10000
        command: ["sh", "-c", "command -v powerprofilesctl >/dev/null && powerprofilesctl get || echo n/a"]
    }
}
