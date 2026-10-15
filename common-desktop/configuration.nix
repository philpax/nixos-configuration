{ config, pkgs, ... }:
{
  imports = [ ./portable.nix ];

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
  services.printing.package = pkgs.cups;
  services.avahi = {
    enable = true;
    nssmdns4 = true;  # for .local hostname resolution
  };

  # Headers for building against CUPS.
  environment.systemPackages = [ pkgs.cups.dev ];

  fonts.enableDefaultPackages = true;

  # Firefox
  programs.firefox.enable = true;
}
