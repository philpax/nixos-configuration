{ config, lib, pkgs, ... }:

let
  src = pkgs.fetchFromGitHub {
    owner = "redlib-org";
    repo = "redlib";
    rev = "a4d36e954cf1bd64f209cd8868c5a29edc81b374";
    hash = "sha256-siyD6A12UALQIV7BMd7zu1TaojleTEYtpxPszuhx1/Y=";
  };
  # Upstream main, which includes the wreq switch (redlib-org/redlib#544) that
  # uses BoringSSL to emulate browser TLS fingerprints and evade bot detection
  redlib-unstable = pkgs.redlib.overrideAttrs (oldAttrs: {
    version = "0.36.0-unstable-2026-04-24";
    inherit src;
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "redlib-0.36.0-unstable-2026-04-24-vendor";
      hash = "sha256-eO3c7rlFna3DuO31etJ6S4c7NmcvgvIWZ1KVkNIuUqQ=";
    };
    # Work around thread pages 403ing (redlib-org/redlib#591)
    patches = (oldAttrs.patches or []) ++ [ ./redlib-591-thread-403.patch ];
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