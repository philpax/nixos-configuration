#!/bin/sh
# Print a Claude Code usage-limit utilisation percentage (integer).
# Usage: cc-usage.sh five_hour|seven_day
#
# Reads the OAuth access token Claude Code keeps in ~/.claude/.credentials.json
# and queries the same usage endpoint the `/usage` command uses. The response is
# cached in /tmp for ~60s so the two bar modules share a single request.
field="$1"
creds="$HOME/.claude/.credentials.json"
cache="/tmp/cc-usage-$(id -u).json"
[ -f "$creds" ] || exit 0

# Refresh the cache when missing, empty, or older than a minute.
if [ ! -s "$cache" ] || [ -n "$(find "$cache" -mmin +1 2>/dev/null)" ]; then
    tok=$(jq -r '.claudeAiOauth.accessToken' "$creds" 2>/dev/null)
    [ -n "$tok" ] && [ "$tok" != "null" ] || exit 0
    resp=$(curl -s --max-time 5 https://api.anthropic.com/api/oauth/usage \
        -H "Authorization: Bearer $tok" \
        -H "anthropic-beta: oauth-2025-04-20")
    # Only overwrite the cache with a response that parses as expected.
    if printf '%s' "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
        printf '%s' "$resp" > "$cache"
    fi
fi

[ -s "$cache" ] || exit 0
jq -r --arg f "$field" '.[$f].utilization // empty | floor' "$cache" 2>/dev/null
