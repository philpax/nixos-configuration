{ config, pkgs, ... }:
let
  unstable = import
    (builtins.fetchTarball https://github.com/nixos/nixpkgs/tarball/eac44c5d88dc6c850e11f522a58818c4ba75ff83)
    # reuse the current configuration
    { config = config.nixpkgs.config; };
in
{
  imports =
    [
      /etc/nixos/hardware-configuration.nix
      ./no-rgb-service.nix
      (import ./ai { inherit config pkgs unstable; })
      (import ./services { inherit config pkgs unstable; })
      (import ./programs { inherit config pkgs unstable; })
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
  services.xserver.videoDrivers = [ "nvidia" ];

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
      8000 # python -m http.server
    ];
    firewall.allowedUDPPorts = [];
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
    extraGroups = [ "networkmanager" "wheel" "docker" "libvirtd" "kvm" "dialout" "plugdev" "uucp" "ai" ];
    packages = with pkgs; [];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDwvEVMGi643L4ufnpEPLHgSIBs2pN1BMG7Z2SGlKPf8N/SjpjKmyUE9NJw1ACb/wQ7D83c+r1QSbW4PUgq1uIuLdOteNj6+QeTiXKW3rmDIQQy0TzV0v/KP5YxK2EXCtr1Bv7Ca/WVLcUzIkvp8xzvXXgB58FbrveRzBYMIiieQYXMvd70HkliccrczyIc0x2mE8KqXy3/TFnZHAw96AenIPcifLenQgSIDsds1JTJoyNWHNa1ac/UKrlzKqNzX2apdL8vX2W+FeR/IZ+Mi86coGR42LJvktYWexqs+876UhMvha4L5toKkqVMf/JH7E3YUt/TbXBykR2rRyxrzYpFUWrk/wL+si30YWK+6a4jD8RDtGzKy+sWM7xitJPaamE9k3bSmexBu3wSc8UCvWyOmHs/YAoFeJIKUET7b3sRKMZbt2tmR//JJdL+PdUsxX7T1JJt/z0wbFK+ENYJVPYUE/B/o8isBkpBdy0pJs7SVjT52wM0JrMqaqAN8HrfUzKt9N8HTaztCGjv86y/avH9it1gERDMTef6HaXROiQngdrChOjQ0nysfIxnsh48usD+p8VbXb54VZM0wRmPUgoUKZbro7AsHvtCNfNI1oBHYFTTIZsGHML5Ho8OlZ8XVTgaIufZc+ZkYN2lRXZPwhQwiIg3Kz0kMP5Uo4onMJOIJw== me@philpax.me"
    ];
  };

  security.rtkit.enable = true;
  security.sudo.extraConfig = ''
    Defaults timestamp_timeout=60
  '';
}
