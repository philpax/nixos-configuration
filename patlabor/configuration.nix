# ASUS ROG Zephyrus G14 2026 (GU405AR): Intel Core Ultra 9 386H + RTX 5070 Ti
# Mobile as PRIME offload. Not in nixos-hardware; settings mirror asus/zephyrus/gu605cw.
{ config, pkgs, ... }:

{
  imports =
    [
      ../common-all/configuration.nix
      ../common-desktop/configuration.nix
      ../common-desktop/nvidia.nix
      ../common-dev/programs/development.nix
      ../common-dev-desktop/configuration.nix
      (import ./services { inherit config pkgs; })
    ];

  system.stateVersion = "26.05";

  time.timeZone = "Asia/Tokyo";
  networking.hostName = "patlabor";

  # Bus IDs from /sys/bus/pci/devices.
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.graphics.enable = true;
  hardware.nvidia = {
    open = true; # required for Blackwell
    modesetting.enable = true;
    powerManagement.enable = true;
    powerManagement.finegrained = true;
    dynamicBoost.enable = true;
    prime = {
      offload.enable = true;
      offload.enableOffloadCmd = true;
      intelBusId = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };

  # Panther Lake iGPU.
  boot.initrd.kernelModules = [ "xe" ];
  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver
    intel-compute-runtime
    vpl-gpu-rt
  ];
  hardware.graphics.extraPackages32 = with pkgs; [
    driversi686Linux.intel-media-driver
  ];

  services.asusd.enable = true;
  # The unit binds /etc/asusd rw, but nixpkgs only creates it when a config is set.
  systemd.tmpfiles.rules = [ "d /etc/asusd 0755 root root -" ];
  services.power-profiles-daemon.enable = true;
  services.fstrim.enable = true;

  swapDevices = [{
    device = "/swapfile";
    size = 32 * 1024; # 32 GB, sized for hibernation
  }];
  # Offset from `btrfs inspect-internal map-swapfile -r /swapfile`; redo if the file is recreated.
  boot.resumeDevice = "/dev/mapper/luks-134c8196-65af-47c0-a9aa-1f6d940119e5";
  boot.kernelParams = [ "resume_offset=6563072" ];

  services.logind.settings.Login = {
    HandleLidSwitch = "suspend-then-hibernate";
    HandleLidSwitchExternalPower = "suspend";
  };
  systemd.sleep.settings.Sleep.HibernateDelaySec = "2h";

  # Podman native, Docker for compatibility; socket-activated, not on the boot path.
  virtualisation.podman = {
    enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };
  virtualisation.docker = {
    enable = true;
    enableOnBoot = false;
    listenOptions = [ "/run/docker.sock" ];
    daemon.settings.live-restore = true;
  };
  # Root-equivalent; see the note on extraGroups in ../common-all/configuration.nix.
  users.users.${config.mainUser}.extraGroups = [ "docker" ];
}
