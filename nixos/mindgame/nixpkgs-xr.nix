{ ... }:
let
  nixpkgs-xr = import
    (builtins.fetchTarball "https://github.com/nix-community/nixpkgs-xr/archive/499bbd9ef425436982b44baed6ff497c84594374.tar.gz");
in
{
  imports = [ nixpkgs-xr.nixosModules.nixpkgs-xr ];
}
