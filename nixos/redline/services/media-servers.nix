{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    jellyfin
    jellyfin-web
    jellyfin-ffmpeg
  ];

  services.plex = {
    enable = true;
    openFirewall = true;
  };

  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };
}