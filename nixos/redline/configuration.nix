{ config, lib, pkgs, ... }:

let
  folders = import ./folders.nix;
in {
  imports =
    [
      ../common-all/configuration.nix
      (import ./ai { inherit config pkgs; })
      (import ./services { inherit config lib pkgs; })
      (import ./programs { inherit config pkgs; })
    ];

  system.stateVersion = "24.11";

  boot.initrd.kernelModules = [
    "nvidia"
  ];
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  # acpi_enforce_resources=lax: the Aorus TRX40 DSDT declares an ACPI OperationRegion
  # over the FCH SMBus I/O range (0xB00-0xB0F), so i2c-piix4's probe hits
  # acpi_check_region() and returns -ENODEV before claiming it. The module loads but
  # never binds to 00:14.0, so no SMBus adapter appears and OpenRGB can't see the
  # Corsair DDR4 DIMMs. `lax` downgrades that conflict to a warning.
  # Caveat: AML and the driver can now both drive the bus.
  boot.kernelParams = [ "nomodeset" "nvme_core.default_ps_max_latency_us=0" "pcie_aspm=off" "acpi_enforce_resources=lax" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.supportedFilesystems = [ "ntfs" "zfs" ];
  boot.zfs.forceImportRoot = true;
  boot.zfs.extraPools = [ "storage" ];

  fileSystems = {
    ${folders.mounts.ssd0} = {
      device = "/dev/disk/by-uuid/68847514-728b-451c-8145-b2eaa1871e8d";
      fsType = "btrfs";
      options = [ "compress=zstd" "noatime" "discard=async" ];
    };

    ${folders.backups.external} = {
      device = "/dev/disk/by-uuid/9EB67FDDB67FB47D";
      fsType = "ntfs";
      options = [ "defaults" "nofail" "x-systemd.automount" "noauto" ];
    };

    "/var/lib/immich" = {
      device = folders.immich;
      fsType = "none";
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
  # schedutil scales with load: idles low but boosts to 3.8-4.5 GHz under
  # inference. The previous "powersave" + acpi-cpufreq pinned all cores to
  # the 2.2 GHz floor, costing ~40% CPU throughput on hybrid LLM serving
  # (discovered tuning GLM-5.2, 2026-07-21).
  powerManagement.cpuFreqGovernor = "schedutil";

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
    interfaces.enp68s0f0.ipv4.addresses = [{
      address = "192.168.50.201";
      prefixLength = 24;
    }];
  };
  # wait-online breaks rebuilds: https://github.com/NixOS/nixpkgs/issues/180175
  systemd.services.NetworkManager-wait-online.enable = false;

  swapDevices = [{
    device = "/mnt/ssd0/swapfile";
    size = 64 * 1024; # 64 GB
  }];

  security.rtkit.enable = true;
  security.sudo.extraConfig = ''
    Defaults timestamp_timeout=60
  '';
}
