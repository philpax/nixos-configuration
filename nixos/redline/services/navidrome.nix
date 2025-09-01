{ config, ... }:

{
  services.navidrome = {
    enable = true;
    settings = {
      Address = "0.0.0.0";
      MusicFolder = "/mnt/external/Music";
    };
  };

  # Navidrome port
  networking.firewall.allowedTCPPorts = [ 4533 ];
}