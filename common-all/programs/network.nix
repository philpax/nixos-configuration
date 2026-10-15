{ config, pkgs, ... }:

{
  services.tailscale.enable = true;
  services.tailscale.useRoutingFeatures = "both";
}
