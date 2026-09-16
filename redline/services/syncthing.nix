{ config, lib, ... }:

let
  folders = import ../folders.nix;
  topology = import ../../common-all/syncthing-topology.nix;
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

  # Main comes from the shared topology; the game folders are local.
  philpax.syncthing.device = "redline";
  philpax.syncthing.folderPaths.Main = folders.notes;
  services.syncthing = {
    user = "syncthing";
    group = "syncthing";
    dataDir = "/var/lib/syncthing";
    configDir = "/var/lib/syncthing/.config/syncthing";
    settings = {
      devices.aynthor.id = topology.devices.aynthor;
      folders = { Main.ignorePerms = true; } // gameFolders // {
        "saves" = gameFolder "Saves";
      };
    };
  };
}
