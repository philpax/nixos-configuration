#!/bin/sh
command -v nvidia-smi >/dev/null 2>&1 || exit 0
util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits)
printf '{"text": "%s%%", "tooltip": "GPU utilization: %s%%"}\n' "$util" "$util"
