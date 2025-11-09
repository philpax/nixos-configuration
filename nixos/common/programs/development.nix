{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Development utilities
    git
    ripgrep
    direnv
    helix
  ];

  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };
}
