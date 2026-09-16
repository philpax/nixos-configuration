#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v python3 &>/dev/null; then
    exec python3 "$DIR/sync.py" "$@"
else
    # Fresh installs have flakes disabled until the first rebuild.
    exec nix --extra-experimental-features 'nix-command flakes' run nixpkgs#python3 -- "$DIR/sync.py" "$@"
fi
