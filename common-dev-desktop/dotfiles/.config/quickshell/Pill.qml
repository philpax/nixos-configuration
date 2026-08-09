import QtQuick

// Coloured background block matching waybar's per-module pill look.
// For the common "single text label" case, set `text`; the pill auto-sizes.
// Set `widthSample` to a worst-case string (e.g. "cpu 100%") to lock the pill's
// width so neighbours don't shuffle as the value changes.
// For custom content (Workspaces, Tray), leave `text` empty, place your own
// children, and set `contentWidth` so the pill can size itself.
Rectangle {
    property alias text: label.text
    property alias label: label
    property real contentWidth: 0
    property string widthSample: ""
    property int leftPadding: 8
    property int rightPadding: 8

    implicitWidth: {
        const w = text.length > 0
            ? Math.max(label.implicitWidth, sampleMetrics.advanceWidth)
            : contentWidth;
        return w + leftPadding + rightPadding;
    }
    implicitHeight: Theme.barHeight
    color: "transparent"

    TextMetrics {
        id: sampleMetrics
        font.family: Theme.fontFamily
        font.styleName: Theme.fontStyle
        font.pixelSize: Theme.fontSize
        text: widthSample
    }

    BitmapText {
        id: label
        visible: parent.text.length > 0
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: parent.leftPadding
        anchors.rightMargin: parent.rightPadding
        horizontalAlignment: Text.AlignHCenter
    }
}
