#!/bin/sh
# Print Claude usage as <percent>|<local reset time>|<status>.
# Status is ok, auth, rate-limit, or error. Failed refreshes retain cached data.
# Usage: cc-usage.sh five_hour|seven_day
field="$1"
creds="$HOME/.claude/.credentials.json"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell"
cache="$cache_dir/cc-usage.json"
result="$cache.status"

# Hide unconfigured providers, but report missing credentials for a cached meter.
[ -f "$creds" ] || [ -s "$cache" ] || exit 0
umask 077
mkdir -p "$cache_dir" || { printf '||error\n'; exit 0; }

# The session and weekly meters share one request, including failed attempts.
exec 9>"$cache.lock"
flock -w 6 9 || { printf '||error\n'; exit 0; }
status=$(cat "$result" 2>/dev/null)
attempted=$(stat -c %Y "$result" 2>/dev/null || printf 0)
if [ ! -s "$result" ] || [ "$(($(date +%s) - attempted))" -ge 300 ] || [ "$creds" -nt "$result" ]; then
    status=auth
    response=$(mktemp "$cache.XXXXXX") || { printf '||error\n'; exit 0; }
    trap 'rm -f "$response"' EXIT
    trap 'exit 1' HUP INT TERM
    tok=$(jq -r '.claudeAiOauth.accessToken // empty | strings | select(length > 0)' "$creds" 2>/dev/null)
    if [ -n "$tok" ]; then
        code=$(curl -s --max-time 5 https://api.anthropic.com/api/oauth/usage \
            -H "Authorization: Bearer $tok" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -o "$response" -w '%{http_code}') || code=000
        status=error
        case "$code" in
            401|403) status=auth ;;
            429) status=rate-limit ;;
            200)
                if jq -e '
                    def valid: type == "number" and . >= 0 and . <= 100;
                    (.five_hour.utilization | valid) and
                    (.seven_day == null or (.seven_day.utilization | valid))
                ' "$response" >/dev/null 2>&1 && mv "$response" "$cache"; then
                    status=ok
                fi
                ;;
        esac
    fi
    printf '%s\n' "$status" > "$response" && mv "$response" "$result"
fi
case "$status" in ok|auth|rate-limit|error) ;; *) status=error ;; esac

pct=$(jq -r --arg f "$field" '.[$f].utilization | numbers | select(. >= 0 and . <= 100) | floor' "$cache" 2>/dev/null)
# A missing or malformed cached field must not appear as a current reading.
[ -n "$pct" ] || { [ "$status" != ok ] || status=error; }
iso=$(jq -r --arg f "$field" '.[$f].resets_at // empty | strings' "$cache" 2>/dev/null)
when=""
[ -n "$iso" ] && when=$(date -d "$iso" "+%a %H:%M" 2>/dev/null)
printf '%s|%s|%s\n' "$pct" "$when" "$status"
