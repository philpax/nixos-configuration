{ config, unstable, ... }:

let
  folders = import ../folders.nix;
in
{
  services.navidrome = {
    enable = true;
    package = unstable.navidrome;
    settings = {
      Address = "0.0.0.0";
      MusicFolder = folders.music;
    };
  };

  users.users.navidrome.extraGroups = [ "editabledata" ];

  # Navidrome port
  networking.firewall.allowedTCPPorts = [ 4533 ];
}
