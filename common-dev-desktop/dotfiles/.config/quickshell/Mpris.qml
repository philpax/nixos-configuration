import QtQuick
import Quickshell.Services.Mpris

Pill {
    id: mpris
    readonly property var player: Mpris.players && Mpris.players.values.length > 0 ? Mpris.players.values[0] : null
    visible: player !== null
    color: Theme.mprisBg
    text: {
        if (!player) return "";
        const artist = player.trackArtist || "?";
        const title = player.trackTitle || "?";
        const stateIcon = player.playbackState === MprisPlaybackState.Playing ? "▶" : "⏸";
        return stateIcon + " " + artist + " - " + title;
    }
    label.elide: Text.ElideRight
    label.maximumLineCount: 1
    label.width: Math.min(label.implicitWidth, 400)

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: if (mpris.player && mpris.player.canTogglePlaying) mpris.player.togglePlaying()
    }
}
