{ config, pkgs, ... }:

{
  imports = [ ../portable.nix ];

  # Vite dev server
  networking.firewall.allowedTCPPorts = [ 5173 ];
}
