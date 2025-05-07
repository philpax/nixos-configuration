{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Network tools
    awscli2
    tailscale
    croc

    # Torrent client
    rtorrent
  ];
}