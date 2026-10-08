{ config, pkgs, ... }:

{
  environment.systemPackages = import ../packages/system.nix { inherit pkgs; };

  programs.nix-ld.enable = true;
  programs.fish.enable = true;
}
