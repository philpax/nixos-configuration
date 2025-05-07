{ config, ... }:

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
        comment = "Read-only Photos Share";
        browsable = true;
        "read only" = true;
        "guest ok" = true;
        "create mask" = "0444";
        "directory mask" = "0555";
      };
      videos = {
        path = "/mnt/external/Videos";
        comment = "Videos Share";
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