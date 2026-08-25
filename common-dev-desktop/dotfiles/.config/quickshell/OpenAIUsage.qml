import QtQuick

// OpenAI Codex weekly (7-day) usage-limit utilisation.
Pill {
    color: Theme.openaiUsageBg
    visible: parsed.pct !== ""
    text: "oai wk " + parsed.pct + "%" + (parsed.when ? " (" + parsed.when + ")" : "")
    widthSample: "oai wk 100% (Wed 00:00)"

    QtObject {
        id: parsed
        property string pct: ""
        property string when: ""
    }

    Poller {
        id: poll
        interval: 300000
        command: ["sh", "-c", "$HOME/.config/quickshell/scripts/openai-usage.sh"]
        onValueChanged: {
            const parts = value.split("|");
            parsed.pct = parts[0] || "";
            parsed.when = parts[1] || "";
        }
    }
}
