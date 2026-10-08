{ config, pkgs, ... }:

{
  environment.systemPackages = import ../packages/network.nix { inherit pkgs; };
  services.tailscale.enable = true;
  services.tailscale.useRoutingFeatures = "both";
}