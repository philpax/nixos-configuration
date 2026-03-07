{ config, lib, ... }:

let
  folders = import ../folders.nix;
  deviceIds = import ../../common-all/syncthing-device-ids.nix;
  gamesDir = "/storage/installers/Games";
  gameFolder = name: {
    path = "${gamesDir}/${name}";
    devices = [ "aynthor" ];
    ignorePerms = true;
    versioning = {
      type = "simple";
      params.keep = "5";
    };
  };
  # Not synced: ps3, windows, x360
  gameFolders = lib.genAttrs
    [ "dreamcast" "gba" "gc" "n3ds" "n64" "nds" "ps2" "psp" "psvita" "psx" "saturn" "snes" "switch" "wii" "wiiu" ]
    gameFolder;
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
        "mindgame-windows" = { id = deviceIds.mindgame-windows; };
      };
      folders = {
        "Main" = {
          path = folders.notes;
          devices = [ "iphone" "paprika" "mindgame-nixos" "mindgame-windows" ];
          ignorePerms = true;
        };
      } // gameFolders // {
        "saves" = gameFolder "Saves";
        "comfyui-models" = {
          path = "${folders.ai.comfyui}/models";
          devices = [ "mindgame-nixos" ];
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
