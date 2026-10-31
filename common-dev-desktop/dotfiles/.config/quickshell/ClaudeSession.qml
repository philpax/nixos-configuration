import QtQuick

// Claude Code 5-hour usage limit.
Pill {
    color: Theme.claude5hBg
    visible: poll.value !== ""
    text: "cc 5h " + (parsed.pct !== ""
        ? parsed.pct + "%" + (parsed.status === "ok"
            ? (parsed.when ? " (" + parsed.when + ")" : "") : " (" + parsed.stale + ")")
        : parsed.failure)
    widthSample: "cc 5h 100% (Wed 00:00)"

    QtObject {
        id: parsed
        readonly property var parts: poll.value.split("|")
        readonly property string pct: parts[0] || ""
        readonly property string when: parts[1] || ""
        readonly property string status: parts[2] || "error"
        readonly property string failure: status === "auth" ? "sign in"
            : status === "rate-limit" ? "rate limited" : "unavailable"
        readonly property string stale: status === "auth" ? "stale: auth"
            : status === "rate-limit" ? "stale: limited" : "stale"
    }

    Poller {
        id: poll
        interval: 300000
        command: ["sh", "-c", "$HOME/.config/quickshell/scripts/cc-usage.sh five_hour"]
    }
}
