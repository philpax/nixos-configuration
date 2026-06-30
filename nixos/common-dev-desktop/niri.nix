# Centralised niri configuration. Defines the available forks (built by overriding nixpkgs' `niri`
# with a pinned source) and the config each one loads, and exposes a single per-machine switch —
# `philpax.niri.variant` — so a machine just opts into a branch instead of overriding the
# package/config itself.
{ config, lib, pkgs, ... }:

let
  cfg = config.philpax.niri;

  # Build a niri fork from a pinned source. The fork's binary still reports `niri 26.04`; our
  # annotated `version` differs, so the install check is skipped.
  mkFork = { owner, repo, rev, hash, version, vendorHash }:
    let
      src = pkgs.fetchFromGitHub { inherit owner repo rev hash; };
    in
    pkgs.niri.overrideAttrs (_: {
      inherit version src;
      cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
        inherit src;
        name = "niri-${version}-vendor";
        hash = vendorHash;
      };
      doInstallCheck = false;
    });

  # Each variant pairs a fork with the config niri loads (pointed there explicitly via NIRI_CONFIG).
  variants = {
    # 0WD0's niri fork (wd/vertical-layout branch) — two-dimensional layouting for vertical monitors.
    "0wd0" = {
      package = mkFork {
        owner = "0WD0";
        repo = "niri";
        rev = "49fe5ed546ae938829842d7e259b4bb5175d40c6";
        hash = "sha256-WYYnuQhxiqBGs3+Dgz05nHzAVAAFwy+0yaFYo06u7Og=";
        version = "26.04-fork-2026-04-28";
        vendorHash = "sha256-gfnalA3qI3a9h3PvsxgQLCrzapfjLLkxhTMJpwRh+ro=";
      };
      configFile = "${config.users.users.philpax.home}/.config/niri/config.kdl";
    };

    # philpax/niriad — sway-style recursive window tree on top of the 2D layouting.
    # Bump rev/hash/vendorHash to pull in newer niriad commits (e.g. the sway-model branch).
    niriad = {
      package = mkFork {
        owner = "philpax";
        repo = "niriad";
        rev = "2f1ae1fd32a56a988dda2dac168b248fb27c8d9b";
        hash = "sha256-Kj+ydDYHD1XXKtfGe6Dc/G9EdAH9e/dDkZ+Ljx2ObBc=";
        version = "26.04-niriad-2026-06-29";
        vendorHash = "sha256-jGORNwJ/F9UrajObXdGLbOTGEpCv919puUuWojbuVwo=";
      };
      configFile = "${config.users.users.philpax.home}/.config/niri/config-niriad.kdl";
    };
  };
  selected = variants.${cfg.variant};
in
{
  options.philpax.niri.variant = lib.mkOption {
    type = lib.types.enum (builtins.attrNames variants);
    default = "0wd0";
    description = "Which niri fork (and matching config) this machine runs; see the `variants` set in this file.";
  };

  config = {
    services.displayManager.sddm.wayland.enable = true;
    programs.niri = {
      enable = true;
      package = selected.package;
    };
    programs.xwayland.enable = true;

    # niri reads NIRI_CONFIG and strips it from the child environment afterwards, so launched apps
    # don't inherit it. Set explicitly for every variant so the loaded config is unambiguous.
    environment.sessionVariables.NIRI_CONFIG = selected.configFile;
  };
}
