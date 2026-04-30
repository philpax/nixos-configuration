# Override xdg-desktop-portal with the 1.21.1 prerelease, which is supposed
# to fix the Realtime-portal memory leak (flatpak/xdg-desktop-portal#1416)
# that pegs a CPU and burns >100G of swap before getting OOM-killed.
final: prev: {
  xdg-desktop-portal = prev.xdg-desktop-portal.overrideAttrs (old: rec {
    version = "1.21.1";

    src = prev.fetchFromGitHub {
      owner = "flatpak";
      repo = "xdg-desktop-portal";
      tag = version;
      hash = "sha256-svr8uWJ32YdeoNK35vpHxLme+KIoLHqaXun0atiZEv0=";
    };

    # nixpkgs ships its patch list inline; we keep the still-needed ones
    # (icon/sound validation, installed-tests-path) and replace the
    # nix-pkgdatadir-env patch with a 1.21-rebased version. trash-test was
    # merged upstream and is dropped.
    patches =
      let
        upstreamPatches = "${prev.path}/pkgs/development/libraries/xdg-desktop-portal";
      in
      [
        (prev.replaceVars "${upstreamPatches}/fix-icon-validation.patch" {
          inherit (builtins) storeDir;
        })
        (prev.replaceVars "${upstreamPatches}/fix-sound-validation.patch" {
          inherit (builtins) storeDir;
        })
        "${upstreamPatches}/installed-tests-path.patch"
        ./nix-pkgdatadir-env.patch
      ];

    # Skip the upstream test suite — it's flaky in sandboxed builds and
    # we just want the binary.
    doCheck = false;
  });
}
