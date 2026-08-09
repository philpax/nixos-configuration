{ config, pkgs, ... }:

{
  # Enable SSH agent system-wide
  programs.ssh.startAgent = true;

  # SSH client configuration
  programs.ssh.extraConfig = ''
    # Automatically add keys to the agent when used
    AddKeysToAgent yes

    # Keep connections alive
    ServerAliveInterval 60
    ServerAliveCountMax 3

    # Use the SSH agent for authentication
    IdentityAgent SSH_AUTH_SOCK
  '';
}
