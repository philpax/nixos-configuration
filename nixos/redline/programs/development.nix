{ config, pkgs, ... }:

{
  imports = [
    ../../shared/programs/development.nix
  ];

  # Add redline-specific development tools here if needed
  environment.systemPackages = with pkgs; [
  ];
}