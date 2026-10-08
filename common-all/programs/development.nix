{ config, pkgs, ... }:

{
  environment.systemPackages = import ../packages/development.nix { inherit pkgs; };
}
