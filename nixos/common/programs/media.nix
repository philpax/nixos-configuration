{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    ffmpeg-full
    yt-dlp
    imagemagick
  ];
}