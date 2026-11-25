#!/usr/bin/env bash
# Frame's counterpart to `nixos-rebuild build|switch`: build the system-manager
# configuration in default.nix and, for switch, register and activate it.
# Requires a device prepared with bootstrap.sh.
set -euo pipefail

usage() { echo "usage: $0 build|switch" >&2; exit 2; }
[[ $# -eq 1 ]] || usage
case $1 in build | switch) ;; *) usage ;; esac

# bootstrap.sh installs Nix here; shells that missed the profile scripts lack it.
PATH=/nix/var/nix/profiles/default/bin:$PATH

# Root's channels, set by `./deploy.sh --channel`, select the release.
channels=/nix/var/nix/profiles/per-user/root/channels
for channel in nixos system-manager; do
  if [[ ! -e $channels/$channel ]]; then
    echo "error: root has no $channel channel; run ./deploy.sh frame --channel nixos-YY.MM" >&2
    exit 1
  fi
done

here=$(cd "$(dirname "$0")" && pwd)
out=$(nix-build --no-out-link "$here" \
  -I "nixos=$channels/nixos" -I "system-manager=$channels/system-manager")
echo "$out"
[[ $1 == switch ]] || exit 0

sudo "$out/bin/register-profile"
sudo "$out/bin/activate"
