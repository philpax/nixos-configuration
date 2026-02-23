{ config, pkgs, unstable, ... }:

{
  imports =
    [
      # <nixos-hardware/...>          # add when hardware is known
      ../common-all/configuration.nix
      ../common-desktop/configuration.nix
      ../common-dev/programs/development.nix
      ../common-dev-desktop/configuration.nix
      # (import ./services { inherit config pkgs unstable; })
    ];

  system.stateVersion = "25.11";

  time.timeZone = "Europe/Stockholm";  # placeholder — update for actual location
  networking.hostName = "mindgame";
  services.xserver.videoDrivers = ["nvidia"];
  hardware.nvidia.open = true;
  hardware.graphics.enable = true;
  hardware.nvidia.modesetting.enable = true;
}
