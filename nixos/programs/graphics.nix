{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # NVIDIA packages
    linuxPackages.nvidia_x11
    cudatoolkit

    # Desktop utilities
    xdg-utils
  ];
}