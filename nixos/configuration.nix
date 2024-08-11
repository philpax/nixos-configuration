{ config, pkgs, ... }:
let
  ddclientSecrets = import /etc/nixos/ddclient-secrets.nix;
in
{
  imports =
    [
      /etc/nixos/hardware-configuration.nix
      ./no-rgb-service.nix
    ];

  system.stateVersion = "23.11";
  system.autoUpgrade.enable = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.supportedFilesystems = [ "ntfs" ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  fileSystems = {
    "/mnt/ssd2" = {
      device = "/dev/disk/by-uuid/83a6c26f-d241-4f80-8c47-c1801d211835";
      fsType = "ext4";
      options = [ "defaults" "nofail" ];
    };

    "/mnt/hdd1" = {
      device = "/dev/disk/by-uuid/f6a10ed9-5d48-4289-ab7a-d3a5a171a378";
      fsType = "ext4";
      options = [ "defaults" "nofail" ];
    };

    "/mnt/hdd2" = {
      device = "/dev/disk/by-uuid/0d71effe-7cd4-469f-b320-44155526c44a";
      fsType = "ext4";
      options = [ "defaults" "nofail" ];
    };

    "/mnt/external" = {
      device = "/dev/disk/by-uuid/9EB67FDDB67FB47D";
      fsType = "ntfs";
      options = [ "defaults" "nofail" "x-systemd.automount" "noauto" ];
    };

    "/mnt/programs" = {
      device = "/dev/disk/by-uuid/30D0BD2BD0BCF7E4";
      fsType = "ntfs";
      options = [ "defaults" "nofail" ];
    };
  };

  powerManagement.cpuFreqGovernor = "ondemand";

  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;
  hardware.graphics.extraPackages = with pkgs; [
    vulkan-validation-layers
  ];
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.stable;
  hardware.nvidia.modesetting.enable = true;

  nixpkgs.config.pulseaudio = true;
  hardware.pulseaudio.enable = true;

  virtualisation.docker.enable = true;
  hardware.nvidia-container-toolkit.enable = true;
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;
      ovmf = {
        enable = true;
        packages = [(pkgs.OVMF.override {
          secureBoot = true;
          tpmSupport = true;
        }).fd];
      };
    };
  };

  networking = {
    hostName = "redline";
    networkmanager.enable = true;
    firewall.allowedTCPPorts = [
      22 # ssh
      7860 # automatic1111
      8000 # python -m http.server
      8384 # syncthing GUI
      22000 # syncthing traffic
      5900 5901 5902 # spice/vnc
    ];
    firewall.allowedUDPPorts =  [
      22000 # syncthing traffic
    ];
    interfaces.enp68s0f1 = {
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
    extraGroups = [ "networkmanager" "wheel" "docker" "libvirtd" "kvm" ];
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
    ffmpeg
    python3
    awscli2
    jq
    rye
    ntfs3g
    virt-manager
    qemu
    OVMF
    virt-viewer
    grim
    slurp
    wl-clipboard
    mako
    discord
    swayfx
    swaylock
    swayidle
    wmenu
    foot
    foot.themes
    xdg-utils
    nodejs_22
    wineWowPackages.stable
    winetricks
    llvmPackages_17.bintools
    vscode.fhs
    ripgrep
    p7zip
    clang
    pavucontrol
    neovide
    spotify
    obsidian
  ];
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
    cozette
    iosevka
  ];
  fonts.enableDefaultPackages = true;
  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };
  programs.firefox.enable = true;
  programs.envision.enable = true;
  programs.adb.enable = true;
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
    localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
  };
  environment.pathsToLink = [ "/share/foot" ];
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = "*";
    wlr.enable = true;
  };
  # https://github.com/NixOS/nixpkgs/issues/262286
  nixpkgs.overlays = [ (self: super: {
    xdg-desktop-portal-gtk = super.xdg-desktop-portal-gtk.overrideAttrs {
      postInstall = ''
        sed -i 's/UseIn=gnome/UseIn=gnome;sway/' $out/share/xdg-desktop-portal/portals/gtk.portal
      '';
    };
  } ) ];

  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;
  services.hardware.openrgb.enable = true;
  services.xserver = {
    xkb = {
      layout = "au";
      variant = "";
    };
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
  services.ddclient = {
    enable = true;
    configFile = pkgs.writeText "ddclient-config" ''
      protocol=namecheap
      use=web, web=dynamicdns.park-your-domain.com/getip
      server=dynamicdns.park-your-domain.com
      login=philpax.me
      password=${ddclientSecrets.password}
      promare.philpax.me
    '';
  };
  services.gnome.gnome-keyring.enable = true;
  services.plex = {
    enable = true;
    openFirewall = true;
  };
  services.navidrome = {
    enable = true;
    settings = {
      MusicFolder = "/mnt/external/Music";
    };
  };

  security.polkit.enable = true;
  security.pam.services.swaylock = {};
}
