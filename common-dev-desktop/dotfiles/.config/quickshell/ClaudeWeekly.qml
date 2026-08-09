import QtQuick

// Claude Code weekly (7-day, all-models) usage-limit utilisation.
Pill {
    color: Theme.claudeWklyBg
    visible: parsed.pct !== ""
    text: "cc wk " + parsed.pct + "%" + (parsed.when ? " (" + parsed.when + ")" : "")
    widthSample: "cc wk 100% (Wed 00:00)"

    QtObject {
        id: parsed
        property string pct: ""
        property string when: ""
    }

    Poller {
        id: poll
        interval: 300000
        command: ["sh", "-c", "$HOME/.config/quickshell/scripts/cc-usage.sh seven_day"]
        onValueChanged: {
            const parts = value.split("|");
            parsed.pct = parts[0] || "";
            parsed.when = parts[1] || "";
        }
    }
}
