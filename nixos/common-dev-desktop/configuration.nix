{ config, pkgs, unstable, ... }:

{
  nixpkgs.overlays = [ (import ./xdg-desktop-portal/overlay.nix) ];

  # Desktop services
  programs.dconf.enable = true;
  environment.pathsToLink = [ "/share/gsettings-schemas" ];
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
    glib  # provides gsettings
    gsettings-desktop-schemas  # provides org.gnome.desktop.interface schema
    nwg-look  # GTK theme/icon/cursor/font configuration
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
    unstable.vesktop
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

  # Route portal requests away from xdg-desktop-portal-gnome, which leaks
  # memory unboundedly waiting for gnome-shell on non-GNOME sessions
  # (was peaking at >100G swap before the OOM killer caught it).
  # niri's nixpkgs module forces the gnome backend into extraPortals; this
  # config keeps it installed but idle by sending real traffic to gtk/wlr.
  xdg.portal = {
    config.common = {
      default = [ "gtk" ];
      "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
      "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
    };
    extraPortals = [ pkgs.xdg-desktop-portal-wlr ];
  };

  # Belt-and-braces against the Realtime-portal leak (flatpak/xdg-desktop-portal#1416).
  # The 1.21.1 override above should fix the leak itself; these caps just ensure
  # that if it ever recurs, the portal gets killed quickly instead of burning
  # tens of GB of swap.
  systemd.user.services.xdg-desktop-portal.serviceConfig = {
    MemoryMax = "512M";
    MemorySwapMax = "0";
    RuntimeMaxSec = "1h";
    Restart = "always";
  };

  # React dev server (Vite)
  networking.firewall.allowedTCPPorts = [ 5173 ];

  services.gnome.gcr-ssh-agent.enable = false;
}
