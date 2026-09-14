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
        // Step in 5% increments, snapping to the grid first so an off-grid
        // volume (e.g. 63%) lands on 65%/60% rather than 68%/58%.
        property int wheelAccum: 0
        onWheel: wheel => {
            if (!audio.sink || !audio.sink.audio) return;
            wheelAccum += wheel.angleDelta.y;
            const steps = Math.trunc(wheelAccum / 120);
            if (steps === 0) return;
            wheelAccum -= steps * 120;
            const percent = Math.round(audio.sink.audio.volume * 100);
            const current = steps > 0 ? Math.floor(percent / 5) * 5 : Math.ceil(percent / 5) * 5;
            const next = Math.max(0, Math.min(100, current + steps * 5));
            audio.sink.audio.volume = next / 100;
        }
    }
}
