import QtQuick

Pill {
    color: Theme.gpuBg
    visible: parsed.text !== ""
    text: "gpu " + parsed.text
    widthSample: "gpu 100%"

    QtObject {
        id: parsed
        property string text: ""
        property string tooltip: ""
    }

    Poller {
        interval: 5000
        command: ["sh", "-c", "$HOME/.config/quickshell/scripts/gpu.sh"]
        onValueChanged: {
            if (!value) { parsed.text = ""; return; }
            try {
                const j = JSON.parse(value);
                parsed.text = j.text ?? "";
                parsed.tooltip = j.tooltip ?? "";
            } catch (e) {
                parsed.text = "";
            }
        }
    }
}
