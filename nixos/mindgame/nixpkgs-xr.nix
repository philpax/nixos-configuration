{ ... }:
let
  nixpkgs-xr = import
    (builtins.fetchTarball "https://github.com/nix-community/nixpkgs-xr/archive/c6af4789d7801fa243205a8ce9b8e3feffbf42b4.tar.gz");
in
{
  imports = [ nixpkgs-xr.nixosModules.nixpkgs-xr ];
}
