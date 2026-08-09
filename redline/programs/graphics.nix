{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    linuxPackages.nvidia_x11
    cudatoolkit
  ];
}