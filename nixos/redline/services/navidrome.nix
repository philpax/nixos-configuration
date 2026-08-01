{ config, lib, pkgs, ... }:

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

  # Only extend the user the navidrome module creates. The mkIf has to wrap the whole
  # `users.users` attrset, not just extraGroups: naming `users.users.navidrome.*` at all
  # instantiates that submodule, and with the service disabled (e.g. via
  # redline.ssd0.enable = false) it has no group or isSystemUser and fails evaluation.
  users.users = lib.mkIf config.services.navidrome.enable {
    navidrome.extraGroups = [ "editabledata" ];
  };

  # Navidrome port
  networking.firewall.allowedTCPPorts = [ 4533 ];
}
