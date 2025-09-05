{ config, ... }:

let
  folders = import ../folders.nix;
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
      photos = {
        path = "/mnt/external/Photos";
        comment = "Photos";
        browsable = true;
        "read only" = false;
        "guest ok" = true;
        "create mask" = "0444";
        "directory mask" = "0555";
      };
      videos = {
        path = "/mnt/external/Videos";
        comment = "Videos";
        browsable = true;
        "read only" = false;
        "guest ok" = true;
        "create mask" = "0444";
        "directory mask" = "0555";
      };
      music = {
        path = folders.music;
        comment = "Music";
        browsable = true;
        "read only" = false;
        "guest ok" = true;
        "create mask" = "0444";
        "directory mask" = "0555";
      };
      music_inbox = {
        path = folders.music_inbox;
        comment = "Music Inbox";
        browsable = true;
        "read only" = false;
        "guest ok" = true;
        "create mask" = "0777";
        "directory mask" = "0777";
      };
      written = {
        path = "/mnt/external/Written";
        comment = "Written";
        browsable = true;
        "read only" = false;
        "guest ok" = true;
        "create mask" = "0444";
        "directory mask" = "0555";
      };
    };
  };

  # Samba ports
  networking.firewall.allowedTCPPorts = [ 139 445 ];
  networking.firewall.allowedUDPPorts = [ 137 138 ];
}