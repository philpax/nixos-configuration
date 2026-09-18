#!/bin/sh
# nvidia-smi ships with the driver, so it is still on PATH after supergfxd has
# taken the dGPU off the bus; it then writes its failure to stdout and exits 9.
# Test the exit status and the shape of the output, not just the binary.
command -v nvidia-smi >/dev/null 2>&1 || exit 0
util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null) || exit 0
case "$util" in '' | *[!0-9]*) exit 0 ;; esac
printf '{"text": "%s%%", "tooltip": "GPU utilization: %s%%"}\n' "$util" "$util"
