{ config, ... }:

let
  folders = import ../folders.nix;
  deviceIds = import ../../common-all/syncthing-device-ids.nix;
in {
  users.users.syncthing = {
    isSystemUser = true;
    group = "syncthing";
    extraGroups = [ "editabledata" ];
    home = "/var/lib/syncthing";
    createHome = true;
  };
  users.groups.syncthing = {};

  services.syncthing = {
    enable = true;
    user = "syncthing";
    group = "syncthing";
    dataDir = "/var/lib/syncthing";
    configDir = "/var/lib/syncthing/.config/syncthing";
    overrideDevices = true;
    overrideFolders = true;
    settings = {
      devices = {
        "iphone" = { id = deviceIds.iphone; };
        "paprika" = { id = deviceIds.paprika; };
        "mindgame-nixos" = { id = deviceIds.mindgame-nixos; };
      };
      folders = {
        "Main" = {
          path = folders.notes;
          devices = [ "iphone" "paprika" "mindgame-nixos" ];
          ignorePerms = true;
        };
      };
      options = {
        minHomeDiskFree = {
          unit = "GB";
          value = 1;
        };
      };
    };
  };

  # Syncthing ports
  networking.firewall.allowedTCPPorts = [ 8384 22000 ];
  networking.firewall.allowedUDPPorts = [ 22000 ];
}
