{ config, pkgs, unstable, ... }:

{
  services.minecraft-server = {
    enable = false;
    eula = true;
    openFirewall = true;
    package = unstable.papermc;
    jvmOpts = "-Xms4092M -Xmx4092M -XX:+UseG1GC";
  };

  # Minecraft server ports
  networking.firewall.allowedTCPPorts = [ 25565 25566 ];
}