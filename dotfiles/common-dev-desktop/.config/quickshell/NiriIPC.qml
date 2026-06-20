pragma Singleton
import QtQuick
import Niri 0.1

// Singleton wrapping the qml-niri IPC client with reconnect logic.
//
// Niri (from qml-niri) is a bare QObject without a default property, so child
// objects (Timer) live on QtObject properties rather than as direct children.
QtObject {
    id: root

    readonly property var workspaces: niri.workspaces
    readonly property var focusedWindow: niri.focusedWindow
    function focusWorkspaceById(id) { niri.focusWorkspaceById(id) }
    function isConnected() { return niri.isConnected() }

    // Move a workspace (referenced by stable id) to a 1-based index on its
    // monitor. niri has no typed wrapper for this in qml-niri, so we go through
    // sendRawAction with the raw niri-ipc Action schema. Referencing by id (not
    // the focused workspace) lets us reorder without stealing focus.
    function moveWorkspaceToIndex(id, index) {
        return niri.sendRawAction({
            "MoveWorkspaceToIndex": { "index": index, "reference": { "Id": id } }
        })
    }

    // The bar in waybar froze every few hours because waybar's niri/workspaces
    // module has no socket error handling: when niri's event-stream socket
    // disconnected (silently, under load), the module sat on its last-known
    // state. Explicit disconnect/error handlers + a watchdog fix that
    // (noctalia-shell#2200).
    property Niri niri: Niri {
        Component.onCompleted: connect()

        onConnected: {
            console.info("niri ipc: connected")
            root.reconnectTimer.stop()
        }
        onDisconnected: {
            console.warn("niri ipc: disconnected; will retry")
            root.reconnectTimer.restart()
        }
        onErrorOccurred: function(err) {
            console.warn("niri ipc error:", err)
            root.reconnectTimer.restart()
        }
    }

    property Timer reconnectTimer: Timer {
        interval: 2000
        repeat: true
        triggeredOnStart: false
        onTriggered: {
            if (!root.niri.isConnected()) {
                console.info("niri ipc: reconnecting")
                root.niri.connect()
            } else {
                stop()
            }
        }
    }

    // Watchdog against silent socket disconnects where neither disconnected()
    // nor errorOccurred() fires.
    property Timer watchdog: Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: {
            if (!root.niri.isConnected()) {
                console.warn("niri ipc: watchdog found dead socket")
                root.reconnectTimer.restart()
            }
        }
    }
}
