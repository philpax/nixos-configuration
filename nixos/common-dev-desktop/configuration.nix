{ config, pkgs, unstable, ... }:

{
  # Desktop services
  services.gvfs.enable = true;
  services.udisks2.enable = true;
  services.udev.packages = [ pkgs.libgphoto2 ];

  # Niri compositor
  services.displayManager.sddm.theme = "sugar-dark";
  services.displayManager.sddm.wayland.enable = true;
  programs.niri = { enable = true; package = unstable.niri; };
  programs.xwayland.enable = true;

  # Enable 32-bit graphics support for Wine etc.
  hardware.graphics.enable32Bit = true;

  # Steam
  programs.steam.enable = true;

  security.polkit.enable = true;

  environment.systemPackages = with pkgs; [
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
    samba
    wsdd
    wl-clipboard
    wf-recorder
    gpu-screen-recorder
    slurp
    unstable.art

    unstable.discord
    unstable.zed-editor
    foliate

    # Wine (Full variant includes wine-mono)
    wineWowPackages.stableFull
    winetricks

    # VM stuff
    quickemu
    quickgui
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

  # Work around xdg-desktop-portal locking up after a few hours of use,
  # blocking any applications that depend on it (flatpak/xdg-desktop-portal#1416).
  # Cap its memory and force a restart every hour as a preventive measure.
  systemd.user.services.xdg-desktop-portal.serviceConfig = {
    MemoryMax = "1G";
    RuntimeMaxSec = "1h";
    Restart = "always";
  };

  services.gnome.gcr-ssh-agent.enable = false;
}
