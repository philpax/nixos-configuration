import QtQuick
import Quickshell.Services.UPower

Pill {
    id: bat
    readonly property var dev: UPower.displayDevice
    visible: dev && dev.isLaptopBattery
    widthSample: "chg 100%"
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
        case UPowerDeviceState.Charging:     return "chg " + pct + "%";
        case UPowerDeviceState.FullyCharged: return "plg " + pct + "%";
        default:                             return "bat " + pct + "%";
        }
    }
}
