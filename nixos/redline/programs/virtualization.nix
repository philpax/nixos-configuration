{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # QEMU/KVM related
    qemu
    OVMF

    # Wine related
    wineWowPackages.stable
    winetricks
  ];
}