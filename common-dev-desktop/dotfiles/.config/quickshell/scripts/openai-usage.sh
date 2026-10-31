#!/bin/sh
# Print OpenAI weekly usage as <percent>|<local reset time>|<status>.
# Status is ok, auth, rate-limit, or error. Failed refreshes retain cached data.
# Credentials belong to Maki; this script does not refresh or change them.
auth="$HOME/.local/state/makima/auth/openai.json"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell"
cache="$cache_dir/oai-usage.json"
result="$cache.status"

[ -f "$auth" ] || [ -s "$cache" ] || exit 0
umask 077
mkdir -p "$cache_dir" || { printf '||error\n'; exit 0; }
exec 9>"$cache.lock"
flock -w 6 9 || { printf '||error\n'; exit 0; }
status=$(cat "$result" 2>/dev/null)
attempted=$(stat -c %Y "$result" 2>/dev/null || printf 0)
if [ ! -s "$result" ] || [ "$(($(date +%s) - attempted))" -ge 300 ] || [ "$auth" -nt "$result" ]; then
    status=auth
    response=$(mktemp "$cache.XXXXXX") || { printf '||error\n'; exit 0; }
    trap 'rm -f "$response"' EXIT
    trap 'exit 1' HUP INT TERM
    tok=$(jq -r '.access // empty | strings | select(length > 0)' "$auth" 2>/dev/null)
    acct=$(jq -r '.account_id // empty | strings' "$auth" 2>/dev/null)
    if [ -n "$tok" ]; then
        set --
        [ -z "$acct" ] || set -- -H "ChatGPT-Account-Id: $acct"
        code=$(curl -s --max-time 5 https://chatgpt.com/backend-api/wham/usage \
            -H "Authorization: Bearer $tok" \
            -H "Accept: application/json" \
            -H "User-Agent: codex-cli" "$@" \
            -o "$response" -w '%{http_code}') || code=000
        status=error
        case "$code" in
            401|403) status=auth ;;
            429) status=rate-limit ;;
            200)
                if jq -e '(.rate_limit.secondary_window // .rate_limit.primary_window).used_percent
                    | numbers | . >= 0 and . <= 100' "$response" >/dev/null 2>&1 \
                    && mv "$response" "$cache"; then
                    status=ok
                fi
                ;;
        esac
    fi
    printf '%s\n' "$status" > "$response" && mv "$response" "$result"
fi
case "$status" in ok|auth|rate-limit|error) ;; *) status=error ;; esac

# Prefer the weekly secondary window; some plans expose only a primary window.
pct=$(jq -r '(.rate_limit.secondary_window // .rate_limit.primary_window).used_percent
    | numbers | select(. >= 0 and . <= 100) | floor' "$cache" 2>/dev/null)
[ -n "$pct" ] || { [ "$status" != ok ] || status=error; }
epoch=$(jq -r '(.rate_limit.secondary_window // .rate_limit.primary_window).reset_at
    // empty | numbers' "$cache" 2>/dev/null)
when=""
[ -n "$epoch" ] && when=$(date -d "@$epoch" "+%a %H:%M" 2>/dev/null)
printf '%s|%s|%s\n' "$pct" "$when" "$status"
