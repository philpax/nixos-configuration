# BCD clock on the lid's Slash Lighting strip. asusctl 6.3.x does not know the
# GU405's 35-zone strip (its board-name match stops at the 2025 models), so
# slash_clock.py drives the hidraw node directly with the packets G-Helper uses.
# The service runs as root because the ITE 8910 hidraw node is root-only; it is
# stopped across sleep so the firmware keeps its own sleep behaviour, and
# restarted on resume because the controller re-enumerates.
{ pkgs, ... }:

let
  script = ./slash_clock.py;
  slash-clock = pkgs.writeShellScriptBin "slash-clock" ''
    exec ${pkgs.python3}/bin/python3 ${script} "$@"
  '';
in
{
  environment.systemPackages = [ slash-clock ];

  systemd.services.slash-clock = {
    description = "BCD clock on the Slash Lighting strip";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${slash-clock}/bin/slash-clock clock";
      Restart = "always";
      RestartSec = 2;
      # Root for the hidraw node, but nothing else.
      DevicePolicy = "closed";
      DeviceAllow = [ "char-hidraw rw" ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateNetwork = true;
      NoNewPrivileges = true;
    };
  };

  systemd.services.slash-clock-sleep = {
    description = "Pause the Slash Lighting clock across sleep";
    before = [ "sleep.target" ];
    wantedBy = [ "sleep.target" ];
    unitConfig.StopWhenUnneeded = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.systemd}/bin/systemctl stop slash-clock.service";
      ExecStop = "${pkgs.systemd}/bin/systemctl start slash-clock.service";
    };
  };
}
