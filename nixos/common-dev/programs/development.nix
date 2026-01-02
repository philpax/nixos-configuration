{ config, pkgs, unstable, ... }:

{
  environment.systemPackages = with pkgs; [
    # Programming languages and build tools
    rustup
    go
    gcc
    python3
    python3Packages.pip
    poetry
    nodejs_22
    rye
    uv
    stylua

    # Development utilities
    gnumake
    cmake
    extra-cmake-modules
    unstable.claude-code
    gh

    # Build dependencies and toolchain
    openssl
    openssl.dev
    pkg-config
    clang
    lld
    libgcc
  ];
}
