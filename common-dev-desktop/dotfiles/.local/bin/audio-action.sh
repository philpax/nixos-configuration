#!/usr/bin/env bash
dump=$(pw-dump)

# The default sink is whatever wpctl/wireplumber recorded in the "default"
# metadata object; priority.session is only a hint used to pick it initially.
default_name=$(printf '%s' "$dump" | jq -r '
    [.[] | select(.type == "PipeWire:Interface:Metadata" and .props."metadata.name" == "default")]
    | last // {}
    | (.metadata // [])
    | map(select(.key == "default.audio.sink"))
    | last.value.name // empty
')

sink_items=$(printf '%s' "$dump" | jq -r --arg def "$default_name" '
    [.[] | select(.type == "PipeWire:Interface:Node" and .info.props."media.class" == "Audio/Sink")]
    | map({id: .id, name: .info.props."node.name", desc: .info.props."node.description"})
    | sort_by(.desc)
    | .[]
    | "\(if .name == $def then "●" else "○" end) \(.desc)\t\(.id)"
')

action=$(printf '%s\n' "$sink_items" "Mute/Unmute" | fuzzel --dmenu --prompt "Audio device:")
[ -z "$action" ] && exit 0

if [ "$action" = "Mute/Unmute" ]; then
    wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
    exit 0
fi

sink_id=$(echo "$action" | awk -F'\t' '{print $2}')
[ -z "$sink_id" ] && exit 0
wpctl set-default "$sink_id"
