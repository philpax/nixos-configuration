{ config, pkgs, ... }:

let
  folders = import ../folders.nix;
in
{
  services.navidrome = {
    enable = true;
    package = pkgs.navidrome;
    settings = {
      Address = "0.0.0.0";
      MusicFolder = folders.music;
      Subsonic.AppendAlbumVersion = false;
    };
  };

  users.users.navidrome.extraGroups = [ "editabledata" ];

  # Navidrome port
  networking.firewall.allowedTCPPorts = [ 4533 ];
}
