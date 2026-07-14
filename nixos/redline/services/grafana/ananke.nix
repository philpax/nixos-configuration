# Generates the Ananke metrics dashboard as a JSON derivation.
# Called from grafana.nix: import ./grafana/ananke.nix { inherit lib pkgs; }
{ lib, pkgs }:
let
  h = import ./helpers.nix { inherit lib; };
  inherit (h) mkTarget tsPanel totalUsedFreeOverrides;

  models = "gemma-4-31b-it-qat|lfm2.5-embedding-350m";

  # Ananke-specific memory panel: Total / Used / Free for a device.
  memPanel = id: title: gridPos: device:
    tsPanel {
      inherit id title gridPos;
      unit = "bytes";
      targets = [
        (mkTarget "A" "ananke_memory_bytes{device=\"${device}\"}" "Total")
        (mkTarget "B" "ananke_memory_used_bytes{device=\"${device}\"}" "Used")
        (mkTarget "C" "ananke_memory_free_bytes{device=\"${device}\"}" "Free")
      ];
      overrides = totalUsedFreeOverrides;
    };

  # Service state rendered as a stepped timeseries. last_over_time()
  # carries the value forward between scrapes so the line is continuous
  # rather than only showing points at scrape intervals. Value mappings
  # translate numeric states to text labels with distinct colors.
  serviceStatePanel =
    tsPanel {
      id = 5;
      title = "Service State";
      gridPos = { h = 8; w = 8; x = 16; y = 8; };
      targets = [ (mkTarget "A" "last_over_time(ananke_service_state{service=~\"${models}\"}[5m])" "{{service}}") ];
      mappings = [
        { options = { "0" = { color = "blue"; index = 0; text = "Idle"; }; }; type = "value"; }
        { options = { "1" = { color = "yellow"; index = 1; text = "Starting"; }; }; type = "value"; }
        { options = { "2" = { color = "green"; index = 2; text = "Running"; }; }; type = "value"; }
        { options = { "3" = { color = "orange"; index = 3; text = "Draining"; }; }; type = "value"; }
        { options = { "4" = { color = "purple"; index = 4; text = "Stopped"; }; }; type = "value"; }
        { options = { "5" = { color = "semi-dark-red"; index = 5; text = "Evicted"; }; }; type = "value"; }
        { options = { "6" = { color = "red"; index = 6; text = "Failed"; }; }; type = "value"; }
        { options = { "7" = { color = "dark-gray"; index = 7; text = "Disabled"; }; }; type = "value"; }
        { options = { "8" = { color = "light-gray"; index = 8; text = "Unknown"; }; }; type = "value"; }
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
      (tsPanel {
        id = 1;
        title = "Effective Throughput (tok/s)";
        gridPos = { h = 8; w = 12; x = 0; y = 0; };
        targets = [ (mkTarget "A" "ananke_effective_tokens_per_second{service=~\"${models}\"}" "{{service}}") ];
      })
      (tsPanel {
        id = 2;
        title = "Input / Output Token Rates (tok/s)";
        gridPos = { h = 8; w = 12; x = 12; y = 0; };
        targets = [
          (mkTarget "A" "ananke_input_tokens_per_second{service=~\"${models}\"}" "{{service}} - input")
          (mkTarget "B" "ananke_output_tokens_per_second{service=~\"${models}\"}" "{{service}} - output")
        ];
      })
      (tsPanel {
        id = 3;
        title = "Request Rate (req/s)";
        gridPos = { h = 8; w = 8; x = 0; y = 8; };
        targets = [ (mkTarget "A" "rate(ananke_requests_total{service=~\"${models}\"}[5m])" "{{service}}") ];
      })
      (tsPanel {
        id = 4;
        title = "Inflight Requests";
        gridPos = { h = 8; w = 8; x = 8; y = 8; };
        unit = "short";
        targets = [ (mkTarget "A" "ananke_inflight_requests{service=~\"${models}\"}" "{{service}}") ];
      })
      serviceStatePanel
      (tsPanel {
        id = 6;
        title = "Cumulative Tokens (prompt + completion)";
        gridPos = { h = 8; w = 12; x = 0; y = 16; };
        unit = "short";
        fillOpacity = 20;
        stackingMode = "normal";
        targets = [
          (mkTarget "A" "ananke_tokens_total{service=~\"${models}\",type=\"prompt\"}" "{{service}} - prompt")
          (mkTarget "B" "ananke_tokens_total{service=~\"${models}\",type=\"completion\"}" "{{service}} - completion")
        ];
      })
      (tsPanel {
        id = 7;
        title = "Total Requests";
        gridPos = { h = 8; w = 12; x = 12; y = 16; };
        unit = "short";
        targets = [ (mkTarget "A" "ananke_requests_total{service=~\"${models}\"}" "{{service}}") ];
      })
      (memPanel 8 "GPU 0 Memory (bytes / used / free)" { h = 8; w = 8; x = 0; y = 24; } "gpu:0")
      (memPanel 9 "GPU 1 Memory (bytes / used / free)" { h = 8; w = 8; x = 8; y = 24; } "gpu:1")
      (memPanel 10 "CPU Memory (bytes / used / free)" { h = 8; w = 8; x = 16; y = 24; } "cpu")
    ];
    refresh = "10s";
    schemaVersion = 39;
    style = "dark";
    tags = [ "ananke" "redline" ];
    templating = { list = []; };
    time = { from = "now-6h"; to = "now"; };
    timezone = "browser";
    title = "Ananke Metrics";
    uid = "ananke";
    version = 0;
    weekStart = "";
  };
in
(pkgs.formats.json { }).generate "ananke-dashboard.json" dashboard
