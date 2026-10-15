{ config, pkgs, ... }:

let
  # bump `rev` to pull in new commits (an unpinned URL is cached for an hour by tarball-ttl and won't refetch promptly).
  blackbird = (builtins.getFlake "git+https://github.com/philpax/blackbird?rev=e57182d2076a28468ae4a6b3883c4578316030b8").packages.${pkgs.stdenv.hostPlatform.system}.default;
  # Tracking the upstream flake directly rather than the nixpkgs channel build
  # (the flake's default package builds from git HEAD, so it carries newer fixes).
  xwayland-satellite = (builtins.getFlake "git+https://github.com/Supreeeme/xwayland-satellite?rev=ae88928f7334556d298b8d9552abdf395931931b").packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  imports = [ ./portable.nix ./quickshell.nix ./niri.nix ];

  nixpkgs.overlays = [ (import ./xdg-desktop-portal/overlay.nix) ];

  # Desktop services
  programs.dconf.enable = true;
  environment.pathsToLink = [ "/share/gsettings-schemas" ];
  services.gvfs.enable = true;
  services.udisks2.enable = true;
  services.upower.enable = true;
  hardware.bluetooth.enable = true;
  services.blueman.enable = true;
  services.udev.packages = [ pkgs.libgphoto2 ];

  # Niri compositor + fork/config selection: see ./niri.nix.

  # Enable 32-bit graphics support for Wine etc.
  hardware.graphics.enable32Bit = true;

  # Steam
  programs.steam.enable = true;

  # gpu-screen-recorder (sets cap_sys_admin on gsr-kms-server to avoid root prompts)
  programs.gpu-screen-recorder.enable = true;

  security.polkit.enable = true;

  environment.systemPackages = with pkgs; [
    blackbird

    # Desktop environment
    glib  # provides gsettings
    gsettings-desktop-schemas  # provides org.gnome.desktop.interface schema
    nwg-look  # GTK theme/icon/cursor/font configuration
    mako
    fuzzel  # dmenu backend for audio-action.sh / window-action.sh
    anyrun  # Mod+D launcher; rink plugin gives live arithmetic and unit conversion
    polkit_gnome
    swaylock
    swayidle
    pavucontrol
    brightnessctl
    playerctl
    nautilus
    ffmpegthumbnailer  # video thumbnails/previews in nautilus
    file-roller
    networkmanagerapplet
    xwayland-satellite
    volantes-cursors
    swaybg
    sunsetr
    gvfs
    samba
    wsdd
    wl-clipboard
    wf-recorder
    gpu-screen-recorder
    slurp
    libnotify
    art

    # Wine (Full variant includes wine-mono)
    wineWow64Packages.stableFull
    winetricks

    # VM stuff
    quickemu
    quickgui

    # AppImage support
    appimage-run
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
