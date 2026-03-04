{ config, pkgs, unstable ? null }:
let
  shared = import ../../common-all/comfyui.nix {
    inherit pkgs;
    comfyuiDir = "/home/philpax/comfyui";
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
