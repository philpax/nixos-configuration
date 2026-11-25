# Frame's system-manager configuration, built without flakes. nixpkgs and
# system-manager come from root's `nixos` and `system-manager` channels, which
# track the same release as the NixOS machines. rebuild.sh builds and activates
# it; see README.md.
{ nixpkgs ? <nixos>, systemManager ? <system-manager> }:
let
  pkgs = import nixpkgs { system = "aarch64-linux"; };
in
(import "${systemManager}/nix/lib.nix" {
  inherit nixpkgs;
  # lib.nix takes the userborn flake. Frame keeps SteamOS's accounts, and
  # system-manager's deactivation runs any userborn it finds on PATH, so an
  # empty package stands in.
  userborn.packages.aarch64-linux.default = pkgs.emptyDirectory;
}).makeSystemConfig {
  # system-manager types nixpkgs.overlays as `listOf anything`, whose merge
  # rewraps overlay functions and recurses on any overlay that uses `final`, so
  # the shared overlays go to nixpkgs directly.
  overlays = import ../common-all/overlays;
  modules = [ ./configuration.nix ];
}
