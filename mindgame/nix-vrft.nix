{ lib, config, ... }:

# VR facial tracking packages from the nix-vrft flake
# (github.com/Naraenda/nix-vrft): Baballonia (eye/face tracking for social
# VR) and VRCFaceTracking (OSC bridge that feeds tracked data to VRChat).
#
# nix-vrft is flake-only — there's no default.nix to import. Match the
# flake's `baballonia-cuda` recipe instead: build against the exact nixpkgs
# revision the flake pins (its flake.lock), with CUDA support enabled. The
# readme explicitly recommends the pinned nixpkgs so the dotnet-based
# packages build against the same dependency set as upstream.
let
  # nix-vrft at develop (2026-08-18, "etvr: bump version to 0.3.0-beta-9").
  nix-vrft = builtins.fetchTarball {
    url = "https://github.com/Naraenda/nix-vrft/archive/47818c748e40cecc6510935536616e4d9e181037.tar.gz";
    sha256 = "1nwpwc9s9pxaqxa8yvzkh2h3l1agsjvklnh0m3j5vfllmqsxh9qy";
  };

  # nixpkgs revision pinned by nix-vrft's flake.lock (nixos-unstable as of
  # 2026-08-18, rev 567a49d). Building the packages against their own
  # dependency set avoids the dotnet/nuget version mismatches that make
  # VRCFT-style packages fragile.
  nixpkgs-vrft = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/567a49d1913ce81ac6e9582e3553dd90a955875f.tar.gz";
    sha256 = "1vq77hlx8mi3z03pw2nf6r5h7473r1p9yxyf58ym3fh01zppmfln";
  };

  # What the flake calls `pkgsCuda` (allowUnfree + cudaSupport). Baballonia's
  # onnxruntime is then built with CUDA, matching `nix run .#baballonia-cuda`.
  pkgsCuda = import nixpkgs-vrft {
    system = "x86_64-linux";
    config = {
      allowUnfree = true;
      cudaSupport = true;
    };
  };

  baballonia = pkgsCuda.callPackage "${nix-vrft}/pkgs/baballonia" {
    # nix-vrft's mkPkg wires babble-trainer in as an explicit override so the
    # calibration trainer ships alongside Baballonia itself.
    babble-trainer = pkgsCuda.callPackage "${nix-vrft}/pkgs/babble-trainer" { };
  };

  vrcft = pkgsCuda.callPackage "${nix-vrft}/pkgs/vrcft" { };
in
{
  # The desktop apps are launched from the systemd user session; expose both.
  environment.systemPackages = [ baballonia vrcft ];
}