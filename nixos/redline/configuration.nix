{ config, pkgs, ... }:
let
  unstable = import
    (builtins.fetchTarball https://github.com/nixos/nixpkgs/tarball/11acca3a7bb28bf404838452cc0bc22d1fd2967e)
    # reuse the current configuration
    { config = config.nixpkgs.config; };
in
{
  imports =
    [
      ../common/configuration.nix
      (import ./ai { inherit config pkgs unstable; })
      (import ./services { inherit config pkgs unstable; })
      (import ./programs { inherit config pkgs unstable; })
    ];

  system.stateVersion = "24.11";

  boot.initrd.kernelModules = [
    "nvidia"
  ];
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  boot.kernelParams = [ "nomodeset" ];
  
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.supportedFilesystems = [ "ntfs" ];

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

  security.rtkit.enable = true;
  security.sudo.extraConfig = ''
    Defaults timestamp_timeout=60
  '';
}
