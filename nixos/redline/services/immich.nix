{ config, pkgs, unstable, ... }:
let
    port = 2283;
in
{
  services.immich = {
    enable = true;
    port = port;
    package = unstable.immich;
    host = "0.0.0.0";
    accelerationDevices = null;
  };

  users.users.immich.extraGroups = [ "video" "render" ];
  networking.firewall.allowedTCPPorts = [ port ];
}