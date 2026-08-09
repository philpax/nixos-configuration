{ config, pkgs, ... }:

{
  services.wivrn = {
    enable = true;
    openFirewall = true;
    # No runtime active at login — pick one explicitly with `vr-mode`
    # (see vr-mode.nix). Monado is socket-activated (also idle at startup).
    autoStart = false;
    package = pkgs.wivrn.override { cudaSupport = true; };
  };

  programs.steam.extraCompatPackages = [ pkgs.proton-ge-rtsp-bin ];
  environment.systemPackages = [ pkgs.wayvr ];
}
