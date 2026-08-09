{ config, ... }:

{
  # No OpenRGB SDK server: it holds the SMBus open, and concurrent SMBus
  # access is the main documented cause of DIMM SPD corruption. Nothing here
  # needs a live RGB daemon — the no-rgb oneshot owns the bus at boot and
  # then exits. Its udev rules still come in via services.udev.packages in
  # services/no-rgb-service.nix.
  services.hardware.openrgb.enable = false;
  services.resolved.enable = true;
  services.udisks2.enable = true;
  services.devmon.enable = true;
}