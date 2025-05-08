{ config, ... }:

{
  services.hardware.openrgb.enable = true;
  services.resolved.enable = true;
  services.tailscale.enable = true;
  services.udisks2.enable = true;
  services.devmon.enable = true;
}