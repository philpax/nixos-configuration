{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # QEMU/KVM related
    qemu

    # Wine related
    wineWowPackages.stable
    winetricks
  ];
}