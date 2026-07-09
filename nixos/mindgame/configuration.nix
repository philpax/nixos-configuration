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
      (import ./programs { inherit config pkgs; })
      (import ./services { inherit config pkgs; })
    ];

  system.stateVersion = "25.11";

  time.timeZone = "Europe/Stockholm";  # placeholder — update for actual location
  networking.hostName = "mindgame";

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
