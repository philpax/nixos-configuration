{ config, pkgs, ... }:

{
  # Boot loader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Networking
  networking.networkmanager.enable = true;

  # Display manager
  services.displayManager.sddm.enable = true;

  # Audio with pipewire
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Printing
  services.printing.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;  # for .local hostname resolution
  };

  # Common desktop packages
  environment.systemPackages = with pkgs; [
    goldendict-ng
    anki-bin
    gthumb
  ];

  # Fonts
  fonts.enableDefaultPackages = true;
  fonts.packages = with pkgs; [
    corefonts
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    liberation_ttf
    dejavu_fonts
    ubuntu-classic
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

  # Firefox
  programs.firefox.enable = true;
}
