{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Development utilities
    git
    ripgrep
    direnv
  ];

  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };
}