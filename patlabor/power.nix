# Battery-first power policy for the Zephyrus G14.
#
# The machine idles at ~21.8 W with the dGPU awake and power-profiles-daemon
# left on `performance`. Switching the profile alone measured 18.2 W, and the
# dGPU was drawing a further 5.9 W of that, so this should land near 12 W —
# the second figure is arithmetic, not yet measured. Two things were doing the
# damage:
#
#   * power-profiles-daemon has no AC/battery logic of its own — GNOME and KDE
#     drive it and niri has no equivalent — so it sat on whatever profile it was
#     last given, holding EPP=performance across all 16 cores. `ac-power-profile`
#     below follows the adapter instead.
#   * The RTX 5070 Ti drew ~5.9 W at P8 around the clock. `powerManagement.
#     finegrained` is armed (the driver reports DynamicPowerManagement: 2) but
#     can never engage, because niri enumerates /dev/dri/card1 at startup and
#     holds a GL context on it for as long as the session lives. supergfxd takes
#     the card off the PCI bus entirely, which is 0 W rather than a better idle.
{ pkgs, lib, ... }:

let
  # Both the barrel jack (ACAD) and the two USB-C PD sources can power the
  # machine, and only one of them reads online at a time, so test all of them.
  # NixOS runs unit scripts under `set -e`, so this has to be a real `if` — a
  # `[ ... ] && on=1` exits the script on the first supply that reads 0, which
  # on battery is every one of them.
  onAc = ''
    on=0
    for p in /sys/class/power_supply/*/online; do
      if [ "$(cat "$p" 2>/dev/null)" = 1 ]; then on=1; fi
    done
  '';

  gfx = pkgs.writeShellScriptBin "gfx" ''
    set -eu
    PATH=${lib.makeBinPath [ pkgs.supergfxctl pkgs.power-profiles-daemon pkgs.coreutils ]}:$PATH

    case "''${1:-status}" in
      perf|on|hybrid)
        supergfxctl --mode Hybrid
        powerprofilesctl set performance
        ;;
      battery|off|integrated)
        supergfxctl --mode Integrated
        powerprofilesctl set balanced
        ;;
      status)
        echo "graphics: $(supergfxctl --get)"
        echo "profile:  $(powerprofilesctl get)"
        # current_now reads 0 or reverses sign while charging, so this line is
        # only meaningful on battery.
        if [ -r /sys/class/power_supply/BAT1/current_now ]; then
          ${pkgs.gawk}/bin/awk \
            -v v="$(cat /sys/class/power_supply/BAT1/voltage_now)" \
            -v c="$(cat /sys/class/power_supply/BAT1/current_now)" \
            'BEGIN { printf "draw:     %.1f W\n", v / 1e6 * c / 1e6 }'
        fi
        ;;
      *)
        echo "usage: gfx [perf|battery|status]" >&2
        exit 2
        ;;
    esac

    # Dropping back to Integrated needs whoever holds the card to let go, which
    # in practice means niri; supergfxd reports that as a pending action rather
    # than failing, so surface it instead of leaving the switch silently queued.
    pend=$(supergfxctl --pend-action 2>/dev/null || true)
    [ -z "$pend" ] || [ "$pend" = "None" ] || echo "pending: $pend"
  '';
in
{
  # Driven by ac-power-profile below; nothing else on a niri session sets it.
  services.power-profiles-daemon.enable = true;

  # services.supergfxd.settings is deliberately unset: the daemon rewrites
  # /etc/supergfxd.conf whenever the mode changes, and the NixOS option would
  # symlink that path into the store read-only. supergfxd-boot-integrated
  # patches the file in place instead.
  services.supergfxd.enable = true;

  # The mode has to be right *before* supergfxd starts, not after. Asking the
  # running daemon to switch is what the first version did, and it fails: with
  # no mode configured supergfxd starts in Hybrid, modprobes the nvidia stack
  # and hands card1 to niri, so the switch to Integrated then needs a logout and
  # times out. Pinning the config first means the daemon comes up integrated
  # having never loaded the driver at all.
  #
  # Only mode and hotplug_type are rewritten, so anything else the daemon
  # persists survives; the fallback is only for a machine that has never run it.
  systemd.services.supergfxd-boot-integrated = {
    description = "Pin supergfxd to Integrated before it starts";
    before = [ "supergfxd.service" ];
    wantedBy = [ "supergfxd.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      conf=/etc/supergfxd.conf
      if [ -s "$conf" ]; then
        ${pkgs.jq}/bin/jq '.mode = "Integrated" | .hotplug_type = "Asus"' "$conf" > "$conf.new"
        mv "$conf.new" "$conf"
      else
        cat > "$conf" <<'JSON'
      {
        "mode": "Integrated",
        "vfio_enable": false,
        "vfio_save": false,
        "always_reboot": false,
        "no_logind": false,
        "logout_timeout_s": 180,
        "hotplug_type": "Asus"
      }
      JSON
      fi
    '';
  };

  # hotplug_type Asus routes the power cut through the dgpu_disable WMI rather
  # than a bare PCI remove, which is what actually takes the card off the rail.
  # supergfxd checks for the driver at startup and only waits two seconds for
  # it, so make sure it is there by then.
  boot.kernelModules = [ "asus_nb_wmi" ];

  # Deliberately not ordered after power-profiles-daemon: that closes a cycle
  # through multi-user.target and systemd resolves it by dropping this job from
  # the boot transaction altogether, which is how the first version silently
  # never ran. Nothing is lost by omitting it, because powerprofilesctl talks to
  # a D-Bus activatable service and will start the daemon on demand.
  systemd.services.ac-power-profile = {
    description = "Follow the AC adapter with a power-profiles-daemon profile";
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    # balanced rather than power-saver on battery: power-saver measured only
    # 0.6 W better and gives up noticeably more responsiveness for it.
    script = ''
      ${onAc}
      if [ "$on" = 1 ]; then
        ${pkgs.power-profiles-daemon}/bin/powerprofilesctl set performance
      else
        ${pkgs.power-profiles-daemon}/bin/powerprofilesctl set balanced
      fi
    '';
  };

  # dynamicBoost only means anything in Hybrid, but the nvidia module wants
  # nvidia-powerd at multi-user.target, so in Integrated mode it starts with no
  # GPU to talk to, fails with "Allocate Root client failed", and takes the exit
  # status of the whole nixos-rebuild with it. supergfxd starts and stops the
  # daemon along with the mode, so the boot-time want is redundant; the
  # condition makes it skip rather than fail if anything else asks for it while
  # the card is off the bus.
  systemd.services.nvidia-powerd = {
    wantedBy = lib.mkForce [ ];
    unitConfig.ConditionPathExists = "/sys/bus/pci/devices/0000:01:00.0";
  };

  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", ATTR{online}=="?*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="ac-power-profile.service"
  '';

  # The root ports and the NVMe link sit in L0 by default, which costs a little
  # over a watt at idle. Revert this first if the machine starts misbehaving
  # after resume — ASPM is the usual suspect for that class of fault.
  boot.kernelParams = [ "pcie_aspm.policy=powersave" ];

  environment.systemPackages = [ gfx ];
}
