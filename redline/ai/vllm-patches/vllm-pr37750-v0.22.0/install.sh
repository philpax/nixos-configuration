#!/bin/bash
# ===========================================================================
# vLLM PR #37750 — torch.Event device= fix (lean v0.22.0 diff-apply)
#
# Stock v0.22.0 constructs torch.cuda.Events without an explicit `device=`
# in multiple places in gpu_model_runner.py and ubatching.py. The event
# gets bound to whatever device is current at construction time on rank 0,
# so when rank 1 later .synchronize()'s it, CUDA fires `unspecified launch
# failure` (the trace bottoms out in cuEventQuery, async error pattern).
#
# Symptom on this rig: TP=2 Qwen3.6-27B (qwen3_next class) deterministically
# kills rank 1 mid-decode at varying token counts, regardless of MTP on/off.
# Open upstream issue tracking: vllm-project/vllm#41190, sibling #40756.
#
# Origin: vllm-project/vllm PR #37750 (closed-as-slop 2026-03-25, technically
# correct but rejected for being agent-generated). Rebased onto v0.22.0 line
# numbers; the pooling-path hunk uses `async_output_copy_stream.device`
# instead of `raw_pooler_output.device` per gemini-code-assist's review
# (PoolerOutput is a Tensor|list union, .device access is unsafe).
#
# Idempotent; fail-loud. Drop when this lands upstream in a pinned release:
#   gh api repos/vllm-project/vllm/issues/41190 --jq '.state, .closed_at'
# ===========================================================================
set -euo pipefail

SITE=/usr/local/lib/python3.12/dist-packages
PATCHDIR=/etc/club3090/pr37750

# already-applied / upstream-merged detection (no-op cleanly).
# `sampled_token_ids.device` is one of the unique strings the patch
# introduces — its presence on AsyncGPUModelRunnerOutput's event line is
# the marker.
if grep -q "torch.Event(device=sampled_token_ids.device)" \
     "$SITE/vllm/v1/worker/gpu_model_runner.py" 2>/dev/null; then
  echo "[pr37750] torch.Event device= fix already present — skipping overlay."
  exit 0
fi

cd "$SITE"
if patch -p1 --forward --batch --reject-file=/tmp/pr37750.rej < "$PATCHDIR/pr37750-v0.22.0.patch"; then
  echo "[pr37750] torch.Event device= fix applied cleanly."
else
  echo "[pr37750] FATAL: #37750 diff did not apply to this image — refusing to boot." >&2
  cat /tmp/pr37750.rej >&2 2>/dev/null || true
  exit 1
fi
