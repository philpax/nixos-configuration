{ ... }:
let
  nixpkgs-xr = import
    (builtins.fetchTarball "https://github.com/nix-community/nixpkgs-xr/archive/665e1550f5411756b3cb678dbdca878f164814ea.tar.gz");
in
{
  imports = [ nixpkgs-xr.nixosModules.nixpkgs-xr ];
}
