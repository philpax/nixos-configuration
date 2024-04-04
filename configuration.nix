# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./no-rgb-service.nix
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "redline"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 7860 8000 ];
  };

  # Set your time zone.
  time.timeZone = "Europe/Stockholm";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_GB.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_GB.UTF-8";
    LC_IDENTIFICATION = "en_GB.UTF-8";
    LC_MEASUREMENT = "en_GB.UTF-8";
    LC_MONETARY = "en_GB.UTF-8";
    LC_NAME = "en_GB.UTF-8";
    LC_NUMERIC = "en_GB.UTF-8";
    LC_PAPER = "en_GB.UTF-8";
    LC_TELEPHONE = "en_GB.UTF-8";
    LC_TIME = "en_GB.UTF-8";
  };

  # Configure keymap in X11
  services.xserver = {
    layout = "au";
    xkbVariant = "";
    videoDrivers = ["nvidia"];
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.philpax = {
    isNormalUser = true;
    description = "philpax";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDwvEVMGi643L4ufnpEPLHgSIBs2pN1BMG7Z2SGlKPf8N/SjpjKmyUE9NJw1ACb/wQ7D83c+r1QSbW4PUgq1uIuLdOteNj6+QeTiXKW3rmDIQQy0TzV0v/KP5YxK2EXCtr1Bv7Ca/WVLcUzIkvp8xzvXXgB58FbrveRzBYMIiieQYXMvd70HkliccrczyIc0x2mE8KqXy3/TFnZHAw96AenIPcifLenQgSIDsds1JTJoyNWHNa1ac/UKrlzKqNzX2apdL8vX2W+FeR/IZ+Mi86coGR42LJvktYWexqs+876UhMvha4L5toKkqVMf/JH7E3YUt/TbXBykR2rRyxrzYpFUWrk/wL+si30YWK+6a4jD8RDtGzKy+sWM7xitJPaamE9k3bSmexBu3wSc8UCvWyOmHs/YAoFeJIKUET7b3sRKMZbt2tmR//JJdL+PdUsxX7T1JJt/z0wbFK+ENYJVPYUE/B/o8isBkpBdy0pJs7SVjT52wM0JrMqaqAN8HrfUzKt9N8HTaztCGjv86y/avH9it1gERDMTef6HaXROiQngdrChOjQ0nysfIxnsh48usD+p8VbXb54VZM0wRmPUgoUKZbro7AsHvtCNfNI1oBHYFTTIZsGHML5Ho8OlZ8XVTgaIufZc+ZkYN2lRXZPwhQwiIg3Kz0kMP5Uo4onMJOIJw== me@philpax.me"
    ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    wget
    linuxPackages.nvidia_x11
    cudatoolkit
    neofetch
    git
    rustup
    gcc
    openssl
    openssl.dev
    pkg-config
    screen
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;
  services.hardware.openrgb.enable = true; 

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "23.11"; # Did you read the comment?

  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
