# Pinned nixpkgs-unstable, for packages whose stable-channel versions are too
# far behind. Import it with the host system and use the packages directly:
# `(import ../common-all/nixpkgs-unstable.nix { system = pkgs.stdenv.hostPlatform.system; }).rerun`.
#
# To bump: take the rev from refs/heads/nixpkgs-unstable and recompute the hash
#   git ls-remote https://github.com/NixOS/nixpkgs refs/heads/nixpkgs-unstable
#   nix-prefetch-url --unpack --type sha256 \
#     https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz
let
  pin = {
    # nixpkgs-unstable at 2026-11-06 (channel 26.11.20261106.4fe25e1).
    rev = "4fe25e12eb9f4c744966dd3de5a05246cf098601";
    sha256 = "0gry3mzkvpk7y7h08v5l503lxr333cnwr38x3qzqnm25sq6qxd2s";
  };
in
{ system }:
import (builtins.fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/${pin.rev}.tar.gz";
  inherit (pin) sha256;
}) { inherit system; }
