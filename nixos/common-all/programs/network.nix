{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    tailscale
    croc
  ];
  services.tailscale.enable = true;
  services.tailscale.useRoutingFeatures = "both";
}