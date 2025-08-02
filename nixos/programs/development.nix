{ config, pkgs, ... }:

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

    # Development utilities
    git
    ripgrep
    direnv
    gnumake
    cmake
    extra-cmake-modules

    # Build dependencies
    openssl
    openssl.dev
    pkg-config
    clang
    llvmPackages_17.bintools
    libgcc
  ];

  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };
}