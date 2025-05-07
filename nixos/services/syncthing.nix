{ config, ... }:

{
  services.syncthing = {
    enable = true;
    user = "philpax";
    dataDir = "/home/philpax";
    configDir = "/home/philpax/.config/syncthing";
    overrideDevices = true;
    overrideFolders = true;
    guiAddress = "127.0.0.1:8384";
    settings = {
      devices = {
        "work-mbp" = { id = "755IIFA-4U6ZX4Z-MYVIMZT-6BR5MDT-UDGV42J-CDXBRC7-RVC26M2-XAEO3AB"; };
        "the-wind-rises" = { id = "NLD2NYH-SAYR2TR-GSRXTMD-EWIQCYN-RNI2UDA-52QQEZX-FVVC3NC-YSPWYAY"; };
      };
      folders = {
        "Notes" = {
          path = "/mnt/ssd2/notes";
          devices = [ "work-mbp" "the-wind-rises" ];
        };
      };
    };
  };

  # Syncthing ports
  networking.firewall.allowedTCPPorts = [ 8384 22000 ];
  networking.firewall.allowedUDPPorts = [ 22000 ];
}