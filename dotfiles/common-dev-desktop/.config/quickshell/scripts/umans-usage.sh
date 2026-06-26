#!/bin/sh
# Print Umans Code usage for the quickshell bar as:
#   <concurrency>|<tokens_in>|<tokens_out>|<status>|<boxed_remaining>
#
# concurrency      — "1/4" (in-flight / soft cap), "" if unavailable
# tokens_in/out    — today's daily bucket, compact (e.g. "1.2M", "340K")
# status           — "" (normal), "low" (deprioritized), "boxed" (auto-paused)
# boxed_remaining  — "3h12m" when boxed, "" otherwise
#
# Reads ~/.umans-token (first line) for auth. Responses cached in /tmp for ~5min.
# Max plan has no request window; only concurrency (4, burst 8) is enforced.
# Token totals are informational daily burn from the history endpoint.

token_file="$HOME/.umans-token"
cache_usage="/tmp/umans-usage-$(id -u).json"
cache_hist="/tmp/umans-usage-hist-$(id -u).json"
base="https://api.code.umans.ai"

[ -f "$token_file" ] || exit 0
tok=$(head -1 "$token_file" 2>/dev/null)
[ -n "$tok" ] || exit 0

# Refresh cache when missing, empty, or older than 5 minutes.
if [ ! -s "$cache_usage" ] || [ -n "$(find "$cache_usage" -mmin +5 2>/dev/null)" ]; then
    resp=$(curl -s --max-time 5 "$base/v1/usage" -H "Authorization: Bearer $tok")
    printf '%s' "$resp" | jq -e '.usage' >/dev/null 2>&1 && printf '%s' "$resp" > "$cache_usage"
fi

if [ ! -s "$cache_hist" ] || [ -n "$(find "$cache_hist" -mmin +5 2>/dev/null)" ]; then
    today=$(date -u +%Y-%m-%d)
    resp=$(curl -s --max-time 5 \
        "$base/v1/usage/history?from=${today}T00:00:00Z&to=${today}T23:59:59Z&granularity=day" \
        -H "Authorization: Bearer $tok")
    if printf '%s' "$resp" | jq -e 'if .buckets then .buckets elif .data then .data elif type == "array" then . else false end' >/dev/null 2>&1; then
        printf '%s' "$resp" > "$cache_hist"
    fi
fi

[ -s "$cache_usage" ] || exit 0

# --- Parse /v1/usage for concurrency + priority ---
cc_limit=$(jq -r '.limits.concurrency.limit // empty' "$cache_usage" 2>/dev/null)
cc_now=$(jq -r '.usage.concurrent_sessions // empty' "$cache_usage" 2>/dev/null)
prio_low=$(jq -r '.usage.priority.low // false' "$cache_usage" 2>/dev/null)
boxed_until=$(jq -r '.usage.priority.boxed_until // empty' "$cache_usage" 2>/dev/null)

concurrency=""
[ -n "$cc_limit" ] && [ -n "$cc_now" ] && concurrency="${cc_now}/${cc_limit}"

# Build status + boxed countdown.
status=""
boxed_remaining=""
if [ -n "$boxed_until" ] && [ "$boxed_until" != "null" ]; then
    now=$(date +%s)
    target=$(date -d "$boxed_until" +%s 2>/dev/null)
    if [ -n "$target" ] && [ "$target" -gt "$now" ]; then
        status="boxed"
        diff=$((target - now))
        hours=$((diff / 3600))
        mins=$(((diff % 3600) / 60))
        boxed_remaining=$(printf '%dh%02dm' "$hours" "$mins")
    fi
elif [ "$prio_low" = "true" ]; then
    status="low"
fi

# --- Parse /v1/usage/history for today's tokens ---
format_tokens() {
    awk -v n="$1" 'BEGIN {
        if (n >= 1000000) printf "%.1fM", n/1000000
        else if (n >= 100000) printf "%.0fK", n/1000
        else if (n >= 1000) printf "%.1fK", n/1000
        else if (n > 0) printf "%d", n
    }'
}

tokens_in=""
tokens_out=""
if [ -s "$cache_hist" ]; then
    tin=$(jq -r '
        (if .buckets then .buckets
         elif .data then .data
         elif type == "array" then .
         else [] end)
        | map(.tokens_in_total // .tokens_in // 0)
        | (add // 0)
    ' "$cache_hist" 2>/dev/null)
    tout=$(jq -r '
        (if .buckets then .buckets
         elif .data then .data
         elif type == "array" then .
         else [] end)
        | map(.tokens_out // 0)
        | (add // 0)
    ' "$cache_hist" 2>/dev/null)
    [ -n "$tin" ] && [ "$tin" != "null" ] && [ "$tin" -gt 0 ] 2>/dev/null && tokens_in=$(format_tokens "$tin")
    [ -n "$tout" ] && [ "$tout" != "null" ] && [ "$tout" -gt 0 ] 2>/dev/null && tokens_out=$(format_tokens "$tout")
fi

printf '%s|%s|%s|%s|%s\n' "$concurrency" "$tokens_in" "$tokens_out" "$status" "$boxed_remaining"
