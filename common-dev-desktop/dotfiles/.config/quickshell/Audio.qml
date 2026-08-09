import QtQuick
import Quickshell.Io
import Quickshell.Services.Pipewire

Pill {
    id: audio
    readonly property var sink: Pipewire.defaultAudioSink
    widthSample: "vol 100%"
    color: sink && sink.audio && sink.audio.muted ? Theme.audioMuted : Theme.audioBg
    text: {
        if (!sink || !sink.audio) return "vol ?";
        if (sink.audio.muted) return "vol mute";
        return "vol " + Math.round(sink.audio.volume * 100) + "%";
    }

    PwObjectTracker { objects: audio.sink ? [audio.sink] : [] }

    Process { id: pavuctl; command: ["pavucontrol"] }
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: pavuctl.running = true
    }
}
