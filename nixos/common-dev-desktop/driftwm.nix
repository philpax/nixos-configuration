{ config, pkgs, ... }:

let
  driftwm-flake = builtins.getFlake "git+file:///home/philpax/programming/driftwm";
  driftwm = driftwm-flake.packages.x86_64-linux.default;
in
{
  services.displayManager.sessionPackages = [ driftwm ];

  environment.systemPackages = [
    driftwm
    pkgs.grim
    pkgs.slurp
    pkgs.xdg-desktop-portal-wlr
  ];
}
