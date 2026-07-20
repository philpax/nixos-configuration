# Generates the system metrics dashboard as a JSON derivation.
# Called from grafana.nix: import ./grafana/system.nix { inherit lib pkgs; }
{ lib, pkgs }:
let
  h = import ./helpers.nix { inherit lib; };
  inherit (h) mkTarget tsPanel;

  ramBytes = 256 * 1024 * 1024 * 1024;
  gpuMemBytes = 24 * 1024 * 1024 * 1024;
  ssd0Bytes = 4000785104896;
  storageBytes = 46354617335808;
  diskMaxBytes = lib.max ssd0Bytes storageBytes;

  cpuPanel =
    tsPanel {
      id = 1;
      title = "CPU Usage (%)";
      gridPos = { h = 8; w = 12; x = 0; y = 0; };
      unit = "percent";
      softMax = 100;
      targets = [
        (mkTarget "A" "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])))" "CPU busy")
      ];
    };

  memPanel =
    tsPanel {
      id = 2;
      title = "Memory Used";
      gridPos = { h = 8; w = 12; x = 12; y = 0; };
      unit = "bytes";
      softMax = ramBytes;
      targets = [
        (mkTarget "A" "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes" "Used")
      ];
      overrides = [
        { matcher = { id = "byName"; options = "Used"; }; properties = [{ id = "color"; value = { mode = "fixed"; fixedColor = "red"; }; }]; }
      ];
    };

  diskPanel =
    tsPanel {
      id = 3;
      title = "Disk Space Used";
      gridPos = { h = 8; w = 12; x = 0; y = 8; };
      unit = "bytes";
      softMax = diskMaxBytes;
      targets = [
        (mkTarget "A" "node_filesystem_size_bytes{mountpoint=\"/mnt/ssd0\"} - node_filesystem_free_bytes{mountpoint=\"/mnt/ssd0\"}" "/mnt/ssd0 - used")
        (mkTarget "B" "node_filesystem_size_bytes{mountpoint=\"/storage\"} - node_filesystem_free_bytes{mountpoint=\"/storage\"}" "/storage - used")
      ];
      overrides = [
        { matcher = { id = "byRegexp"; options = ".*used.*"; }; properties = [{ id = "color"; value = { mode = "fixed"; fixedColor = "red"; }; }]; }
      ];
    };

  netPanel =
    tsPanel {
      id = 4;
      title = "Network Throughput (bytes/s)";
      gridPos = { h = 8; w = 12; x = 12; y = 8; };
      unit = "Bps";
      targets = [
        (mkTarget "A" "rate(node_network_receive_bytes_total{device!~\"lo|docker.*|veth.*\"}[5m])" "{{device}} rx")
        (mkTarget "B" "rate(node_network_transmit_bytes_total{device!~\"lo|docker.*|veth.*\"}[5m])" "{{device}} tx")
      ];
    };

  gpuUtilPanel =
    tsPanel {
      id = 5;
      title = "GPU Utilization (%)";
      gridPos = { h = 8; w = 12; x = 0; y = 16; };
      unit = "percent";
      softMax = 100;
      targets = [ (mkTarget "A" "100 * nvidia_smi_utilization_gpu_ratio" "GPU {{uuid}}") ];
    };

  gpuTempPanel =
    tsPanel {
      id = 6;
      title = "GPU Temperature (°C)";
      gridPos = { h = 8; w = 12; x = 12; y = 16; };
      unit = "celsius";
      targets = [ (mkTarget "A" "nvidia_smi_temperature_gpu" "GPU {{uuid}}") ];
    };

  gpuPowerPanel =
    tsPanel {
      id = 7;
      title = "GPU Power Draw (W)";
      gridPos = { h = 8; w = 12; x = 0; y = 24; };
      unit = "watt";
      targets = [ (mkTarget "A" "nvidia_smi_power_draw_watts" "GPU {{uuid}}") ];
    };

  gpuMemPanel =
    tsPanel {
      id = 8;
      title = "GPU Memory Used";
      gridPos = { h = 8; w = 12; x = 12; y = 24; };
      unit = "bytes";
      softMax = gpuMemBytes;
      targets = [
        (mkTarget "A" "nvidia_smi_memory_used_bytes" "GPU {{uuid}} - used")
      ];
      overrides = [
        { matcher = { id = "byRegexp"; options = ".*used.*"; }; properties = [{ id = "color"; value = { mode = "fixed"; fixedColor = "red"; }; }]; }
      ];
    };

  zfsHealthPanel =
    tsPanel {
      id = 9;
      title = "ZFS Pool Health";
      gridPos = { h = 8; w = 12; x = 0; y = 32; };
      targets = [ (mkTarget "A" "zfs_pool_health" "pool {{pool}}") ];
      mappings = [
        { options = { "0" = { color = "green"; index = 0; text = "ONLINE"; }; }; type = "value"; }
        { options = { "1" = { color = "yellow"; index = 1; text = "DEGRADED"; }; }; type = "value"; }
        { options = { "2" = { color = "red"; index = 2; text = "FAULTED"; }; }; type = "value"; }
        { options = { "3" = { color = "orange"; index = 3; text = "OFFLINE"; }; }; type = "value"; }
        { options = { "4" = { color = "purple"; index = 4; text = "UNAVAIL"; }; }; type = "value"; }
        { options = { "5" = { color = "dark-gray"; index = 5; text = "REMOVED"; }; }; type = "value"; }
      ];
    };

  zfsSpacePanel =
    tsPanel {
      id = 10;
      title = "ZFS Pool Space Used";
      gridPos = { h = 8; w = 12; x = 12; y = 32; };
      unit = "bytes";
      softMax = storageBytes;
      targets = [
        (mkTarget "A" "zfs_pool_size_bytes - zfs_pool_free_bytes" "pool {{pool}} - used")
      ];
      overrides = [
        { matcher = { id = "byRegexp"; options = ".*used.*"; }; properties = [{ id = "color"; value = { mode = "fixed"; fixedColor = "red"; }; }]; }
      ];
    };

  # Corsair H150i Pro XT, via the liquidctl textfile collector in
  # services/h150i-metrics.nix. Fan 3 idles at 0 rpm under its zero-RPM
  # curve, so a flat zero there is expected rather than a dead fan.
  coolantTempPanel =
    tsPanel {
      id = 11;
      title = "Coolant Temperature (°C)";
      gridPos = { h = 8; w = 12; x = 0; y = 40; };
      unit = "celsius";
      targets = [ (mkTarget "A" "liquidctl_liquid_temperature_celsius" "coolant") ];
    };

  coolerRpmPanel =
    tsPanel {
      id = 12;
      title = "Pump & Fan Speed (rpm)";
      gridPos = { h = 8; w = 12; x = 12; y = 40; };
      unit = "rotrpm";
      targets = [
        (mkTarget "A" "liquidctl_pump_speed_rpm" "pump")
        (mkTarget "B" "liquidctl_fan_speed_rpm" "fan {{fan}}")
      ];
    };

  coolerDutyPanel =
    tsPanel {
      id = 13;
      title = "Pump & Fan Duty (%)";
      gridPos = { h = 8; w = 24; x = 0; y = 48; };
      unit = "percent";
      softMax = 100;
      targets = [
        (mkTarget "A" "liquidctl_pump_duty_percent" "pump")
        (mkTarget "B" "liquidctl_fan_duty_percent" "fan {{fan}}")
      ];
    };

  dashboard = {
    annotations = { list = []; };
    editable = true;
    fiscalYearStartMonth = 0;
    graphTooltip = 1;
    id = null;
    links = [];
    liveNow = false;
    panels = [
      cpuPanel
      memPanel
      diskPanel
      netPanel
      gpuUtilPanel
      gpuTempPanel
      gpuPowerPanel
      gpuMemPanel
      zfsHealthPanel
      zfsSpacePanel
      coolantTempPanel
      coolerRpmPanel
      coolerDutyPanel
    ];
    refresh = "10s";
    schemaVersion = 39;
    style = "dark";
    tags = [ "system" "redline" ];
    templating = { list = []; };
    time = { from = "now-6h"; to = "now"; };
    timezone = "browser";
    title = "System Overview";
    uid = "system";
    version = 0;
    weekStart = "";
  };
in
(pkgs.formats.json { }).generate "system-dashboard.json" dashboard
