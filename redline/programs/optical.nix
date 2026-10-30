{ config, pkgs, ... }:

{
  # MakeMKV talks to the BW-16D1HT through SCSI generic devices
  boot.kernelModules = [ "sg" ];

  environment.systemPackages = with pkgs; [
    makemkv
    # Secure CD ripping with AccurateRip; read offset lives in whipper.conf
    whipper
    flac
  ];
}
