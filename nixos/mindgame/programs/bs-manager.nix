{ ... }:

# nixpkgs pins bs-manager's DepotDownloader fork (Iluhadesu/DepotDownloader,
# used to download Beat Saber depots) to a 2024 commit that no longer works.
# Swap it for a build of current master, which has merged upstream 3.4.0 and
# moved to .NET 9 (see bs-manager/depotdownloader.nix).
#
# To bump again: update rev/hash in bs-manager/depotdownloader.nix, then
# regenerate the NuGet lockfile:
#
#   cd nixos/mindgame/programs
#   nix-build -E 'let pkgs = import <nixpkgs> { overlays = (import ./bs-manager.nix {}).nixpkgs.overlays; }; in pkgs.bs-manager.passthru.depotdownloader.passthru.fetch-deps'
#   ./result bs-manager/depotdownloader-deps.json

{
  nixpkgs.overlays = [
    (final: prev: {
      bs-manager = prev.bs-manager.overrideAttrs (old: {
        passthru = old.passthru // {
          depotdownloader = final.callPackage ./bs-manager/depotdownloader.nix { };
        };
      });
    })
  ];
}
