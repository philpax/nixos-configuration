{ config, pkgs, unstable, ... }:

{
  imports =
    [
      ../common/configuration.nix
      (import ./services { inherit config pkgs unstable; })
    ];

  system.stateVersion = "24.11";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "paprika";

  # Enable networking
  networking.networkmanager.enable = true;

  # Enable Niri and such.
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.theme = "where-is-my-sddm-theme";
  services.displayManager.sddm.wayland.enable = true;
  programs.niri = { enable = true; package = unstable.niri; };
  programs.xwayland.enable = true;

  # Enable sound with pipewire.
  # services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  security.polkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;
  };

  environment.systemPackages = with pkgs; [
    goldendict-ng
    anki-bin
    where-is-my-sddm-theme
    obsidian

    # Blackbird compilation
    rustup
    clang
    lld
    pkg-config

    # Desktop environment
    mako
    alacritty
    fuzzel
    waybar
    polkit_gnome
    swaylock
    pavucontrol
    brightnessctl
    playerctl
    nautilus
    file-roller
    networkmanagerapplet
    blueman
    xwayland-satellite
    volantes-cursors
    swaybg

    unstable.claude-code
  ];

  fonts.enableDefaultPackages = true;
  fonts.packages = with pkgs; [
    corefonts
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-emoji
    noto-fonts-extra
    liberation_ttf
    dejavu_fonts
    ubuntu_font_family
    ipafont
    iosevka
    font-awesome
    nerd-fonts.meslo-lg
    cozette
  ];
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

  programs.firefox.enable = true;
}
