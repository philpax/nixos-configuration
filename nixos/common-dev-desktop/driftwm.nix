{ config, pkgs, ... }:

let
  driftwm-flake = builtins.getFlake "github:malbiruk/driftwm";
  driftwm = driftwm-flake.packages.x86_64-linux.default;
in
{
  services.displayManager.sessionPackages = [ driftwm ];

  environment.systemPackages = [
    driftwm
    pkgs.grim
    pkgs.xdg-desktop-portal-wlr
  ];
}
