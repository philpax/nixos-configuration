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
      ./power.nix
    ];

  system.stateVersion = "26.05";

  time.timeZone = "Asia/Tokyo";
  networking.hostName = "patlabor";
  philpax.syncthing.device = "patlabor";

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

  # nixpkgs' alsa-ucm-conf 1.2.15.3 mis-parses this card's combined speaker
  # component (spk:cs35l56+cs42l43-spk), so UCM fails and PipeWire falls back
  # to the jack PCM with no speakers. Point PipeWire at a release that parses it
  # via ALSA_CONFIG_UCM2 instead of overlaying alsa-lib (world rebuild).
  systemd.user.services =
    let
      ucm = pkgs.alsa-ucm-conf.overrideAttrs (old: rec {
        version = "1.2.16.1";
        src = pkgs.fetchFromGitHub {
          owner = "alsa-project";
          repo = "alsa-ucm-conf";
          rev = "v${version}";
          hash = "sha256-PBhA5hgwnIB/8h+tikP1PisIY1qrmrs06YzU32lD+bU=";
        };
        patches = [ ]; # nixpkgs' Volt2 patch is already upstream
        # PipeWire's mute control is remapped to both the codec switch and the
        # amp switches under one name, and only the amps take; enable the codec
        # (tweeter) switch with the device instead, or the speakers sound muffled.
        postPatch = (old.postPatch or "") + ''
          sed -i "/^\tEnableSequence \[/a\\\t\tcset \"name='cs42l43 Speaker Digital Switch' on,on\"" \
            ucm2/sof-soundwire/cs42l43-spk.conf
        '';
      });
      env.ALSA_CONFIG_UCM2 = "${ucm}/share/alsa/ucm2";
    in
    {
      pipewire.environment = env;
      wireplumber.environment = env;
    };

  services.asusd.enable = true;
  # The unit binds /etc/asusd rw, but nixpkgs only creates it when a config is set.
  systemd.tmpfiles.rules = [ "d /etc/asusd 0755 root root -" ];
  services.fstrim.enable = true;

  swapDevices = [{
    device = "/swapfile";
    size = 32 * 1024; # 32 GB, sized for hibernation
  }];
  # Offset from `btrfs inspect-internal map-swapfile -r /swapfile`; redo if the file is recreated.
  boot.resumeDevice = "/dev/mapper/luks-134c8196-65af-47c0-a9aa-1f6d940119e5";
  # The OLED is only dimmable over DP AUX. The panel advertises both AUX
  # interfaces; the driver's pick (=1, Intel HDR) blanks it, VESA (=2) works.
  boot.kernelParams = [ "resume_offset=6563072" "xe.enable_dpcd_backlight=2" ];

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
