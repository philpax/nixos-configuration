{ pkgs, ... }:
let
  no-rgb = pkgs.writeScriptBin "no-rgb" ''
    #!/bin/sh
    # openrgb can wedge indefinitely talking to some devices over i2c/USB,
    # so every invocation gets a hard timeout.
    NUM_DEVICES=$(timeout 30 ${pkgs.openrgb}/bin/openrgb --noautoconnect --list-devices | grep -cE '^[0-9]+: ')

    for i in $(seq 0 $(($NUM_DEVICES - 1))); do
      timeout 30 ${pkgs.openrgb}/bin/openrgb --noautoconnect --device $i --mode static --color 000000
    done
  '';
in {
  config = {
    services.udev.packages = [ pkgs.openrgb ];
    boot.kernelModules = [ "i2c-dev" ];
    hardware.i2c.enable = true;

    systemd.services.no-rgb = {
      description = "no-rgb";
      serviceConfig = {
        ExecStart = "${no-rgb}/bin/no-rgb";
        Type = "oneshot";
        # oneshot start timeout defaults to infinity; a wedged openrgb once
        # blocked multi-user.target (and nixos-rebuild) for three days.
        TimeoutStartSec = "2min";
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}
