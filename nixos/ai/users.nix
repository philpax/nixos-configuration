{ config, pkgs, ... }:

{
  users.users.ai = {
    isNormalUser = true;
    description = "AI Services User";
    home = "/mnt/ssd2/ai";
    createHome = true;
    group = "ai";
    extraGroups = [ "docker" ];
  };

  users.groups.ai = {};

  # Ensure the AI directory exists and has correct permissions
  system.activationScripts.aiDir = pkgs.lib.mkAfter ''
    mkdir -p /mnt/ssd2/ai
    chown -R ai:ai /mnt/ssd2/ai
    chmod -R 775 /mnt/ssd2/ai
  '';
}