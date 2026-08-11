#!/usr/bin/env bash
# Update the pinned llama.cpp rev and rebuild the flake.
#
# Usage: ./update.sh [ref]
#   ref: a branch, tag, or commit sha of ggml-org/llama.cpp (default: master)
#
# Resolves the ref to a full commit sha, rewrites the pin in flake.nix (flake
# inputs must be literal strings, so the rev can't live in a separate file),
# and relocks the input. Then test-applies fattn-graph-reuse-fix.patch
# against the new rev and, only on success, advances flake.nix's
# patch-verified-rev marker — a failure leaves it pointing at the last rev
# it actually applied against, so the gap between it and the pinned rev is
# visible in a diff rather than silently building a broken patch. Building
# the package itself is left to nixos-rebuild. Commit flake.nix and
# flake.lock afterwards.
set -euo pipefail

upstream=https://github.com/ggml-org/llama.cpp
ref=${1:-master}

cd "$(dirname "$(readlink -f "$0")")"

if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
    rev=$ref
else
    echo "Resolving '$ref' against $upstream..."
    rev=$(git ls-remote "$upstream" "refs/heads/$ref" "refs/tags/$ref^{}" "refs/tags/$ref" \
        | head -n1 | cut -f1)
    if [[ -z $rev ]]; then
        echo "error: could not resolve '$ref' to a commit" >&2
        exit 1
    fi
fi

old=$(sed -nE 's|.*"github:ggml-org/llama\.cpp/([0-9a-f]{40})".*|\1|p' flake.nix)
if [[ -z $old ]]; then
    echo "error: could not find the pinned rev in flake.nix" >&2
    exit 1
fi
if [[ $rev == "$old" ]]; then
    echo "Already pinned to $rev; nothing to do."
    exit 0
fi

echo "Updating llama.cpp: $old -> $rev"
sed -i "s|github:ggml-org/llama\.cpp/$old|github:ggml-org/llama.cpp/$rev|" flake.nix

nix flake update llama-cpp

echo "Testing fattn-graph-reuse-fix.patch against $rev..."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" fetch -q --depth 1 "$upstream" "$rev"
git -C "$tmp" checkout -q FETCH_HEAD
if git -C "$tmp" apply --check "$(pwd)/fattn-graph-reuse-fix.patch"; then
    echo "Patch applies cleanly against $rev; advancing patch-verified-rev."
    sed -i -E "s|patch-verified-rev: [0-9a-f]{40}|patch-verified-rev: $rev|" flake.nix
else
    verified=$(sed -nE 's|.*patch-verified-rev: ([0-9a-f]{40}).*|\1|p' flake.nix)
    echo "warning: fattn-graph-reuse-fix.patch does NOT apply against $rev." >&2
    echo "         patch-verified-rev left at $verified — rebase the patch before building." >&2
fi

echo "Done. Commit flake.nix and flake.lock, then nixos-rebuild switch."
