{ pkgs }:
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

  # Build dependencies and toolchain
  openssl
  openssl.dev
  pkg-config
  clang
  lld
  libgcc
]
