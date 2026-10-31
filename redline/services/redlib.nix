{ config, lib, pkgs, ... }:

let
  # The fork requires Rust 1.98; keep its toolchain local to this package.
  rustOverlaySrc = pkgs.fetchFromGitHub {
    owner = "oxalica";
    repo = "rust-overlay";
    rev = "6ecf534a7c16e7c969f26838fdd8c93597ae93f3";
    hash = "sha256-+sgVNI2c67di+XIeMaz5KSei4T65kX68s5Nl0E5Gzbc=";
  };
  rustPkgs = pkgs.extend (import rustOverlaySrc);
  rustToolchain = rustPkgs.rust-bin.stable."1.98.0".minimal;
  redlibRustPlatform = pkgs.makeRustPlatform {
    rustc = rustToolchain;
    cargo = rustToolchain;
  };
  src = pkgs.fetchFromGitHub {
    owner = "Nachtalb";
    repo = "redlib";
    rev = "f3120f910d0fea3cb578d2b8cb5a7434becf16aa";
    hash = "sha256-46MDqphWkRtM2i77dn5wF906aRuVV1hmzoMBjzu1Nko=";
  };
  redlib-unstable = (pkgs.redlib.override {
    rustPlatform = redlibRustPlatform;
  }).overrideAttrs (oldAttrs: {
    version = "0.36.0-unstable-2026-10-31";
    inherit src;
    env = (oldAttrs.env or {}) // { GIT_HASH = src.rev; };
    cargoDeps = redlibRustPlatform.fetchCargoVendor {
      inherit src;
      name = "redlib-0.36.0-unstable-2026-10-31-vendor";
      hash = "sha256-aCIooy54Z8Hi6+lG8wiWWI4kikXmqxeoV4LWumaAoZc=";
    };
    # BoringSSL (via btls-sys) needs cmake, go, git, perl, and libclang for bindgen.
    nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ (with pkgs; [
      cmake
      go
      perl
      git
    ]) ++ [ redlibRustPlatform.bindgenHook ];
    checkFlags = (oldAttrs.checkFlags or []) ++ [
      "--skip=oauth::tests::test_generic_web_backend"
      "--skip=oauth::tests::test_mobile_spoof_backend"
      "--skip=backends::live_tests::"
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