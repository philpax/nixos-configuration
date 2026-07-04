{ config, pkgs, ... }:

let
  # bump `rev` to pull in new commits (an unpinned URL is cached for an hour by tarball-ttl and won't refetch promptly).
  blackbird = (builtins.getFlake "git+https://github.com/philpax/blackbird?rev=e57182d2076a28468ae4a6b3883c4578316030b8").packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  imports = [ ./quickshell.nix ./niri.nix ];

  nixpkgs.overlays = [ (import ./xdg-desktop-portal/overlay.nix) ];

  # vesktop's nixpkgs recipe still pins pnpm 10.29.2 (build-time only).
  nixpkgs.config.permittedInsecurePackages = [ "pnpm-10.29.2" ];

  # Desktop services
  programs.dconf.enable = true;
  environment.pathsToLink = [ "/share/gsettings-schemas" ];
  services.gvfs.enable = true;
  services.udisks2.enable = true;
  services.upower.enable = true;
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

    obsidian

    # Desktop environment
    glib  # provides gsettings
    gsettings-desktop-schemas  # provides org.gnome.desktop.interface schema
    nwg-look  # GTK theme/icon/cursor/font configuration
    mako
    # Trialling ghostty as the primary terminal (spawned by niri/driftwm).
    # If it sticks, drop alacritty here and its dotfiles/blur rules.
    alacritty
    ghostty
    fuzzel
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

    discord
    vesktop
    zed-editor
    foliate

    # Wine (Full variant includes wine-mono)
    wineWow64Packages.stableFull
    winetricks

    # VM stuff
    quickemu
    quickgui

    # AppImage support
    appimage-run

    # Keyboard configurator (Kaleidoscope)
    chrysalis

    # Games
    prismlauncher
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
