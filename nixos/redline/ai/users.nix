{ config, pkgs, ... }:

{
  users.users.ai = {
    isNormalUser = true;
    description = "AI Services User";
    home = "/home/ai";
    group = "ai";
    extraGroups = [ "docker" ];
  };

  users.groups.ai = {};
}