{ config, pkgs, unstable, ... }:

let
  folders = import ./folders.nix;
in {
  imports =
    [
      ../common-all/configuration.nix
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
  boot.supportedFilesystems = [ "ntfs" "zfs" ];
  boot.zfs.forceImportRoot = true;
  boot.zfs.extraPools = [ "storage" ];

  fileSystems = {
    ${folders.mounts.ssd0} = {
      device = "/dev/disk/by-uuid/68847514-728b-451c-8145-b2eaa1871e8d";
      fsType = "btrfs";
      options = [ "compress=zstd" "noatime" ];
    };

    ${folders.backups.external} = {
      device = "/dev/disk/by-uuid/9EB67FDDB67FB47D";
      fsType = "ntfs";
      options = [ "defaults" "nofail" "x-systemd.automount" "noauto" ];
    };

    "/var/lib/immich" = {
      device = folders.immich;
      options = [ "bind" ];
    };
  };

  # Auto-scrub monthly
  services.zfs.autoScrub.enable = true;

  # Auto-snapshots (optional but recommended)
  services.zfs.autoSnapshot = {
    enable = true;
    frequent = 4;
    hourly = 24;
    daily = 7;
    weekly = 4;
    monthly = 12;
  };

  # Auto-scrub btrfs weekly
  services.btrfs.autoScrub = {
    enable = true;
    interval = "weekly";
    fileSystems = [ "/mnt/ssd0" ];
  };

  # Use powersave governor for quieter operation
  powerManagement.cpuFreqGovernor = "powersave";

  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.latest;
  hardware.nvidia.open = true;
  hardware.nvidia.modesetting.enable = false;
  hardware.nvidia-container-toolkit.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  nixpkgs.overlays = [
    (final: prev: {
      onnxruntime = prev.onnxruntime.override { cudaSupport = true; };
    })
  ];
  services.immich.machine-learning = {
    environment.LD_LIBRARY_PATH = "${pkgs.python312Packages.onnxruntime}/lib/python3.12/site-packages/onnxruntime/capi";
  };

  virtualisation.docker.enable = true;
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      swtpm.enable = true;
    };
  };
  virtualisation.spiceUSBRedirection.enable = true;

  networking = {
    hostName = "redline";
    hostId = "9d649414";
    firewall.allowedTCPPorts = [
      8000 # python -m http.server
    ];
    firewall.allowedUDPPorts = [];
    defaultGateway = "192.168.50.1";
    nameservers = ["1.1.1.1" "1.0.0.1"];
    interfaces.enp68s0f0.ipv4.addresses = [{
      address = "192.168.50.201";
      prefixLength = 24;
    }];
  };
  # wait-online breaks rebuilds: https://github.com/NixOS/nixpkgs/issues/180175
  systemd.services.NetworkManager-wait-online.enable = false;

  security.rtkit.enable = true;
  security.sudo.extraConfig = ''
    Defaults timestamp_timeout=60
  '';
}
