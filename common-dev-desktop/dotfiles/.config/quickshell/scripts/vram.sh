#!/bin/sh
# See gpu.sh: nvidia-smi outlives the GPU it reports on.
command -v nvidia-smi >/dev/null 2>&1 || exit 0
info=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null) || exit 0
used=$(echo "$info" | cut -d',' -f1 | tr -d ' ')
total=$(echo "$info" | cut -d',' -f2 | tr -d ' ')
case "$used" in '' | *[!0-9]*) exit 0 ;; esac
case "$total" in '' | 0 | *[!0-9]*) exit 0 ;; esac
pct=$((used * 100 / total))
printf '{"text": "%s%%", "tooltip": "VRAM: %s/%s MiB (%s%%)"}\n' "$pct" "$used" "$total" "$pct"
