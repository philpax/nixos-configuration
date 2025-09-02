{ config, pkgs, ... }:

{
  imports =
    [
      ../common/configuration.nix
    ];

  system.stateVersion = "24.11";

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";
  boot.loader.grub.useOSProber = true;

  networking.hostName = "jinroh";

  # Enable networking
  networking.networkmanager.enable = true;

  # Enable the KDE Plasma Desktop Environment.
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;
  };

  users.users.philpax.packages = with pkgs; [
    kdePackages.kate
  ];

  # Install fonts
  fonts.packages = with pkgs; [
    corefonts
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-emoji
    noto-fonts-extra
    ipafont
    iosevka
  ];

  # Set default fonts
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

  # Enable automatic login for the user.
  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = "philpax";

  programs.firefox.enable = true;
}
