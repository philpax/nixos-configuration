{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    awscli2
    rtorrent
  ];
}