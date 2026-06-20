import QtQuick

Pill {
    color: Theme.diskBg
    text: "disk " + (poll.value || "?") + "%"
    widthSample: "disk 100%"
    Poller {
        id: poll
        interval: 30000
        command: ["sh", "-c", "duf --json / | jq -r '.[] | select(.mount_point==\"/\") | (.used*100/.total) | floor'"]
    }
}
