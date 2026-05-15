#!/bin/sh
command -v nvidia-smi >/dev/null 2>&1 || exit 0
info=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits)
used=$(echo "$info" | cut -d',' -f1 | tr -d ' ')
total=$(echo "$info" | cut -d',' -f2 | tr -d ' ')
pct=$((used * 100 / total))
printf '{"text": "%s%%", "tooltip": "VRAM: %s/%s MiB (%s%%)"}\n' "$pct" "$used" "$total" "$pct"
