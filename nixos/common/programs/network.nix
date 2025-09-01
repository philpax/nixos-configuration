{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    tailscale
    croc
  ];
  programs.ssh.startAgent = true;
  services.tailscale.enable = true;
  services.tailscale.useRoutingFeatures = "both";
}