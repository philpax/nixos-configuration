import QtQuick
import Quickshell.Services.UPower

Pill {
    id: bat
    readonly property var dev: UPower.displayDevice
    visible: dev && dev.isLaptopBattery
    widthSample: "chg 100% (12:34)"

    // UPower reports 0 while it has no estimate yet (just plugged/unplugged, or
    // the rate is still settling), so render the percentage alone until it does.
    function remaining(seconds) {
        if (!seconds || seconds <= 0) return "";
        const h = Math.floor(seconds / 3600);
        const m = Math.floor(seconds / 60) % 60;
        return " (" + h + ":" + (m < 10 ? "0" + m : m) + ")";
    }

    color: {
        if (!dev) return "transparent";
        if (dev.state === UPowerDeviceState.Charging || dev.state === UPowerDeviceState.FullyCharged)
            return Theme.batteryCharging;
        if (dev.percentage < 0.15) return Theme.batteryCritical;
        return Theme.batteryBg;
    }
    text: {
        if (!dev) return "";
        const pct = Math.round(dev.percentage * 100);
        switch (dev.state) {
        case UPowerDeviceState.Charging:     return "chg " + pct + "%" + remaining(dev.timeToFull);
        case UPowerDeviceState.FullyCharged: return "plg " + pct + "%";
        default:                             return "bat " + pct + "%" + remaining(dev.timeToEmpty);
        }
    }
}
