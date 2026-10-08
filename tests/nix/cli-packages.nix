{ system ? "x86_64-linux", nixpkgs ? <nixpkgs>, baselineOnly ? false }:
let
  pkgs = import nixpkgs {
    inherit system;
    config.allowUnfree = true;
    overlays = [ (import ../../common-all/overlays/helix-steel.nix) ];
  };
  # Independent expectations captured from the original modules before extraction.
  expected = {
    system = with pkgs; [
      wget fastfetch screen jq parallel parted ntfs3g p7zip btrfs-progs lm_sensors
      lsof psmisc usbutils smartmontools ethtool bind.dnsutils libva-utils
      fd bat eza zoxide dust duf bottom procs delta tldr hyperfine tokei fzf zellij broot
      xdg-utils any-nix-shell
    ];
    development = with pkgs; [ git ripgrep direnv gdb ];
    network = with pkgs; [ tailscale croc ];
    media = with pkgs; [ ffmpeg-full yt-dlp imagemagick exiftool ];
    helix = [ pkgs.helix-steel ];
    dev = with pkgs; [
      rustup go gcc python3 python3Packages.pip poetry nodejs_22 pnpm rye uv stylua
      python3Packages.huggingface-hub python3Packages.hf-xet gnumake cmake gh
      openssl openssl.dev pkg-config clang lld libgcc
    ];
    fonts = with pkgs; [
      corefonts noto-fonts noto-fonts-cjk-sans noto-fonts-color-emoji liberation_ttf
      dejavu_fonts ubuntu-classic ipafont iosevka font-awesome nerd-fonts.meslo-lg cozette
    ];
  };
  callModule = path: import path { inherit pkgs; config = { }; };
  modules = {
    system = callModule ../../common-all/programs/system.nix;
    development = callModule ../../common-all/programs/development.nix;
    network = callModule ../../common-all/programs/network.nix;
    media = callModule ../../common-all/programs/media.nix;
    helix = callModule ../../common-all/programs/helix.nix;
    dev = callModule ../../common-dev/programs/development.nix;
    desktop = callModule ../../common-desktop/configuration.nix;
  };
  paths = builtins.map (p: p.outPath);
  metadata = builtins.map (p: {
    name = p.name;
    output = p.outputName or "out";
    path = p.outPath;
  });
  lists = builtins.mapAttrs (_: metadata) expected;
  options = {
    fish = modules.system.programs.fish.enable;
    nixLd = modules.system.programs.nix-ld.enable;
    tailscale = modules.network.services.tailscale;
    firewall = modules.dev.networking.firewall.allowedTCPPorts;
    defaultFontPackages = modules.desktop.fonts.enableDefaultPackages;
    fontFamilies = modules.desktop.fonts.fontconfig.defaultFonts;
  };
  expectedOptions = {
    fish = true;
    nixLd = true;
    tailscale = { enable = true; useRoutingFeatures = "both"; };
    firewall = [ 5173 ];
    defaultFontPackages = true;
    fontFamilies = {
      monospace = [ "Iosevka" "Noto Sans Mono CJK JP" ];
      sansSerif = [ "Noto Sans" "Noto Sans CJK JP" ];
      serif = [ "Noto Serif" "Noto Serif CJK JP" ];
    };
  };
  originalMatch = builtins.all (name:
    paths modules.${name}.environment.systemPackages == paths expected.${name}
  ) [ "system" "development" "network" "media" "helix" "dev" ];
  extracted = {
    system = import ../../common-all/packages/system.nix { inherit pkgs; };
    development = import ../../common-all/packages/development.nix { inherit pkgs; };
    network = import ../../common-all/packages/network.nix { inherit pkgs; };
    media = import ../../common-all/packages/media.nix { inherit pkgs; };
    helix = import ../../common-all/packages/helix.nix { inherit pkgs; };
    dev = import ../../common-dev/packages/development.nix { inherit pkgs; };
    fonts = import ../../common-desktop/packages/fonts.nix { inherit pkgs; };
  };
  extractedMatch = builtins.all (name:
    paths extracted.${name} == paths expected.${name}
  ) (builtins.attrNames expected);
in
assert originalMatch;
assert paths modules.desktop.fonts.packages == paths expected.fonts;
assert options == expectedOptions;
assert baselineOnly || extractedMatch;
{
  inherit system lists options;
  nixos_cli_lists_match_baseline = originalMatch && (baselineOnly || extractedMatch);
  nixos_cli_service_options_unchanged = options == expectedOptions;
  nixos_fonts_match_baseline = paths modules.desktop.fonts.packages == paths expected.fonts;
}
