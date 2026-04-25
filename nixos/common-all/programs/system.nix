{ config, pkgs, unstable, ... }:

{
  environment.systemPackages = with pkgs; [
    # Basic system tools
    wget
    fastfetch
    screen
    jq
    parallel

    # File system tools
    parted
    ntfs3g
    p7zip
    btrfs-progs

    # System monitoring
    lm_sensors

    # Better utilities
    fd
    bat
    eza
    zoxide
    dust
    duf
    bottom
    procs
    delta
    tldr
    hyperfine
    tokei
    fzf
    unstable.zellij # https://github.com/NixOS/nixpkgs/issues/512867 back to stable once mended
    broot

    # Misc
    xdg-utils

    # Shell integration
    any-nix-shell
  ];

  programs.nix-ld.enable = true;
  programs.fish.enable = true;
}
