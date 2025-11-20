{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Version control and code search
    git
    ripgrep
    direnv

    # Text editors
    helix

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

    # Development utilities
    gnumake
    cmake
    extra-cmake-modules

    # Build dependencies and toolchain
    openssl
    openssl.dev
    pkg-config
    clang
    lld
    llvmPackages_17.bintools
    libgcc
  ];

  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };
}
