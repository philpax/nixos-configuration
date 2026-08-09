#!/usr/bin/env fish

# Waybar module for Tailscale exit node status
# Displays whether exit node is active and toggles on click

# Source fish config to get TAILSCALE_EXIT_NODE
source ~/.config/fish/config.fish 2>/dev/null

function get_status
    # Check if tailscale is using an exit node
    set -l status_json (tailscale status --json 2>/dev/null)

    if test $status -ne 0
        echo '{"text": "ts err", "tooltip": "Tailscale not running", "class": "error"}'
        return
    end

    # Check if ExitNodeStatus exists and is active
    set -l exit_node_active (echo $status_json | jq -r '.ExitNodeStatus.Online // false')

    if test "$exit_node_active" = "true"
        echo '{"text": "ts exit", "tooltip": "Exit node: '$TAILSCALE_EXIT_NODE'", "class": "on"}'
    else
        echo '{"text": "ts", "tooltip": "Exit node: off", "class": "off"}'
    end
end

function toggle
    # Check current status
    set -l status_json (tailscale status --json 2>/dev/null)
    set -l exit_node_active (echo $status_json | jq -r '.ExitNodeStatus.Online // false')

    if test "$exit_node_active" = "true"
        # Turn off exit node
        pkexec tailscale set --exit-node=
    else
        # Turn on exit node
        pkexec tailscale set --exit-node="$TAILSCALE_EXIT_NODE"
    end
end

switch "$argv[1]"
    case toggle
        toggle
    case '*'
        get_status
end
