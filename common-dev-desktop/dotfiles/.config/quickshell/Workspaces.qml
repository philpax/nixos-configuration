import QtQuick

// Workspace list for one screen. Pass screenName="DP-1" (or similar) to
// filter to that niri output; empty string shows all.
//
// Workspaces are drag-reorderable: grab a pill and drop it elsewhere to move
// it, which issues niri's MoveWorkspaceToIndex. A plain click still focuses.
//
// Why a local ListModel instead of binding straight to NiriIPC.workspaces:
// qml-niri rebuilds its model with beginResetModel/endResetModel on every
// WorkspacesChanged, which destroys any in-flight ListView move/displace
// transitions (everything snaps). So we mirror niri into a local ListModel and
// reconcile it with minimal move/insert/remove ops, letting the ListView
// animate. During a drag we suppress reconciliation entirely and drive the
// reorder locally, committing to niri only on drop.
Pill {
    id: ws
    property string screenName: ""
    color: "transparent"
    contentWidth: listView.contentWidth
    leftPadding: 0
    rightPadding: 0

    // True while the user is dragging a pill; pauses niri->local sync so the
    // optimistic local reorder isn't clobbered mid-gesture.
    property bool dragging: false

    ListModel { id: wsModel }

    function makeRow(w) {
        return {
            wid: w.id,
            wname: w.name || "",
            widx: w.index,
            output: w.output,
            isActive: w.isActive,
            isFocused: w.isFocused,
            isUrgent: w.isUrgent
        }
    }

    // Reconcile wsModel toward niri's current state with minimal structural
    // edits, so the ListView animates rather than rebuilding from scratch.
    function syncFromNiri() {
        if (ws.dragging)
            return
        const all = NiriIPC.workspaces
        if (!all)
            return

        const desired = []
        for (let i = 0; i < all.count; i++) {
            const w = all.get(i)
            if (ws.screenName === "" || w.output === ws.screenName)
                desired.push(w)
        }

        const has = function(list, id, key) {
            for (let j = 0; j < list.length; j++)
                if (list[j][key] === id)
                    return true
            return false
        }

        // 1. Drop workspaces that no longer exist on this screen.
        for (let r = wsModel.count - 1; r >= 0; r--)
            if (!has(desired, wsModel.get(r).wid, "id"))
                wsModel.remove(r)

        // 2. Append newcomers (final position is fixed up in step 3).
        for (let a = 0; a < desired.length; a++) {
            let exists = false
            for (let e = 0; e < wsModel.count; e++)
                if (wsModel.get(e).wid === desired[a].id) { exists = true; break }
            if (!exists)
                wsModel.append(makeRow(desired[a]))
        }

        // 3. Reorder into niri's order (selection-sort style; n is tiny).
        for (let p = 0; p < desired.length; p++) {
            if (wsModel.get(p).wid !== desired[p].id) {
                for (let s = p + 1; s < wsModel.count; s++) {
                    if (wsModel.get(s).wid === desired[p].id) {
                        wsModel.move(s, p, 1)
                        break
                    }
                }
            }
        }

        // 4. Refresh per-workspace state in place (no structural change).
        for (let u = 0; u < desired.length && u < wsModel.count; u++) {
            wsModel.setProperty(u, "wname", desired[u].name || "")
            wsModel.setProperty(u, "widx", desired[u].index)
            wsModel.setProperty(u, "isActive", desired[u].isActive)
            wsModel.setProperty(u, "isFocused", desired[u].isFocused)
            wsModel.setProperty(u, "isUrgent", desired[u].isUrgent)
        }
    }

    Component.onCompleted: syncFromNiri()

    Connections {
        target: NiriIPC.workspaces
        function onCountChanged() { ws.syncFromNiri() }
        function onModelReset() { ws.syncFromNiri() }
        function onDataChanged() { ws.syncFromNiri() }
    }

    ListView {
        id: listView
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        height: Theme.barHeight
        width: contentWidth
        orientation: ListView.Horizontal
        interactive: false
        spacing: 12
        model: wsModel

        // Animate pills sliding out of the way as a drag passes over them.
        displaced: Transition {
            NumberAnimation { property: "x"; duration: 160; easing.type: Easing.OutCubic }
        }
        moveDisplaced: Transition {
            NumberAnimation { property: "x"; duration: 160; easing.type: Easing.OutCubic }
        }

        delegate: Item {
            id: cell
            required property var model
            required property int index

            width: content.cellWidth
            height: listView.height
            z: content.held ? 2 : 1

            Item {
                id: content
                property bool held: dragHandler.active
                property real cellWidth: nameMetrics.advanceWidth
                    + (indexLabel.visible ? indexMetrics.advanceWidth + 2 : 0) + 12

                width: cell.width
                height: cell.height
                opacity: held ? 0.85 : 1.0
                scale: held ? 1.08 : 1.0
                Behavior on scale { NumberAnimation { duration: 120 } }

                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 1
                    color: "#ffffff"
                    visible: cell.model.isActive
                }

                // TextMetrics queries the underlying font geometry, which is
                // more reliable than Text.implicitWidth when the requested
                // pixelSize falls outside Cozette's bitmap strikes.
                TextMetrics {
                    id: nameMetrics
                    font: nameLabel.font
                    text: nameLabel.text
                }
                TextMetrics {
                    id: indexMetrics
                    font: indexLabel.font
                    text: indexLabel.text
                }

                Item {
                    id: labels
                    anchors.centerIn: parent
                    implicitWidth: nameMetrics.advanceWidth
                        + (indexLabel.visible ? indexMetrics.advanceWidth + 2 : 0)
                    implicitHeight: nameLabel.implicitHeight

                    BitmapText {
                        id: nameLabel
                        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                        text: cell.model.wname || String(cell.model.widx)
                        color: cell.model.isFocused ? "#ffffff" : "#aaaaaa"
                    }
                    // Numeric subscript — suppressed when the workspace has no
                    // name (the index would duplicate what's in nameLabel).
                    BitmapText {
                        id: indexLabel
                        visible: !!cell.model.wname && cell.model.wname !== String(cell.model.widx)
                        anchors {
                            left: nameLabel.right
                            leftMargin: 2
                            baseline: nameLabel.baseline
                            baselineOffset: 4
                        }
                        text: String(cell.model.widx)
                        color: "#80ffffff"
                        font.pixelSize: Math.max(Theme.fontSize - 4, 8)
                    }
                }

                HoverHandler {
                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onTapped: NiriIPC.focusWorkspaceById(cell.model.wid)
                }

                DragHandler {
                    id: dragHandler
                    target: content
                    xAxis.enabled: true
                    yAxis.enabled: false

                    onActiveChanged: {
                        if (active) {
                            ws.dragging = true
                        } else {
                            // Commit the final position (1-based per monitor),
                            // then resume sync. We deliberately don't sync here:
                            // the move is async, so reconciling against niri's
                            // not-yet-updated state would briefly snap the order
                            // back. The local model already shows the intended
                            // order; niri's WorkspacesChanged confirms it.
                            NiriIPC.moveWorkspaceToIndex(cell.model.wid, cell.index + 1)
                            ws.dragging = false
                        }
                    }
                }

                // While held, follow the pointer and detect which slot we're
                // over, reordering the local model live so neighbours animate.
                onXChanged: {
                    if (!held)
                        return
                    // content is reparented into listView.contentItem while
                    // held, so its x is already in content coordinates.
                    const centre = content.x + content.width / 2
                    const target = listView.indexAt(centre, listView.height / 2)
                    if (target >= 0 && target !== cell.index)
                        wsModel.move(cell.index, target, 1)
                }

                // Reparenting to the content item (preserving scene position)
                // lets the dragged pill float above the row and move freely
                // while its empty slot animates with the others.
                states: State {
                    name: "held"
                    when: content.held
                    ParentChange { target: content; parent: listView.contentItem }
                    PropertyChanges { target: content; z: 1000 }
                }

                // On release, glide back home rather than snapping.
                transitions: Transition {
                    to: ""
                    NumberAnimation {
                        target: content
                        properties: "x,y"
                        to: 0
                        duration: 160
                        easing.type: Easing.OutCubic
                    }
                }
            }
        }
    }
}
