{ config, pkgs, ... }:

{
  imports =
    [
      <nixos-hardware/lenovo/thinkpad/t480s>
      ../common-all/configuration.nix
      ../common-desktop/configuration.nix
      ../common-dev/programs/development.nix
      ../common-dev-desktop/configuration.nix
      ../common-dev-desktop/driftwm.nix
      (import ./services { inherit config pkgs; })
    ];

  system.stateVersion = "24.11";

  swapDevices = [{
    device = "/swapfile";
    size = 16 * 1024; # 16 GB
  }];

  time.timeZone = "Europe/Stockholm";
  networking.hostName = "paprika";

  # niri fork/config selection — see ../common-dev-desktop/niri.nix.
  philpax.niri.variant = "niriad";
}
