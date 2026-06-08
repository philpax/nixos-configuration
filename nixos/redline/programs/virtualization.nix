{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # QEMU/KVM related
    qemu

    # Wine related
    wineWow64Packages.stable
    winetricks
  ];
}