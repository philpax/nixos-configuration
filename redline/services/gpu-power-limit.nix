{ config, pkgs, ... }:
let
  watts = 250;
  # Lock the GPU clock range to the 3090's base clock so it never boosts.
  # Ampere has no "disable boost" toggle (the old --auto-boost-default flag
  # is Kepler-era and removed), so we cap the locked clock range at base.
  maxClockMHz = 1395;
  nvidia-smi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
in {
  hardware.nvidia.nvidiaPersistenced = true;

  systemd.services.gpu-power-limit = {
    description = "Set NVIDIA GPU power limit to ${toString watts}W and lock clocks to ${toString maxClockMHz}MHz";
    after = [ "nvidia-persistenced.service" ];
    requires = [ "nvidia-persistenced.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        "${nvidia-smi} -pl ${toString watts}"
        "${nvidia-smi} -lgc 0,${toString maxClockMHz}"
      ];
      # Restore the default boost behaviour when the service is stopped.
      ExecStop = "${nvidia-smi} -rgc";
    };
  };
}
