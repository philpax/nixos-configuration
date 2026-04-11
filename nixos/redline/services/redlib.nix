{ config, lib, pkgs, unstable, ... }:

let
  src = pkgs.fetchFromGitHub {
    owner = "Silvenga";
    repo = "redlib";
    rev = "af002ab216d271890e715c2d3413f7193c07c640";
    hash = "sha256-Ny/pdBZFgUAV27e3wREPV8DUtP3XfMdlw0T01q4b70U=";
  };
  # Use Silvenga's wreq fork (redlib-org/redlib#544) which uses BoringSSL
  # to emulate browser TLS fingerprints and evade bot detection
  redlib-fork = unstable.redlib.overrideAttrs (oldAttrs: {
    version = "0.36.0-unstable-2026-04-04";
    inherit src;
    cargoDeps = unstable.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "redlib-0.36.0-unstable-2026-04-04-vendor";
      hash = "sha256-eO3c7rlFna3DuO31etJ6S4c7NmcvgvIWZ1KVkNIuUqQ=";
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
    package = redlib-fork;
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