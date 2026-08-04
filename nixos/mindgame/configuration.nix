{ config, pkgs, ... }:

{
  imports =
    [
      # <nixos-hardware/...>          # add when hardware is known
      ../common-all/configuration.nix
      ../common-desktop/configuration.nix
      ../common-dev/programs/development.nix
      ../common-dev-desktop/configuration.nix
      ./nixpkgs-xr.nix
      ./nvidia-bsb-dsc.nix
      (import ./programs { inherit config pkgs; })
      (import ./services { inherit config pkgs; })
    ];

  system.stateVersion = "25.11";

  nixpkgs.overlays = [ (import ./overlays/bs-manager.nix) ];

  time.timeZone = "Europe/Stockholm";
  networking.hostName = "mindgame";

  # Give plenty of time at the boot menu to pick Windows.
  boot.loader.timeout = 60;
  # Push our main NixOS instance to the bottom, so that Windows is next to it.
  boot.loader.systemd-boot.sortKey = "z_nixos";

  # Load the NVIDIA modules in the initrd so the GPU is fully up long before
  # graphical.target. Otherwise SDDM's weston greeter can open the DRM node
  # while nvidia-drm is still initialising, EGL fails, and the greeter dies
  # without a retry — leaving a black screen at "Reached target Graphical Interface".
  boot.initrd.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" ];

  services.xserver.videoDrivers = ["nvidia"];
  hardware.nvidia.open = true;
  # hardware.nvidia.package is set in ./nvidia-bsb-dsc.nix — it wraps
  # nvidiaPackages.latest to patch the open kernel modules for the Bigscreen
  # Beyond's DSC quirks.
  hardware.graphics.enable = true;
  hardware.nvidia.modesetting.enable = true;

  virtualisation.docker.enable = true;
  hardware.nvidia-container-toolkit.enable = true;

  swapDevices = [{
    device = "/swapfile";
    size = 128 * 1024; # 128 GB
  }];

  environment.systemPackages = with pkgs; [
    kdePackages.kdenlive
    android-tools
    bs-manager
  ];

  # OBS Studio
  programs.obs-studio = {
    enable = true;
    package = pkgs.obs-studio.override {
      cudaSupport = true;
    };
    plugins = with pkgs.obs-studio-plugins; [
      obs-backgroundremoval
      obs-pipewire-audio-capture
      obs-vaapi
      obs-gstreamer
      obs-vkcapture
    ];
  };
}
