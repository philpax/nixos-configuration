{ config, pkgs, ... }:

{
  imports = [
    ../../common-dev/programs/development.nix
  ];

  # Add redline-specific development tools here if needed
  environment.systemPackages = with pkgs; [
  ];
}