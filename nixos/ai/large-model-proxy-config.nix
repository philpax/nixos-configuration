{ pkgs, ... }:
let
  # Port definitions
  openaiPort = 7070;
  managementPort = 7071;
  comfyuiPort = 8188;
  comfyuiTargetPort = 18188;

  # Import modules
  utils = import ./utils.nix { inherit pkgs; };
  llms = import ./llms.nix { inherit pkgs utils; };
  comfyui = import ./comfyui.nix { inherit pkgs comfyuiPort comfyuiTargetPort; };

  # Generate the configuration
  config = {
    OpenAiApi = {
      ListenPort = toString openaiPort;
    };
    ManagementApi = {
      ListenPort = toString managementPort;
    };
    MaxTimeToWaitForServiceToCloseConnectionBeforeGivingUpSeconds = 1200;
    ShutDownAfterInactivitySeconds = 120;
    ResourcesAvailable = {
      "VRAM-GPU-1" = 24000;
      RAM = 96000;
    };
    Services = [
      (utils.mkService {
        name = "ComfyUI";
        listenPort = comfyuiPort;
        targetPort = comfyuiTargetPort;
        command = "${comfyui.comfyuiScript}/bin/comfyui-service";
        args = "";
        killCommand = "docker kill comfyui";
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
      })
    ] ++ llms.llms;
  };

  # Generate the JSON file
  jsonFile = pkgs.writeText "large-model-proxy-config.json" (builtins.toJSON config);

  # Extract all ports from the configuration
  ports = [openaiPort managementPort] ++ (builtins.map (s: builtins.fromJSON s.ListenPort) config.Services);
in
{
  inherit jsonFile ports;
}