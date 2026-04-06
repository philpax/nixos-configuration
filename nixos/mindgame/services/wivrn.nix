{ config, pkgs, ... }:

{
  services.wivrn = {
    enable = true;
    openFirewall = true;
    autoStart = true;
    package = pkgs.wivrn.override { cudaSupport = true; };
  };

  programs.steam.extraCompatPackages = [ pkgs.proton-ge-rtsp-bin ];
  environment.systemPackages = [ pkgs.wayvr ];
}
