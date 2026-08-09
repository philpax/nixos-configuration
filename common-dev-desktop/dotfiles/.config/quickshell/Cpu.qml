import QtQuick

Pill {
    color: Theme.cpuBg
    text: "cpu " + (poll.value || "?") + "%"
    widthSample: "cpu 100%"
    Poller {
        id: poll
        interval: 5000
        // top -bn2 -d 0.5 gives a 0.5s sample window; first iteration is
        // cumulative-since-boot (useless), second is the delta.
        command: ["sh", "-c", "top -bn2 -d 0.5 | grep -m2 '^%Cpu' | tail -1 | awk '{printf \"%d\", $2+$4+0.5}'"]
    }
}
