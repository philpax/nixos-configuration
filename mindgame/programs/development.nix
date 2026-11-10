{ config, pkgs, ... }:

let
  unstable = import ../../common-all/nixpkgs-unstable.nix {
    system = pkgs.stdenv.hostPlatform.system;
  };
in
{
  environment.systemPackages = [
    # Stable's rerun is 0.32; unstable carries 0.40.
    unstable.rerun
  ];
}
