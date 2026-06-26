import QtQuick

// Umans Code usage: concurrency, daily token burn (in/out), and rate-limit
// status. Hidden when there's no token or no concurrency data. Turns red
// when deprioritized (priority.low) or auto-paused (boxed).
Pill {
    color: parsed.status === "boxed" || parsed.status === "low"
           ? Theme.critical
           : Theme.umansUsageBg
    visible: parsed.concurrency !== ""
    text: parsed.status === "boxed"
          ? "umans boxed " + parsed.boxedRemaining
          : "umans " + parsed.concurrency
            + (parsed.tokensIn !== "" ? " " + parsed.tokensIn + "/" + parsed.tokensOut : "")
    widthSample: "umans 8/4 12.3M/340K"

    QtObject {
        id: parsed
        property string concurrency: ""
        property string tokensIn: ""
        property string tokensOut: ""
        property string status: ""
        property string boxedRemaining: ""
    }

    Poller {
        id: poll
        interval: 300000
        command: ["sh", "-c", "$HOME/.config/quickshell/scripts/umans-usage.sh"]
        onValueChanged: {
            const parts = value.split("|");
            parsed.concurrency = parts[0] || "";
            parsed.tokensIn = parts[1] || "";
            parsed.tokensOut = parts[2] || "";
            parsed.status = parts[3] || "";
            parsed.boxedRemaining = parts[4] || "";
        }
    }
}
