#!/usr/bin/env bash
# Frame's counterpart to `nixos-rebuild build|switch`: build the system-manager
# configuration in default.nix and, for switch, register and activate it.
# Requires a device prepared with bootstrap.sh.
set -euo pipefail

usage() { echo "usage: $0 build|switch" >&2; exit 2; }
[[ $# -eq 1 ]] || usage
case $1 in build | switch) ;; *) usage ;; esac

here=$(cd "$(dirname "$0")" && pwd)
out=$(nix-build --no-out-link "$here")
echo "$out"
[[ $1 == switch ]] || exit 0

sudo "$out/bin/register-profile"
sudo "$out/bin/activate"
