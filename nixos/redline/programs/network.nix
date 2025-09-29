{ config, pkgs, unstable, ... }:

{
  environment.systemPackages = with pkgs; [
    awscli2
    rtorrent
    unstable.icloudpd
  ];
}