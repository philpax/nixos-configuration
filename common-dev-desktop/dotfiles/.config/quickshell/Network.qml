import QtQuick

Pill {
    widthSample: "net ✗"
    color: poll.value === "disconnected" ? Theme.networkDown : Theme.networkBg
    text: {
        switch (poll.value) {
        case "connected": return "net";
        case "connecting": return "net…";
        case "disconnected": return "net ✗";
        default: return "net";
        }
    }
    Poller {
        id: poll
        interval: 5000
        // nmcli -t -f STATE general → connected / connecting / disconnected.
        // Fall back to checking default route if nmcli is missing.
        command: ["sh", "-c", "command -v nmcli >/dev/null && nmcli -t -f STATE general | head -1 || (ip route get 1.1.1.1 >/dev/null 2>&1 && echo connected || echo disconnected)"]
    }
}
