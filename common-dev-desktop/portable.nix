# Applications shared by the niri desktop and Frame's Desktop Mode. The niri
# session itself (compositor, panels, portals, helpers) stays in configuration.nix.
{ lib, pkgs, ... }:
{
  # vesktop's nixpkgs recipe still pins pnpm 10.29.2 (build-time only).
  nixpkgs.config.permittedInsecurePackages = [ "pnpm-10.29.2" ];

  environment.systemPackages = builtins.filter (lib.meta.availableOn pkgs.stdenv.hostPlatform) (with pkgs; [
    # Trialling ghostty as the primary terminal (spawned by niri).
    # If it sticks, drop alacritty here and its dotfiles/blur rules.
    alacritty
    ghostty
    kdePackages.ocean-sound-theme  # Ghostty and GTK audible bell sound

    obsidian
    discord
    vesktop
    zed-editor
    foliate
    shotcut
    chromium

    # Keyboard configurator (Kaleidoscope)
    chrysalis

    # Games
    prismlauncher
  ]);
}
