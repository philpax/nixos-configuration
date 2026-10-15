# Desktop applications and fonts shared by NixOS and Frame's Desktop Mode.
{ lib, pkgs, ... }:
{
  environment.systemPackages = builtins.filter (lib.meta.availableOn pkgs.stdenv.hostPlatform) (with pkgs; [
    goldendict-ng
    anki-bin
    gthumb
    inlyne
    mpv
    vlc
  ]);

  fonts.packages = import ./packages/fonts.nix { inherit pkgs; };
  fonts.fontconfig.defaultFonts = {
    monospace = [
      "Iosevka"
      "Noto Sans Mono CJK JP"
    ];

    sansSerif = [
      "Noto Sans"
      "Noto Sans CJK JP"
    ];

    serif = [
      "Noto Serif"
      "Noto Serif CJK JP"
    ];
  };
}
