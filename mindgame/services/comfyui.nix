{ config, pkgs, ... }:
let
  shared = import ../../common-all/comfyui.nix {
    inherit pkgs;
    comfyuiDir = "${config.users.users.${config.mainUser}.home}/comfyui";
    port = 8188;
  };
in
{
  environment.systemPackages = [
    shared.comfyuiRebuildScript
    shared.comfyuiStartScript
    shared.comfyuiStopScript
  ];

  networking.firewall.allowedTCPPorts = [ 8188 ];
}
