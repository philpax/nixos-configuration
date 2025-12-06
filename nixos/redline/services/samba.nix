{ config, ... }:

let
  folders = import ../folders.nix;

  # Define shares with their names, paths, and comments
  shares = [
    { name = "backup"; path = folders.backup; }
    { name = "datasets"; path = folders.datasets; }
    { name = "documents"; path = folders.documents; }
    { name = "downloads"; path = folders.downloads; }
    { name = "games"; path = folders.games; }
    { name = "installers"; path = folders.installers; }
    { name = "music_inbox"; path = folders.music_inbox; }
    { name = "music"; path = folders.music; }
    { name = "photos"; path = folders.photos; }
    { name = "videos"; path = folders.videos; }
    { name = "written"; path = folders.written; }
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