# Runtime toolchain for the locally built Strata-family engines (strata, maya, xolotl).
#
# The engines are built in place from each source tree's `nix develop` shell, which locks nixpkgs at the
# rev below. That shell is not a GC root, so its glibc, CUDA and libstdc++ can be collected out from under
# the binaries. Pinning the same rev here makes the system closure own those paths, and `wrap` runs an
# engine through the pinned loader so it never depends on its ELF interpreter or RUNPATH surviving.
#
# Keep `rev` and `narHash` in step with the engines' flake.lock. A newer pin also works (glibc, libstdc++
# and CUDA 13.0 are backward compatible); an older one does not.
{ pkgs }:

let
  rev = "6510408d147d8c5e6d76043e899e9251756f6a75";
  narHash = "sha256-XK4KceonkwD8LuMAt/vNrz982mXJM5jeHAxMwsUXXAQ=";
  pinned = import (builtins.fetchTarball {
    url = "https://github.com/nixos/nixpkgs/archive/${rev}.tar.gz";
    sha256 = narHash;
  }) {
    system = "x86_64-linux";
    config.allowUnfree = true;
    config.cudaSupport = true;
  };
  cudaPackages = pinned.cudaPackages_13_0;
  glibc = pinned.glibc;
  libraryPath = pkgs.lib.concatStringsSep ":" [
    "${glibc}/lib"
    "${pinned.stdenv.cc.cc.lib}/lib"
    "${cudaPackages.backendStdenv.cc.cc.lib}/lib"
    "${cudaPackages.cudatoolkit}/lib"
    "/run/opengl-driver/lib"
  ];
in
{
  # A wrapper script that runs `exe` against the pinned libraries, ahead of whatever LD_LIBRARY_PATH the
  # caller set; the engine's own RUNPATH ($ORIGIN-relative libraries) is still searched after.
  #
  # By default the engine is exec'd directly, which requires its ELF interpreter to be the pinned glibc's
  # (referenced here, so the closure keeps it). `loader = true` runs it through the pinned ld.so instead,
  # for a binary whose interpreter is some other glibc; /proc/self/exe then names ld.so, which breaks
  # engines that locate files next to themselves (Strata's libstrata_kq.so loader does).
  wrap = { name, exe, loader ? false }: pkgs.writeShellScript name (
    if loader then ''
      exec ${glibc}/lib/ld-linux-x86-64.so.2 --library-path ${libraryPath} ${exe} "$@"
    '' else ''
      export LD_LIBRARY_PATH=${libraryPath}
      exec ${exe} "$@"
    ''
  );
}
