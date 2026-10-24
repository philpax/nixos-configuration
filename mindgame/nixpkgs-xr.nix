{ ... }:
let
  nixpkgs-xr = import
    (builtins.fetchTarball "https://github.com/nix-community/nixpkgs-xr/archive/8d169c67d1e73b8721711b3750ef75ba205e7fe1.tar.gz");
in
{
  imports = [ nixpkgs-xr.nixosModules.nixpkgs-xr ];
}
