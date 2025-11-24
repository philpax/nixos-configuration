{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Development utilities
    git
    ripgrep
    direnv
    helix
  ];
}
