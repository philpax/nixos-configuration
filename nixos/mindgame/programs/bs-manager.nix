{ ... }:

# nixpkgs pins bs-manager's DepotDownloader fork (Iluhadesu/DepotDownloader,
# used to download Beat Saber depots) to a 2024 commit that no longer works.
# nixpkgs master bumps it to current fork master (upstream 3.4.0, .NET 9);
# until that reaches our channel, build the package definition straight from
# the master commit that introduced it.
#
# Once the fix has reached our nixpkgs channel, delete this file.

{
  # Timebomb: force a reevaluation of this workaround a month after it was
  # added (2026-07-11). If the fix has reached the channel by then, delete
  # this file; otherwise, bump the date below.
  assertions = [
    {
      assertion = builtins.currentTime < 1786406400; # 2026-08-11 UTC
      message = ''
        The bs-manager DepotDownloader overlay (nixos/mindgame/programs/bs-manager.nix)
        is over a month old. Check whether the DepotDownloader bump has reached the channel:

          grep version /nix/var/nix/profiles/per-user/root/channels/nixos/pkgs/by-name/bs/bs-manager/depotdownloader/default.nix

        If it shows 3.4.0, delete the overlay file; otherwise bump the timebomb date.
      '';
    }
  ];

  nixpkgs.overlays = [
    (final: prev:
      let
        # The nixpkgs master commit that bumped bs-manager's DepotDownloader.
        rev = "3431bb1194dd3c1a78b1f4d23cd3068ef83c5aef";
        masterFile = file: hash:
          prev.fetchurl {
            url = "https://raw.githubusercontent.com/NixOS/nixpkgs/${rev}/pkgs/by-name/bs/bs-manager/depotdownloader/${file}";
            inherit hash;
          };
        depotdownloaderDir = prev.runCommand "depotdownloader-nixpkgs-master" { } ''
          mkdir $out
          cp ${masterFile "default.nix" "sha256-3rTxDCGG3jqkSvaWHNcKF0nB26yjRzgE9FeOE1tqUnI="} $out/default.nix
          cp ${masterFile "deps.json" "sha256-mB7w9ecjyiwwpH89+qUwRs0N+EQ5/uGs3HJqafJyLdE="} $out/deps.json
        '';
      in
      {
        bs-manager = prev.bs-manager.overrideAttrs (old: {
          passthru = old.passthru // {
            depotdownloader = final.callPackage depotdownloaderDir { };
          };
        });
      })
  ];
}
