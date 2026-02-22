{ config, pkgs, unstable, ... }:

{
  imports =
    [
      <nixos-hardware/lenovo/thinkpad/t480s>
      ../common-all/configuration.nix
      ../common-desktop/configuration.nix
      ../common-dev/programs/development.nix
      ../common-dev-desktop/configuration.nix
      (import ./services { inherit config pkgs unstable; })
    ];

  system.stateVersion = "24.11";

  time.timeZone = "Europe/Stockholm";
  networking.hostName = "paprika";
}
