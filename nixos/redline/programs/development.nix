{ config, pkgs, ... }:

{
  # Most development tools are now configured in nixos/common/programs/development.nix
  # This file is kept for redline-specific development tools and overrides
  environment.systemPackages = with pkgs; [
    # Add redline-specific development tools here
  ];
}