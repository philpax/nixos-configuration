{ config, pkgs, ... }:

let
  ddclientSecrets = import ../ddclient-secrets.nix;
in
{
  services.ddclient = {
    enable = true;
    configFile = pkgs.writeText "ddclient-config" ''
      protocol=namecheap
      use=web, web=dynamicdns.park-your-domain.com/getip
      server=dynamicdns.park-your-domain.com
      login=philpax.me
      password=${ddclientSecrets.password}
      promare.philpax.me
    '';
  };
}