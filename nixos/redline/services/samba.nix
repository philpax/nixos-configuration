{ config, ... }:

let
  folders = import ../folders.nix;

  # Define shares with their names, paths, and comments
  shares = [
    { name = "Photos"; path = folders.photos; }
    { name = "Videos"; path = folders.videos; }
    { name = "Written"; path = folders.written; }
    { name = "Music"; path = folders.music; }
    { name = "Music Inbox"; path = folders.music_inbox; }
    { name = "Backups"; path = folders.backup; }
  ];

  # Function to create share configuration with music_inbox permissions
  createShare = share: {
    ${share.name} = {
      path = share.path;
      comment = share.name;
      browsable = true;
      "read only" = false;
      "guest ok" = true;
      "create mask" = "0777";
      "directory mask" = "0777";
    };
  };

  # Generate all share configurations
  shareConfigs = builtins.foldl' (acc: share: acc // (createShare share)) {} shares;
in
{
  services.samba = {
    enable = true;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = "NixOS SMB Server";
        "server role" = "standalone server";
        "map to guest" = "Bad User";
        "guest account" = "nobody";
        "security" = "user";
        # Disable printing services
        "load printers" = "no";
        "printing" = "bsd";
        "printcap name" = "/dev/null";
      };
    } // shareConfigs;
  };

  # Samba ports
  networking.firewall.allowedTCPPorts = [ 139 445 ];
  networking.firewall.allowedUDPPorts = [ 137 138 ];
}