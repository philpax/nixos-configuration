{ config, pkgs, ... }:
{
  imports =
    [
      ./hardware-configuration.nix
      ./no-rgb-service.nix
    ];

  system.stateVersion = "23.11";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  powerManagement.cpuFreqGovernor = "ondemand";

  hardware.opengl.enable = true;
  hardware.opengl.driSupport32Bit = true;

  virtualisation.docker.enable = true;
  virtualisation.docker.enableNvidia = true;

  networking = {
    hostName = "redline";
    networkmanager.enable = true;
    firewall.allowedTCPPorts = [
      22 # ssh
      7860 # automatic1111
      8000 # python -m http.server
      8384 # syncthing GUI
      22000 # syncthing traffic
    ];
    firewall.allowedUDPPorts =  [
      22000 # syncthing traffic
    ];
    interfaces.enp67s0f1 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = "192.168.50.201";
          prefixLength = 24;
        }
      ];
    };
    defaultGateway = "192.168.50.1";
    nameservers = ["1.1.1.1" "1.0.0.1"];
  };

  time.timeZone = "Europe/Stockholm";
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

  users.users.philpax = {
    isNormalUser = true;
    description = "philpax";
    extraGroups = [ "networkmanager" "wheel" "docker" ];
    packages = with pkgs; [];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDwvEVMGi643L4ufnpEPLHgSIBs2pN1BMG7Z2SGlKPf8N/SjpjKmyUE9NJw1ACb/wQ7D83c+r1QSbW4PUgq1uIuLdOteNj6+QeTiXKW3rmDIQQy0TzV0v/KP5YxK2EXCtr1Bv7Ca/WVLcUzIkvp8xzvXXgB58FbrveRzBYMIiieQYXMvd70HkliccrczyIc0x2mE8KqXy3/TFnZHAw96AenIPcifLenQgSIDsds1JTJoyNWHNa1ac/UKrlzKqNzX2apdL8vX2W+FeR/IZ+Mi86coGR42LJvktYWexqs+876UhMvha4L5toKkqVMf/JH7E3YUt/TbXBykR2rRyxrzYpFUWrk/wL+si30YWK+6a4jD8RDtGzKy+sWM7xitJPaamE9k3bSmexBu3wSc8UCvWyOmHs/YAoFeJIKUET7b3sRKMZbt2tmR//JJdL+PdUsxX7T1JJt/z0wbFK+ENYJVPYUE/B/o8isBkpBdy0pJs7SVjT52wM0JrMqaqAN8HrfUzKt9N8HTaztCGjv86y/avH9it1gERDMTef6HaXROiQngdrChOjQ0nysfIxnsh48usD+p8VbXb54VZM0wRmPUgoUKZbro7AsHvtCNfNI1oBHYFTTIZsGHML5Ho8OlZ8XVTgaIufZc+ZkYN2lRXZPwhQwiIg3Kz0kMP5Uo4onMJOIJw== me@philpax.me"
    ];
  };

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
    lunarvim
    ffmpeg
    python3
    awscli2
    jq
  ];
  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };

  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;
  services.hardware.openrgb.enable = true;
  services.xserver = {
    layout = "au";
    xkbVariant = "";
    videoDrivers = ["nvidia"];
  };
  services.syncthing = {
    enable = true;
    user = "philpax";
    dataDir = "/home/philpax";
    configDir = "/home/philpax/.config/syncthing";
    overrideDevices = true;
    overrideFolders = true;
    guiAddress = "0.0.0.0:8384";
    settings = {
      devices = {
        "valkyrie" = { id = "YLT7IT5-EPPNEXT-XEAFQ45-JZULUBI-JER6IEI-GDSVXRA-MVCCPLD-IOHN5AH"; };
      };
      folders = {
        "Documents" = {
          path = "/home/philpax/Documents";
          devices = [ "valkyrie" ];
        };
      };
    };
  };
}
