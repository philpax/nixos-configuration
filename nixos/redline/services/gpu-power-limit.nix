{ config, pkgs, ... }:
let
  watts = 270;
in {
  hardware.nvidia.nvidiaPersistenced = true;

  systemd.services.gpu-power-limit = {
    description = "Set NVIDIA GPU power limit to ${toString watts}W";
    after = [ "nvidia-persistenced.service" ];
    requires = [ "nvidia-persistenced.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi -pl ${toString watts}";
    };
  };
}
