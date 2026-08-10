{ config, ... }:

{
  services.samba = {
    enable = true;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = config.networking.hostName;
        "server role" = "standalone server";
        "map to guest" = "Bad User";
        "security" = "user";
        "force user" = config.mainUser;
        "force group" = "users";
        "load printers" = "no";
        "printing" = "bsd";
        "printcap name" = "/dev/null";
      };
      biome = {
        path = "${config.users.users.${config.mainUser}.home}/work/owl/Biome";
        comment = "Biome";
        browsable = true;
        "read only" = false;
        "guest ok" = true;
        "create mask" = "0777";
        "directory mask" = "0777";
      };
    };
  };

  # Samba ports
  networking.firewall.allowedTCPPorts = [ 139 445 ];
  networking.firewall.allowedUDPPorts = [ 137 138 ];
}
