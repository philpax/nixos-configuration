# Development tools shared by NixOS (through programs/development.nix) and Frame.
{ pkgs, ... }:
{
  environment.systemPackages = import ./packages/development.nix { inherit pkgs; };
}
