{ config, ... }:

let
  folders = import ../folders.nix;
  deviceIds = import ../../common-all/syncthing-device-ids.nix;
  gamesDir = "/storage/installers/Games";
  gameFolder = name: {
    path = "${gamesDir}/${name}";
    devices = [ "aynthor" ];
    ignorePerms = true;
  };
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
        "aynthor" = { id = deviceIds.aynthor; };
      };
      folders = {
        "Main" = {
          path = folders.notes;
          devices = [ "iphone" "paprika" "mindgame-nixos" ];
          ignorePerms = true;
        };
        "gc" = gameFolder "gc";
        "n3ds" = gameFolder "n3ds";
        "nds" = gameFolder "nds";
        "ps2" = gameFolder "ps2";
        "psvita" = gameFolder "psvita";
        "psx" = gameFolder "psx";
        "switch" = gameFolder "switch";
        "wii" = gameFolder "wii";
        "wiiu" = gameFolder "wiiu";
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
