{ pkgs, ... }:
let
  # Port definitions
  openaiPort = 7070;
  managementPort = 7071;
  comfyuiPort = 8188;
  comfyuiTargetPort = 18188;
  llmBasePort = 8200;
  llmBaseTargetPort = 18200;

  # Import modules
  utils = import ./utils.nix { inherit pkgs; };
  llms = import ./llms.nix { inherit pkgs utils llmBasePort llmBaseTargetPort; };
  comfyui = import ./comfyui.nix { inherit pkgs comfyuiPort comfyuiTargetPort utils; };

  # Generate the configuration
  config = {
    OpenAiApi = {
      ListenPort = toString openaiPort;
    };
    ManagementApi = {
      ListenPort = toString managementPort;
    };
    DefaultServiceUrl = "http://redline:{{.PORT}}";
    MaxTimeToWaitForServiceToCloseConnectionBeforeGivingUpSeconds = 1200;
    ShutDownAfterInactivitySeconds = 120;
    ResourcesAvailable = {
      "VRAM-GPU-1" = 24000;
      "VRAM-GPU-2" = 24000;
      RAM = 96000;
    };
    Services = [comfyui.service] ++ llms.llms;
  };

  # Generate the JSON file
  jsonFile = pkgs.writeText "large-model-proxy-config.json" (builtins.toJSON config);

  # Extract all ports from the configuration
  ports = [openaiPort managementPort] ++ (builtins.map (s: builtins.fromJSON s.ListenPort) config.Services);
in
{
  inherit jsonFile ports;
}