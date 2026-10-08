{ config, pkgs, ... }:

{
  environment.systemPackages = import ../packages/development.nix { inherit pkgs; };

  # Vite dev server
  networking.firewall.allowedTCPPorts = [ 5173 ];
}
