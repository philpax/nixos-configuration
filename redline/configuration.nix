{ config, lib, pkgs, ... }:

let
  folders = import ./folders.nix;
in {
  imports =
    [
      ../common-all/configuration.nix
      ../common-ai/configuration.nix
      ./ssd0.nix
      (import ./ai { inherit config pkgs; })
      ./hermes
      (import ./services { inherit config lib pkgs; })
      (import ./programs { inherit config pkgs; })
    ];

  system.stateVersion = "24.11";

  redline.ssd0.enable = true;

  boot.initrd.kernelModules = [
    "nvidia"
  ];
  # btrfs is normally autoloaded via /dev/btrfs-control when udev probes ssd0; on
  # 2026-08-05 a cold boot came up with the module never loaded and the ssd0 device
  # unit never appeared. Loading it unconditionally removes that variable.
  boot.kernelModules = [ "btrfs" ];
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

  # ssd0 and the immich bind that sits on it are gated by redline.ssd0.enable — see
  # ssd0.nix. Both must be absent together: the bind's source lives inside ssd0, and a
  # swapfile or bind mount left behind pins the filesystem and blocks unmounting it.
  fileSystems = lib.mkMerge [
    {
      ${folders.backups.external} = {
        device = "/dev/disk/by-uuid/9EB67FDDB67FB47D";
        fsType = "ntfs";
        options = [ "defaults" "nofail" "x-systemd.automount" "noauto" ];
      };
    }
    (lib.mkIf config.redline.ssd0.enable {
      # nofail on both mounts (the bind fails whenever ssd0 does): if the device
      # doesn't probe — as on the 2026-08-05 cold boot — the box must come up with
      # ssd0's services down rather than drop to an emergency shell, which on a
      # headless machine means walking to it.
      ${folders.mounts.ssd0} = {
        device = "/dev/disk/by-uuid/68847514-728b-451c-8145-b2eaa1871e8d";
        fsType = "btrfs";
        options = [ "compress=zstd" "noatime" "discard=async" "nofail" "x-systemd.device-timeout=30s" ];
      };

      "/var/lib/immich" = {
        device = folders.immich;
        fsType = "none";
        options = [ "bind" "nofail" ];
      };
    })
  ];

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

  # Auto-scrub btrfs weekly.
  #
  # This works — it caught the 2026-08-01 corruption a full week early, on Jul 27
  # (`Error summary: csum=9`, unit exited 3 and went to `failed`). Nobody was told,
  # so the warning was lost. The detection was never the problem; the alerting was.
  # That gap is now covered by services/unit-alerts.nix, which hooks OnFailure= on
  # this unit and shows any failed unit at login.
  services.btrfs.autoScrub = {
    enable = config.redline.ssd0.enable;
    interval = "weekly";
    fileSystems = lib.optionals config.redline.ssd0.enable [ "/mnt/ssd0" ];
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
  # Both GPUs are RTX 3090s (sm_86).
  nixpkgs.config.cudaCapabilities = [ "8.6" ];
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
    interfaces.enp67s0f0.ipv4.addresses = [{
      address = "192.168.50.201";
      prefixLength = 24;
    }];
  };
  # wait-online breaks rebuilds: https://github.com/NixOS/nixpkgs/issues/180175
  systemd.services.NetworkManager-wait-online.enable = false;

  # Swap lives on ssd0, so it goes away with it. This is not optional tidiness: an
  # active swapfile pins the filesystem, and `swapoff` on an already-read-only btrfs
  # fails with EROFS — which is exactly how the 2026-08-01 teardown got stuck.
  swapDevices = lib.optionals config.redline.ssd0.enable [{
    device = "/mnt/ssd0/swapfile";
    size = 64 * 1024; # 64 GB
  }];

  security.rtkit.enable = true;
  security.sudo.extraConfig = ''
    Defaults timestamp_timeout=60
  '';
}
