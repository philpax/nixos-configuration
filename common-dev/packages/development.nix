{ pkgs }:
let
  # Built from upstream's flake, tracking `mistress` HEAD; bump `rev` to update.
  makima = (builtins.getFlake
    "git+https://github.com/lun-4/makima?rev=1c018ff3f42bdafeab86c6fb1b4bdda01257763f")
    .packages.${pkgs.stdenv.hostPlatform.system}.default;
in
with pkgs; [
  # Programming languages and build tools
  rustup
  go
  gcc
  python3
  python3Packages.pip
  poetry
  nodejs_22
  pnpm
  rye
  uv
  stylua
  python3Packages.huggingface-hub
  python3Packages.hf-xet # Xet-accelerated `hf download` for large model pulls

  # Development utilities
  gnumake
  cmake
  gh
  (pkgs.callPackage ./ttt.nix { })
  makima

  # Build dependencies and toolchain
  openssl
  openssl.dev
  pkg-config
  clang
  lld
  libgcc
]
