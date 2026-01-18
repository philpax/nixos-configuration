{ config, ... }:

let
  folders = import ../folders.nix;
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
        "iphone" = { id = "CTLWMSO-UZTMF6D-DKMOSXI-4DST6YP-W2GN3YW-Y5AV4UD-LUXBIBV-WBJXXQ6"; };
        "the-wind-rises" = { id = "NLD2NYH-SAYR2TR-GSRXTMD-EWIQCYN-RNI2UDA-52QQEZX-FVVC3NC-YSPWYAY"; };
        "paprika" = { id = "MOF5BJW-TFNNC62-WHEQYG7-SMYBVSU-GAY7WHA-3ILFZSA-G7SRE5X-LY3DOQ4"; };
      };
      folders = {
        "Main" = {
          path = folders.notes;
          devices = [ "iphone" "the-wind-rises" "paprika" ];
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
