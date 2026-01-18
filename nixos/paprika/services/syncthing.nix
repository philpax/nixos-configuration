{ config, ... }:

{
  services.syncthing = {
    enable = true;
    user = "philpax";
    group = "users";
    dataDir = "/home/philpax";
    configDir = "/home/philpax/.config/syncthing";
    overrideDevices = true;
    overrideFolders = true;
    settings = {
      devices = {
        "the-wind-rises" = { id = "NLD2NYH-SAYR2TR-GSRXTMD-EWIQCYN-RNI2UDA-52QQEZX-FVVC3NC-YSPWYAY"; };
        "redline" = { id = "MHZ62PM-H2JVD52-Z73DOWH-WSSOQKI-CYGJSMR-QVSKHGB-DHCTCU2-LKURZAU"; };
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
