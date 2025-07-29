{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Programming languages and build tools
    rustup
    go
    gcc
    python3
    poetry
    nodejs_22
    rye
    uv

    # Development utilities
    git
    ripgrep
    direnv

    # Build dependencies
    openssl
    openssl.dev
    pkg-config
    clang
    llvmPackages_17.bintools
  ];

  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };
}