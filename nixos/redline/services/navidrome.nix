{ config, ... }:

let
  folders = import ../folders.nix;
in
{
  services.navidrome = {
    enable = true;
    settings = {
      Address = "0.0.0.0";
      MusicFolder = folders.music;
    };
  };

  # Navidrome port
  networking.firewall.allowedTCPPorts = [ 4533 ];
}