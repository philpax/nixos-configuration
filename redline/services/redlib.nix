{ config, lib, pkgs, ... }:

let
  src = pkgs.fetchFromGitHub {
    owner = "polak14";
    repo = "redlib";
    rev = "4055fda1a5355f1507b23108795d827a16794b58";
    hash = "sha256-7VRaXfYDPhwqgUCSCYCmO36XKdNQ5zEPrpP/E/BQh5g=";
  };
  # This fork handles blocked comments API requests and falls back to scraping.
  redlib-unstable = pkgs.redlib.overrideAttrs (oldAttrs: {
    version = "0.36.0-unstable-2026-10-20";
    inherit src;
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "redlib-0.36.0-unstable-2026-10-20-vendor";
      hash = "sha256-An6ai9CWrskjfPqmUN/z9rqZYsZp0Tjhp1ODvUnPAuw=";
    };
    # BoringSSL (via boring-sys2) needs cmake, go, git, perl, and libclang for bindgen
    nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ (with pkgs; [
      cmake
      go
      perl
      git
      rustPlatform.bindgenHook
    ]);
    checkFlags = (oldAttrs.checkFlags or []) ++ [
      "--skip=oauth::tests::test_generic_web_backend"
      "--skip=oauth::tests::test_mobile_spoof_backend"
    ];
  });
in
{
  services.redlib = {
    enable = true;
    openFirewall = true;
    package = redlib-unstable;
    port = 10000;
    settings = {
      REDLIB_SFW_ONLY = "off";
      REDLIB_BANNER = "philpax's personal redlib. you probably shouldn't have access to this, unless you're me.";
      REDLIB_ROBOTS_DISABLE_INDEXING = "on";
      REDLIB_DEFAULT_FRONT_PAGE = "default";
      REDLIB_DEFAULT_LAYOUT = "compact";
      REDLIB_DEFAULT_WIDE = "off";
      REDLIB_DEFAULT_BLUR_SPOILER = "on";
      REDLIB_DEFAULT_BLUR_NSFW = "on";
      REDLIB_DEFAULT_SUBSCRIPTIONS = builtins.concatStringsSep "+" [
        "datahoarder"
        "fujifilm"
        "LocalLLaMA"
        "hardware"
        "rust"
        "selfhosted"
        "StableDiffusion"
        "steinsgate"
      ];
      REDLIB_DEFAULT_REMOVE_DEFAULT_FEEDS = "on";
    };
  };
}