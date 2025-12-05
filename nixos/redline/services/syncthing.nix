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
        "iphone" = { id = "CTLWMSO-UZTMF6D-DKMOSXI-4DST6YP-W2GN3YW-Y5AV4UD-LUXBIBV-WBJXXQ6"; };
        "the-wind-rises" = { id = "NLD2NYH-SAYR2TR-GSRXTMD-EWIQCYN-RNI2UDA-52QQEZX-FVVC3NC-YSPWYAY"; };
        "paprika" = { id = "6AJNFQE-DCDVHBD-UVPZINA-5HGY655-VGVCG2H-X7D7EL6-IEWWMIZ-F2LJSAQ"; };
      };
      folders = {
        "Main" = {
          path = "/mnt/ssd0/notes/Main";
          devices = [ "iphone" "the-wind-rises" "paprika" ];
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
