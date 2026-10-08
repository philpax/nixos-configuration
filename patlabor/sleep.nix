# btintel_pcie's hibernate/suspend callbacks time out waiting for the
# controller to enter D3 (EBUSY), which rolls back the hibernate and then
# fails every suspend after it, while logind retries every 30 s with the lid
# closed. Unbind the driver across sleep, and stop any other failure looping.
{ pkgs, ... }:

let
  driver = "/sys/bus/pci/drivers/btintel_pcie";
  saved = "/run/btintel-pcie-sleep";
in
{
  systemd.services.btintel-pcie-sleep = {
    description = "Unbind the Intel PCIe Bluetooth controller across sleep";
    before = [ "sleep.target" ];
    wantedBy = [ "sleep.target" ];
    unitConfig.StopWhenUnneeded = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      : > ${saved}
      for dev in ${driver}/0000:*; do
        [ -e "$dev" ] || continue
        addr=$(basename "$dev")
        echo "$addr" > ${driver}/unbind
        echo "$addr" >> ${saved}
      done
    '';
    preStop = ''
      [ -f ${saved} ] || exit 0
      while read -r addr; do
        [ -n "$addr" ] || continue
        echo "$addr" > ${driver}/bind || echo "failed to rebind $addr" >&2
      done < ${saved}
      rm -f ${saved}
    '';
  };

  # Three failures in fifteen minutes means it is stuck: hibernate, and if that
  # fails too, power off. Both go to PID 1 directly rather than through logind:
  # with the lid still closed logind has usually started its next retry by the
  # time this runs, and refuses `systemctl hibernate`/`poweroff` as "already in
  # progress". replace-irreversibly also stops that retry cancelling the
  # poweroff. `systemctl start` blocks until the job completes.
  systemd.services.sleep-failure-fallback = {
    description = "Hibernate, then power off, when sleep keeps failing";
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils pkgs.gawk pkgs.systemd ];
    script = ''
      log=/run/sleep-failures
      now=$(date +%s)
      echo "$now" >> "$log"
      recent=$(awk -v since=$((now - 900)) '$1 >= since' "$log")
      printf '%s\n' "$recent" > "$log"
      n=$(printf '%s\n' "$recent" | grep -c .)
      if [ "$n" -lt 3 ]; then
        exit 0
      fi
      echo "sleep failed $n times in 15 minutes; hibernating instead"
      : > "$log"
      if systemctl start --job-mode=replace-irreversibly hibernate.target; then
        exit 0
      fi
      echo "hibernate failed as well; powering off"
      systemctl start --job-mode=replace-irreversibly poweroff.target
    '';
  };
  systemd.services.systemd-suspend.unitConfig.OnFailure = "sleep-failure-fallback.service";
  systemd.services.systemd-suspend-then-hibernate.unitConfig.OnFailure = "sleep-failure-fallback.service";
}
