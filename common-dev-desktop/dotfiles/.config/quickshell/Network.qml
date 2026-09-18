import QtQuick

Pill {
    id: net
    // "<state> <ip-or-dash> <rx-bytes-per-sec> <tx-bytes-per-sec>"; empty until the first poll.
    readonly property var fields: poll.value.length > 0 ? poll.value.split(" ") : []
    readonly property string linkState: fields.length > 0 ? fields[0] : ""
    readonly property string addr: fields.length > 1 && fields[1] !== "-" ? fields[1] : ""

    widthSample: "net 255.255.255.255 ↓999K ↑999K"
    color: linkState === "disconnected" ? Theme.networkDown : Theme.networkBg

    // Decimal units, as network tooling conventionally reports them. Keeps one
    // decimal below 10 so the reading stays four characters at every scale.
    function rate(bytes) {
        const units = ["B", "K", "M", "G"];
        let v = bytes, i = 0;
        while (v >= 1000 && i < units.length - 1) {
            v /= 1000;
            i++;
        }
        return (i > 0 && v < 10 ? v.toFixed(1) : Math.round(v)) + units[i];
    }

    text: {
        switch (linkState) {
        case "disconnected": return "net ✗";
        case "connecting": return "net…";
        }
        if (fields.length < 4) return "net";
        return "net " + (addr.length > 0 ? addr + " " : "")
            + "↓" + rate(parseFloat(fields[2]))
            + " ↑" + rate(parseFloat(fields[3]));
    }

    Poller {
        id: poll
        interval: 5000
        // nmcli -t -f STATE general → connected / connecting / disconnected,
        // falling back to the default route if nmcli is missing. The address and
        // the counters both track the physical link carrying the default route
        // (en*/eth*/wl*), so tailscale0 and the docker bridge don't stand in for
        // it. Throughput is two /proc/net/dev samples a second apart, so the
        // delta is bytes/sec; the colon is split off the interface name first
        // because the kernel drops the space after it once rx_bytes passes 8
        // digits.
        command: ["sh", "-c", "s=$(nmcli -t -f STATE general 2>/dev/null | head -1); [ -n \"$s\" ] || s=$(ip route get 1.1.1.1 >/dev/null 2>&1 && echo connected || echo disconnected); d=$(ip -4 route show default | awk '$5 ~ /^(en|eth|wl)/ {print $5; exit}'); a=$(ip -4 -o addr show dev \"$d\" scope global 2>/dev/null | awk '{split($4,x,\"/\"); print x[1]; exit}'); r() { awk '{gsub(/:/,\" \")} $1 ~ /^(en|eth|wl)/ {rx+=$2; tx+=$10} END {print rx+0, tx+0}' /proc/net/dev; }; set -- $(r); p=$1 q=$2; sleep 1; set -- $(r); echo \"$s ${a:--} $(($1-p)) $(($2-q))\""]
    }
}
