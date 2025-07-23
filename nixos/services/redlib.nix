{ config, pkgs, unstable, ... }:

{
  services.redlib = {
    enable = true;
    openFirewall = true;
    package = unstable.redlib;
    port = 10000;
  };
}