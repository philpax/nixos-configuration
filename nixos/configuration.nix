{ config, pkgs, ... }:
let
  ddclientSecrets = import ./ddclient-secrets.nix;
  unstable = import
    (builtins.fetchTarball https://github.com/nixos/nixpkgs/tarball/85c3ab0195ffe0d797704c9707e4da3d925be9b9)
    # reuse the current configuration
    { config = config.nixpkgs.config; };
in
{
  imports =
    [
      /etc/nixos/hardware-configuration.nix
      ./no-rgb-service.nix
    ];

  system.stateVersion = "24.11";
  system.autoUpgrade.enable = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.supportedFilesystems = [ "ntfs" ];
  boot.initrd.kernelModules = [
    "nvidia"
  ];
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  boot.kernelParams = [ "nomodeset" ];

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
  };

  powerManagement.cpuFreqGovernor = "performance";

  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.latest;
  hardware.nvidia.open = true;
  hardware.nvidia.modesetting.enable = false;
  hardware.nvidia-container-toolkit.enable = true;

  virtualisation.docker.enable = true;
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      swtpm.enable = true;
      ovmf.enable = true;
      ovmf.packages = [ pkgs.OVMFFull.fd ];
    };
  };
  virtualisation.spiceUSBRedirection.enable = true;

  networking = {
    hostName = "redline";
    firewall.allowedTCPPorts = [
      22 # ssh
      139 445 # smb
      4533 # navidrome
      7070 # openai-compatible large-model-proxy server
      7860 # automatic1111
      8000 # python -m http.server
      8188 # comfyui
      8192 # http server testing
      8384 # syncthing GUI
      22000 # syncthing traffic
      5900 5901 5902 # spice/vnc
      25565 25566 # minecraft server
      31338 # game server
    ]
    # llama.cpp instances
    ++ (builtins.genList (x: 8200 + x) 10);
    firewall.allowedUDPPorts =  [
      137 138 # smb
      22000 # syncthing traffic
      31337 # game server
    ];
    defaultGateway = "192.168.50.1";
    nameservers = ["1.1.1.1" "1.0.0.1"];
  };
  # wait-online breaks rebuilds: https://github.com/NixOS/nixpkgs/issues/180175
  systemd.services.NetworkManager-wait-online.enable = false;

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
    extraGroups = [ "networkmanager" "wheel" "docker" "libvirtd" "kvm" "dialout" "plugdev" "uucp" ];
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
    go
    gcc
    openssl
    openssl.dev
    pkg-config
    screen
    ffmpeg-full
    python3
    poetry
    awscli2
    jq
    rye
    ntfs3g
    qemu
    OVMF
    xdg-utils
    nodejs_22
    wineWowPackages.stable
    winetricks
    llvmPackages_17.bintools
    ripgrep
    p7zip
    clang
    jellyfin
    jellyfin-web
    jellyfin-ffmpeg
    yt-dlp
    (openai-whisper-cpp.override { cudaSupport = true; })
    (unstable.llama-cpp.override { cudaSupport = true; })
    imagemagick
    tailscale
    direnv
    rtorrent
    croc
    lm_sensors
  ];
  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };

  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;
  services.hardware.openrgb.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  services.syncthing = {
    enable = true;
    user = "philpax";
    dataDir = "/home/philpax";
    configDir = "/home/philpax/.config/syncthing";
    overrideDevices = true;
    overrideFolders = true;
    guiAddress = "127.0.0.1:8384";
    settings = {
      devices = {
        "work-mbp" = { id = "755IIFA-4U6ZX4Z-MYVIMZT-6BR5MDT-UDGV42J-CDXBRC7-RVC26M2-XAEO3AB"; };
        "the-wind-rises" = { id = "NLD2NYH-SAYR2TR-GSRXTMD-EWIQCYN-RNI2UDA-52QQEZX-FVVC3NC-YSPWYAY"; };
      };
      folders = {
        "Notes" = {
          path = "/mnt/ssd2/notes";
          devices = [ "work-mbp" "the-wind-rises" ];
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
  services.resolved.enable = true;
  services.plex = {
    enable = true;
    openFirewall = true;
  };
  services.navidrome = {
    enable = true;
    settings = {
      Address = "0.0.0.0";
      MusicFolder = "/mnt/external/Music";
    };
  };
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };
  services.minecraft-server = {
    enable = true;
    eula = true;
    openFirewall = true;

    package = unstable.papermc;

    jvmOpts = "-Xms4092M -Xmx4092M -XX:+UseG1GC";
  };
  services.samba = {
    enable = true;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = "NixOS SMB Server";
        "server role" = "standalone server";
        "map to guest" = "Bad User";
        "guest account" = "nobody";
        "security" = "user";
        # Disable printing services
        "load printers" = "no";
        "printing" = "bsd";
        "printcap name" = "/dev/null";
      };
      photos = {
        path = "/mnt/external/Photos";
        comment = "Read-only Photos Share";
        browsable = true;
        "read only" = true;
        "guest ok" = true;
        "create mask" = "0444";
        "directory mask" = "0555";
      };
      videos = {
        path = "/mnt/external/Videos";
        comment = "Read-only Videos Share";
        browsable = true;
        "read only" = true;
        "guest ok" = true;
        "create mask" = "0444";
        "directory mask" = "0555";
      };
    };
  };
  services.tailscale.enable = true;
  systemd.services.largemodelproxy = {
    description = "Large Model Proxy";
    after = [ "docker.service" "network.target" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      WorkingDirectory = "/mnt/ssd2/ai/large-model-proxy";
      ExecStart = "/mnt/ssd2/ai/large-model-proxy/large-model-proxy -c /home/philpax/nixos-configuration/large-model-proxy-config.json";
      Restart = "always";
      RestartSec = "10s";
    };
  };
  security.rtkit.enable = true;
  services.udisks2.enable = true;
  services.devmon.enable = true;
}
