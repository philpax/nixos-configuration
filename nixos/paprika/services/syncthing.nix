{ config, ... }:

{
  services.syncthing = {
    enable = true;
    user = "philpax";
    dataDir = "/home/philpax";
    configDir = "/home/philpax/.config/syncthing";
    overrideDevices = true;
    overrideFolders = true;
    settings = {
      devices = {
        "the-wind-rises" = { id = "NLD2NYH-SAYR2TR-GSRXTMD-EWIQCYN-RNI2UDA-52QQEZX-FVVC3NC-YSPWYAY"; };
        "redline" = { id = "MUFOKAR-D7CL6A6-2PUXSY3-KBWLORN-3R6HCUA-L2HW664-MKLYAXO-4Y2DCQK"; };
      };
      folders = {
        "Main" = {
          path = "/home/philpax/notes/Main";
          devices = [ "redline" "the-wind-rises" ];
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
