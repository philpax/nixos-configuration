#!/usr/bin/env bash
# Update the pinned poolside llama.cpp rev and rebuild the flake.
#
# Usage: ./update.sh [ref]
#   ref: a branch, tag, or commit sha of poolsideai/llama.cpp (default: laguna)
#
# Resolves the ref to a full commit sha, rewrites the pin in flake.nix (flake
# inputs must be literal strings, so the rev can't live in a separate file),
# and relocks the input. Building is left to nixos-rebuild. Commit flake.nix
# and flake.lock afterwards.
set -euo pipefail

upstream=https://github.com/poolsideai/llama.cpp
ref=${1:-laguna}

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

old=$(sed -nE 's|.*"github:poolsideai/llama\.cpp/([0-9a-f]{40})".*|\1|p' flake.nix)
if [[ -z $old ]]; then
    echo "error: could not find the pinned rev in flake.nix" >&2
    exit 1
fi
if [[ $rev == "$old" ]]; then
    echo "Already pinned to $rev; nothing to do."
    exit 0
fi

echo "Updating poolside llama.cpp: $old -> $rev"
sed -i "s|github:poolsideai/llama\.cpp/$old|github:poolsideai/llama.cpp/$rev|" flake.nix

nix flake update poolside-llama-cpp

echo "Done. Commit flake.nix and flake.lock, then nixos-rebuild switch."
