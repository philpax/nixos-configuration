{ config, pkgs, ... }:

{
  environment.systemPackages = import ../packages/media.nix { inherit pkgs; };
}
