{ config, pkgs, unstable, ... }:

{
  imports =
    [
      <nixos-hardware/lenovo/thinkpad/t480s>
      ../common-all/configuration.nix
      ../common-desktop/configuration.nix
      ../common-dev/programs/development.nix
      (import ./services { inherit config pkgs unstable; })
    ];

  system.stateVersion = "24.11";

  time.timeZone = "Europe/Stockholm";
  networking.hostName = "paprika";

  # Desktop services
  services.gvfs.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;  # Enable mDNS in NSS
  };
  services.udisks2.enable = true;

  # Niri compositor
  services.displayManager.sddm.theme = "sugar-dark";
  services.displayManager.sddm.wayland.enable = true;
  programs.niri = { enable = true; package = unstable.niri; };
  programs.xwayland.enable = true;

  # Enable 32-bit graphics support for Wine etc.
  hardware.graphics.enable32Bit = true;

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
    wl-clipboard
    unstable.art

    unstable.discord
    foliate

    # Wine (Full variant includes wine-mono)
    wineWowPackages.stableFull
    winetricks
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
}
