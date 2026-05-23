{ config, pkgs, lib, unstable, unstableGfx, ... }:

{
  imports =
    [
      # <nixos-hardware/...>          # add when hardware is known
      ../common-all/configuration.nix
      ../common-desktop/configuration.nix
      ../common-dev/programs/development.nix
      ../common-dev-desktop/configuration.nix
      ./nixpkgs-xr.nix
      (import ./services { inherit config pkgs unstable; })
    ];

  system.stateVersion = "25.11";

  time.timeZone = "Europe/Stockholm";  # placeholder — update for actual location
  networking.hostName = "mindgame";
  # Held to 2026-04-25 unstable via unstableGfx (see common-all). 25.11
  # stable's 580.142 lacks features we want; current unstable's 595.71.05 +
  # kernel 7.0.9 breaks EGL/GBM on Blackwell (RTX 5090). The unstableGfx pin
  # gives us 595.58.03 + 7.0.1, the last-known-working combo on this GPU.
  # Drop both overrides once we migrate to 26.05. Timebomb: see common-all.
  boot.kernelPackages = lib.mkForce unstableGfx.linuxPackages_latest;

  services.xserver.videoDrivers = ["nvidia"];
  hardware.nvidia.open = true;
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.latest;
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
  ];

  # OBS Studio
  programs.obs-studio = {
    enable = true;
    package = pkgs.obs-studio.override {
      cudaSupport = true;
    };
    plugins = with pkgs.obs-studio-plugins; [
      wlrobs
      obs-backgroundremoval
      obs-pipewire-audio-capture
      obs-vaapi
      obs-gstreamer
      obs-vkcapture
    ];
  };
}
