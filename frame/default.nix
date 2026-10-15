# Frame's system-manager configuration, built without flakes. rebuild.sh
# builds and activates it; see README.md.
let
  fetchPinned = repo: file:
    let pin = builtins.fromJSON (builtins.readFile file); in
    builtins.fetchTarball {
      url = "https://github.com/${repo}/archive/${pin.rev}.tar.gz";
      inherit (pin) sha256;
    };
  nixpkgs = fetchPinned "NixOS/nixpkgs" ./nixpkgs.json;
  systemManager = fetchPinned "numtide/system-manager" ./system-manager.json;
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
