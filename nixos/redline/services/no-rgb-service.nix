{ pkgs, ... }:
let
  # DDR4 kits whose RGB register window and LED count have been verified by
  # hand on this machine. Adding a kit here is not a formality: confirm its
  # controllers actually sit at 0x58-0x5F and that OpenRGB reports the right
  # LED count, or the Direct-mode packet will be the wrong size.
  allowedKits = [
    "CMW128GX4M4Z3200C16"
    "CMW128GX4M4E3200C16"
  ];

  no-rgb = pkgs.writeScriptBin "no-rgb" ''
    #!/bin/sh
    # openrgb can wedge indefinitely talking to some devices over i2c/USB,
    # so every invocation gets a hard timeout.
    OPENRGB="${pkgs.openrgb}/bin/openrgb"
    ALLOWED_KITS="${builtins.concatStringsSep " " allowedKits}"

    DEVICES=$(timeout 30 $OPENRGB --noautoconnect --list-devices 2>/dev/null)
    NUM=$(echo "$DEVICES" | grep -cE '^[0-9]+: ')

    dev_name() {
      echo "$DEVICES" | ${pkgs.gawk}/bin/awk -v want="$1" \
        '/^[0-9]+: /{idx=$1; sub(/:/,"",idx); if (idx==want) {sub(/^[0-9]+: /,""); print; exit}}'
    }
    dev_addr() {
      echo "$DEVICES" | ${pkgs.gawk}/bin/awk -v want="$1" \
        '/^[0-9]+: /{idx=$1; sub(/:/,"",idx)} idx==want && /Location:/ && /address 0x/{print $NF; exit}'
    }

    # Bus hosting the DIMM RGB controllers. Other SMBus segments can carry
    # phantom SPD instantiations that read back garbage, so the allowlist
    # check below is scoped to this bus rather than globbing every bus.
    DIMM_BUS=$(echo "$DEVICES" | sed -n \
      's#.*Location:.*(/dev/i2c-\([0-9]\+\)), address 0x5[89ABCDEFabcdef]$#\1#p' | head -1)

    # Gate: every populated DDR4 DIMM must be a kit we've verified. ee1004
    # only binds DDR4 SPD (DDR5 uses spd5118), so a future DDR5 rebuild finds
    # no SPDs here, leaves dimms_ok=0, and skips the DIMM writes entirely.
    # Fails closed: an unrecognised stick means we touch no DIMM at all.
    dimms_ok=1
    found_spd=0
    if [ -n "$DIMM_BUS" ]; then
      for eeprom in /sys/bus/i2c/devices/"$DIMM_BUS"-00*/eeprom; do
        [ -e "$eeprom" ] || continue
        [ "$(cat "$(dirname "$eeprom")/name" 2>/dev/null)" = "ee1004" ] || continue
        found_spd=1
        pn=$(dd if="$eeprom" bs=1 skip=329 count=20 2>/dev/null | tr -d '\0' | tr -d ' ')
        case " $ALLOWED_KITS " in
          *" $pn "*) ;;
          *) echo "no-rgb: unrecognised DIMM '$pn', skipping all DIMM writes"; dimms_ok=0 ;;
        esac
      done
    fi
    [ "$found_spd" -eq 1 ] || dimms_ok=0

    # Collect every device into ONE invocation. openrgb re-runs a full device
    # detection pass on startup (~17s here, dominated by SMBus probing), so
    # invoking it per device took over two minutes and tripped the start
    # timeout. Chained --device/--mode/--color groups detect once and apply
    # to all of them, which is the difference between ~35s and ~200s.
    ARGS=""
    i=0
    while [ "$i" -lt "$NUM" ]; do
      name=$(dev_name "$i")
      addr=$(dev_addr "$i")

      case "$name" in
        # OpenRGB segfaults on the Hydro controller; liquidctl drives it below.
        *Hydro*)
          i=$((i + 1)); continue
          ;;
      esac

      case "$addr" in
        0x5[89ABCDEFabcdef])
          # DIMM RGB controller.
          [ "$dimms_ok" -eq 1 ] || { i=$((i + 1)); continue; }
          ;;
        0x1[89ABCDEFabcdef])
          # Phantom: OpenRGB's Corsair DRAM probe also scans the JEDEC
          # JC-42.4 thermal-sensor range and false-positives there. The
          # kernel's jc42 driver owns these addresses, so leave them alone.
          i=$((i + 1)); continue
          ;;
      esac

      # Direct, not static: neither the 3090 nor the Hydro has a Static mode,
      # so the previous --mode static calls silently failed for them.
      ARGS="$ARGS --device $i --mode direct --color 000000"
      i=$((i + 1))
    done

    [ -n "$ARGS" ] && timeout 60 $OPENRGB --noautoconnect $ARGS

    # The AIO pump block/fan LEDs, via its own protocol rather than OpenRGB's.
    timeout 30 ${pkgs.liquidctl}/bin/liquidctl --match H150i set led color off || true
  '';
in {
  config = {
    services.udev.packages = [ pkgs.openrgb ];
    boot.kernelModules = [ "i2c-dev" ];
    hardware.i2c.enable = true;

    systemd.services.no-rgb = {
      description = "no-rgb";
      # Ordered *after* multi-user.target, not before it. Turning the LEDs off
      # is cosmetic and takes ~35s (two openrgb detection passes), so gating
      # the target on it delayed every other service on the box by that much.
      # WantedBy still pulls it in at boot; After just stops it blocking.
      after = [ "systemd-modules-load.service" "multi-user.target" ];
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
