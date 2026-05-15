import QtQuick

Pill {
    color: "transparent"
    text: NiriIPC.focusedWindow ? NiriIPC.focusedWindow.title : ""
    label.elide: Text.ElideRight
    label.maximumLineCount: 1
    label.width: Math.min(label.implicitWidth, 600)
}
