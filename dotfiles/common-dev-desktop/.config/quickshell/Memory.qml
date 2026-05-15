import QtQuick

Pill {
    color: Theme.memoryBg
    text: "mem " + (poll.value || "?") + "%"
    widthSample: "mem 100%"
    Poller {
        id: poll
        interval: 5000
        command: ["sh", "-c", "awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf \"%d\", (t-a)*100/t}' /proc/meminfo"]
    }
}
