{ pkgs, ... }:
let
  # node-exporter reads *.prom out of this directory via its textfile
  # collector. Contributed here rather than in grafana.nix so that deleting
  # this one file removes the whole feature cleanly (services/ auto-imports).
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  # liquidctl reports a flat list of {key, value, unit} per device. Map that
  # onto Prometheus names generically — derive the suffix from the unit and
  # split "Fan N <what>" into a fan="N" label — so this keeps working if the
  # cooler is swapped for another liquidctl-supported device.
  toProm = pkgs.writeText "liquidctl-to-prom.jq" ''
    def sanitize: ascii_downcase | gsub("[^a-z0-9]+"; "_") | sub("^_"; "") | sub("_$"; "");
    def unitsuffix: if . == "rpm" then "_rpm"
                    elif . == "%" then "_percent"
                    elif . == "°C" then "_celsius"
                    else "" end;

    [ .[]
      | .description as $dev
      | .status[]
      | select(.value != null and (.value | type) == "number")
      | if (.key | test("^Fan [0-9]+ ")) then
          (.key | capture("^Fan (?<n>[0-9]+) (?<what>.+)$")) as $c
          | { metric: ("liquidctl_fan_" + ($c.what | sanitize) + (.unit | unitsuffix)),
              labels: { device: $dev, fan: $c.n },
              value: .value }
        else
          { metric: ("liquidctl_" + (.key | sanitize) + (.unit | unitsuffix)),
            labels: { device: $dev },
            value: .value }
        end
    ] as $samples
    | ( [ $samples[].metric ] | unique | map("# TYPE " + . + " gauge") | .[] ),
      ( $samples[]
        | .metric
          + "{" + ([ .labels | to_entries[] | .key + "=\"" + .value + "\"" ] | join(",")) + "} "
          + (.value | tostring) )
  '';

  collector = pkgs.writeShellScript "h150i-metrics" ''
    set -eu
    out="${textfileDir}/h150i.prom"
    tmp="$out.$$"

    # A failed poll leaves the previous file in place rather than truncating
    # it, so a transient USB hiccup doesn't show up as a gap that looks like
    # the cooler vanished.
    if ! status=$(timeout 15 ${pkgs.liquidctl}/bin/liquidctl --match H150i --json status 2>/dev/null); then
      echo "h150i-metrics: liquidctl status failed, keeping previous metrics" >&2
      exit 0
    fi

    printf '%s' "$status" | ${pkgs.jq}/bin/jq -r -f ${toProm} > "$tmp"
    # Atomic swap: node-exporter must never observe a half-written file.
    mv "$tmp" "$out"
  '';
in {
  config = {
    systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];

    services.prometheus.exporters.node = {
      enabledCollectors = [ "textfile" ];
      extraFlags = [ "--collector.textfile.directory=${textfileDir}" ];
    };

    systemd.services.h150i-metrics = {
      description = "Export Corsair H150i Pro XT metrics for node-exporter";
      serviceConfig = {
        ExecStart = collector;
        Type = "oneshot";
        TimeoutStartSec = "30s";
      };
    };

    systemd.timers.h150i-metrics = {
      description = "Poll Corsair H150i Pro XT metrics";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "30s";
        AccuracySec = "5s";
      };
    };
  };
}
