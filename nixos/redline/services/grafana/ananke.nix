# Generates the Ananke metrics dashboard as a JSON derivation.
# Called from grafana.nix: import ./grafana/ananke.nix { inherit lib pkgs; }
{ lib, pkgs }:
let
  h = import ./helpers.nix { inherit lib; };
  inherit (h) mkTarget tsPanel stateTimelinePanel;

  models = "gemma-4-31b-it-qat|lfm2.5-embedding-350m";

  # Service state as a state-timeline. last_over_time() carries the value
  # forward between scrapes so the band is continuous. Thresholds map
  # numeric states to colored regions.
  serviceStatePanel =
    stateTimelinePanel {
      id = 5;
      title = "Service State";
      gridPos = { h = 8; w = 24; x = 0; y = 8; };
      targets = [ (mkTarget "A" "last_over_time(ananke_service_state{service=~\"${models}\"}[5m])" "{{service}}") ];
      states = [
        { value = 0; color = "blue"; text = "Idle"; }
        { value = 1; color = "yellow"; text = "Starting"; }
        { value = 2; color = "green"; text = "Running"; }
        { value = 3; color = "orange"; text = "Draining"; }
        { value = 4; color = "purple"; text = "Stopped"; }
        { value = 5; color = "semi-dark-red"; text = "Evicted"; }
        { value = 6; color = "red"; text = "Failed"; }
        { value = 7; color = "dark-gray"; text = "Disabled"; }
        { value = 8; color = "light-gray"; text = "Unknown"; }
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
        gridPos = { h = 8; w = 12; x = 0; y = 16; };
        targets = [ (mkTarget "A" "rate(ananke_requests_total{service=~\"${models}\"}[5m])" "{{service}}") ];
      })
      (tsPanel {
        id = 4;
        title = "Inflight Requests";
        gridPos = { h = 8; w = 12; x = 12; y = 16; };
        unit = "short";
        targets = [ (mkTarget "A" "ananke_inflight_requests{service=~\"${models}\"}" "{{service}}") ];
      })
      serviceStatePanel
      (tsPanel {
        id = 6;
        title = "Cumulative Tokens (prompt + completion)";
        gridPos = { h = 8; w = 12; x = 0; y = 24; };
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
        gridPos = { h = 8; w = 12; x = 12; y = 24; };
        unit = "short";
        targets = [ (mkTarget "A" "ananke_requests_total{service=~\"${models}\"}" "{{service}}") ];
      })
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
