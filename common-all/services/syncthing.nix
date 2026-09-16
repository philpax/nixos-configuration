# Syncthing peers and folders derived from ../syncthing-topology.nix.
{ config, lib, ... }:

let
  cfg = config.philpax.syncthing;
  topology = import ../syncthing-topology.nix;
  home = config.users.users.${config.mainUser}.home;
  folders = lib.filterAttrs (_: members: builtins.elem cfg.device members) topology.folders;
  peers = lib.unique (lib.remove cfg.device (lib.concatLists (builtins.attrValues folders)));
in
{
  options.philpax.syncthing = {
    device = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum (builtins.attrNames topology.devices));
      default = null;
      description = "This machine's name in syncthing-topology.nix; null leaves Syncthing off.";
    };
    folderPaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Folder path overrides; the default is ~/notes/<name>.";
    };
  };

  config = lib.mkIf (cfg.device != null) {
    services.syncthing = {
      enable = true;
      user = lib.mkDefault config.mainUser;
      group = lib.mkDefault "users";
      dataDir = lib.mkDefault home;
      configDir = lib.mkDefault "${home}/.config/syncthing";
      overrideDevices = true;
      overrideFolders = true;
      settings = {
        devices = lib.genAttrs peers (d: { id = topology.devices.${d}; });
        folders = lib.mapAttrs (name: members: {
          path = cfg.folderPaths.${name} or "${home}/notes/${name}";
          devices = lib.remove cfg.device members;
        }) folders;
        options.minHomeDiskFree = { unit = "GB"; value = 1; };
      };
    };
    networking.firewall.allowedTCPPorts = [ 8384 22000 ];
    networking.firewall.allowedUDPPorts = [ 22000 ];
  };
}
