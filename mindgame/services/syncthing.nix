{ config, ... }:

let
  deviceIds = import ../../common-all/syncthing-device-ids.nix;
in {
  services.syncthing = {
    enable = true;
    user = config.mainUser;
    group = "users";
    dataDir = config.users.users.${config.mainUser}.home;
    configDir = "${config.users.users.${config.mainUser}.home}/.config/syncthing";
    overrideDevices = true;
    overrideFolders = true;
    settings = {
      devices = {
        "redline" = { id = deviceIds.redline; };
        "paprika" = { id = deviceIds.paprika; };
      };
      folders = {
        "Main" = {
          path = "${config.users.users.${config.mainUser}.home}/notes/Main";
          devices = [ "redline" "paprika" ];
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
