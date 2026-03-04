{ pkgs, comfyuiPort, comfyuiTargetPort, utils, folders }:
let
  shared = import ../../common-all/comfyui.nix {
    inherit pkgs;
    comfyuiDir = folders.ai.comfyui;
    port = comfyuiTargetPort;
  };

  # ComfyUI service configuration
  service = utils.mkService {
    name = "ComfyUI";
    listenPort = comfyuiPort;
    targetPort = comfyuiTargetPort;
    command = "${shared.comfyuiStartScript}/bin/comfyui-start --foreground";
    args = "";
    killCommand = "${shared.comfyuiStopScript}/bin/comfyui-stop";
    healthcheck = {
      command = "curl --fail http://localhost:${toString comfyuiTargetPort}/system_stats";
      intervalMilliseconds = 200;
    };
    restartOnConnectionFailure = true;
    shutDownAfterInactivitySeconds = 30;
    resourceRequirements = {
      "VRAM-GPU-1" = 20000;
      RAM = 16000;
    };
  };
in
{
  inherit service;
  comfyuiRebuildScript = shared.comfyuiRebuildScript;
  comfyuiStartScript = shared.comfyuiStartScript;
  comfyuiStopScript = shared.comfyuiStopScript;
  inherit comfyuiPort comfyuiTargetPort;
}
