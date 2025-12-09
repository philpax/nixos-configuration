{ config, pkgs, unstable, ... }:

{
  imports =
    [
      <nixos-hardware/lenovo/thinkpad/t480s>
      ../common/configuration.nix
      ../shared/programs/development.nix
      (import ./services { inherit config pkgs unstable; })
    ];

  system.stateVersion = "24.11";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "paprika";

  # Enable networking
  networking.networkmanager.enable = true;
  services.gvfs.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;  # Enable mDNS in NSS
  };
  services.udisks2.enable = true;

  # Enable Niri and such.
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.theme = "sugar-dark";
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
    sddm-sugar-dark
    obsidian

    # Desktop environment
    mako
    alacritty
    fuzzel
    waybar
    polkit_gnome
    swaylock
    swayidle
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
    unstable.sunsetr
    gvfs
    wl-clipboard

    unstable.discord
    foliate
  ];

  systemd.user.services.polkit-gnome-authentication-agent-1 = {
    description = "polkit-gnome-authentication-agent-1";
    wantedBy = [ "graphical-session.target" ];
    wants = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
        Restart = "on-failure";
        RestartSec = 1;
        TimeoutStopSec = 10;
      };
  };
  services.gnome.gcr-ssh-agent.enable = false;

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

  programs.firefox.enable = true;
}
