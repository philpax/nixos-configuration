#!/usr/bin/env bash
default_id=$(pw-dump | jq -r '[.[] | select(.type == "PipeWire:Interface:Node" and .info.props."media.class" == "Audio/Sink")] | sort_by(.info.props."priority.session") | last | .id')

sink_items=$(pw-dump | jq -r --arg def "$default_id" '
    [.[] | select(.type == "PipeWire:Interface:Node" and .info.props."media.class" == "Audio/Sink")]
    | sort_by(.key)
    | .[]
    | {id: .id, desc: .info.props."node.description", muted: (.info.params.Props[0].mute // false)}
    | "\(.desc)\t\(.id)\t\(.muted)"
' | while IFS=$'\t' read -r desc id muted; do
    marker="○"
    [ "$id" = "$default_id" ] && marker="●"
    printf '%s %s\t%s\n' "$marker" "$desc" "$id"
done)

action=$(printf '%s\n' "$sink_items" "Mute/Unmute" | fuzzel --dmenu --prompt "Audio device:")
[ -z "$action" ] && exit 0

if [ "$action" = "Mute/Unmute" ]; then
    wpctl set-mute "$default_id" toggle
    exit 0
fi

sink_id=$(echo "$action" | awk -F'\t' '{print $2}')
[ -z "$sink_id" ] && exit 0
wpctl set-default "$sink_id"
