{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Media tools
    ffmpeg-full
    yt-dlp
    imagemagick

    # Media servers
    jellyfin
    jellyfin-web
    jellyfin-ffmpeg
  ];
}