import QtQuick

// Claude Code 5-hour ("session") usage-limit utilisation.
Pill {
    color: Theme.claude5hBg
    visible: parsed.pct !== ""
    text: "cc 5h " + parsed.pct + "%" + (parsed.when ? " (" + parsed.when + ")" : "")
    widthSample: "cc 5h 100% (Wed 00:00)"

    QtObject {
        id: parsed
        property string pct: ""
        property string when: ""
    }

    Poller {
        id: poll
        interval: 300000
        command: ["sh", "-c", "$HOME/.config/quickshell/scripts/cc-usage.sh five_hour"]
        onValueChanged: {
            const parts = value.split("|");
            parsed.pct = parts[0] || "";
            parsed.when = parts[1] || "";
        }
    }
}
