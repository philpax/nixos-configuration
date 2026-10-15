# The part of common-all that both NixOS and Frame's system-manager
# configuration understand. NixOS-only settings live in configuration.nix.
{ lib, pkgs, ... }:
{
  imports = [ ./syncthing.nix ];

  options.mainUser = lib.mkOption {
    type = lib.types.str;
    default = "philpax";
    description = "The primary human user account: the one with sudo, the interactive desktop session, and the personal files under /home/<name>. Modules derive home paths from this rather than hardcoding them.";
  };

  config = {
    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = lib.concatMap (list: import list { inherit pkgs; }) [
      ./packages/development.nix
      ./packages/helix.nix
      ./packages/media.nix
      ./packages/network.nix
      ./packages/system.nix
    ];

    programs.fish.enable = true;

    programs.ssh.startAgent = true;
    programs.ssh.extraConfig = ''
      # Automatically add keys to the agent when used
      AddKeysToAgent yes

      # Keep connections alive
      ServerAliveInterval 60
      ServerAliveCountMax 3

      # Use the SSH agent for authentication
      IdentityAgent SSH_AUTH_SOCK
    '';
  };
}
