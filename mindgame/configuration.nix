{ config, pkgs, ... }:

{
  imports =
    [
      # <nixos-hardware/...>          # add when hardware is known
      ../common-all/configuration.nix
      ../common-ai/configuration.nix
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

  # Restrict the SDDM greeter to the MSI ultrawide — the Dell portrait's
  # hotplug churn crashes the weston greeter. Connector names can change;
  # each output entry below is annotated with the device it matches.
  services.displayManager.sddm.wayland.compositorCommand =
    let
      # Written by hand: the nixpkgs INI generator can't emit repeated
      # [output] sections, which is how weston expresses multiple outputs.
      greeterIni = pkgs.writeText "sddm-greeter.ini" ''
        [keyboard]
        keymap_model=${config.services.xserver.xkb.model}
        keymap_layout=${config.services.xserver.xkb.layout}
        keymap_variant=${config.services.xserver.xkb.variant}
        keymap_options=${config.services.xserver.xkb.options}

        [libinput]
        enable-tap=${if config.services.libinput.mouse.tapping then "true" else "false"}
        left-handed=${if config.services.libinput.mouse.leftHanded then "true" else "false"}

        # Only the MSI (DP-1) stays on; unlisted outputs keep their current mode.
        [output]
        name=HDMI-A-2
        mode=off

        [output]
        name=DP-3
        mode=off
      '';
    in
    "${pkgs.weston}/bin/weston --shell=kiosk -c ${greeterIni}";
  # hardware.nvidia.package is set in ./nvidia-bsb-dsc.nix — it wraps
  # nvidiaPackages.latest to patch the open kernel modules for the Bigscreen
  # Beyond's DSC quirks.
  hardware.graphics.enable = true;
  hardware.nvidia.modesetting.enable = true;

  virtualisation.docker.enable = true;
  hardware.nvidia-container-toolkit.enable = true;

  # RTX 5090 (Blackwell, sm_120).
  ai.cudaCapabilities = [ "12.0" ];

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
