#!/bin/sh
# Print OpenAI Codex usage-limit utilisation as `<percent>|<Day HH:MM>`, where
# the second field is the local time the weekly (7-day) limit renews (empty if
# unknown). Read-only: querying /wham/usage does not consume quota.
#
# Reads the OAuth access token + account id Maki keeps at
# ~/.local/state/makima/auth/openai.json (the same tokens `codex login` issues)
# and queries the same endpoint Codex itself polls. The response is cached in
# /tmp for ~5min to keep the cadence gentle, mirroring cc-usage.sh.
auth="$HOME/.local/state/makima/auth/openai.json"
cache="/tmp/oai-usage-$(id -u).json"
[ -f "$auth" ] || exit 0

# Refresh the cache when missing, empty, or older than five minutes.
if [ ! -s "$cache" ] || [ -n "$(find "$cache" -mmin +5 2>/dev/null)" ]; then
    tok=$(jq -r '.access // empty' "$auth" 2>/dev/null)
    acct=$(jq -r '.account_id // empty' "$auth" 2>/dev/null)
    [ -n "$tok" ] || exit 0
    if [ -n "$acct" ]; then
        resp=$(curl -s --max-time 5 https://chatgpt.com/backend-api/wham/usage \
            -H "Authorization: Bearer $tok" \
            -H "Accept: application/json" \
            -H "ChatGPT-Account-Id: $acct" \
            -H "User-Agent: codex-cli")
    else
        resp=$(curl -s --max-time 5 https://chatgpt.com/backend-api/wham/usage \
            -H "Authorization: Bearer $tok" \
            -H "Accept: application/json" \
            -H "User-Agent: codex-cli")
    fi
    # Only overwrite the cache with a response that parses as expected.
    if printf '%s' "$resp" | jq -e '.rate_limit' >/dev/null 2>&1; then
        printf '%s' "$resp" > "$cache"
    fi
fi

[ -s "$cache" ] || exit 0
# Prefer the 7-day secondary window; fall back to the primary window. reset_at
# is a unix timestamp.
out=$(jq -r '
    (.rate_limit.secondary_window // .rate_limit.primary_window // empty)
    | "\((.used_percent // 0) | floor)|\(.reset_at // "")"
' "$cache" 2>/dev/null)
[ -n "$out" ] || exit 0
pct=${out%%|*}
epoch=${out#*|}
when=""
[ -n "$epoch" ] && when=$(date -d "@$epoch" "+%a %H:%M" 2>/dev/null)
printf '%s|%s\n' "$pct" "$when"
