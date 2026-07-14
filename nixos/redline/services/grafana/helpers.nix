# Reusable Grafana panel builders. Takes { lib } and returns an
# attrset of helper functions for constructing dashboard panel JSON
# from Nix, avoiding hand-written JSON.
{ lib }:
let
  # Shared datasource reference. Matches the uid provisioned in grafana.nix.
  ds = { type = "prometheus"; uid = "prometheus"; };

  # Build a single Prometheus query target.
  mkTarget = refId: expr: legend: {
    datasource = ds;
    editorMode = "code";
    expr = expr;
    legendFormat = legend;
    range = true;
    refId = refId;
  };

  # Default field config for line charts. Callers can override
  # fillOpacity / stackingMode via tsPanel parameters, and pass custom
  # overrides for per-series coloring.
  lineField = unit: {
    color.mode = "palette-classic";
    custom = {
      drawStyle = "line";
      fillOpacity = 10;
      lineInterpolation = "linear";
      lineWidth = 2;
      pointSize = 5;
      showPoints = "never";
      spanNulls = false;
      stacking = { group = "A"; mode = "none"; };
    };
    mappings = [];
    thresholds = { mode = "absolute"; steps = [{ color = "green"; value = null; }]; };
    unit = unit;
  };

  # Build a timeseries panel. `mappings` adds value→text/color mappings
  # (used by the service-state panel); `overrides` sets per-series colors.
  tsPanel = { id, title, gridPos, unit ? "none", targets, fillOpacity ? 10, stackingMode ? "none", overrides ? [], mappings ? [] }: {
    datasource = ds;
    fieldConfig = {
      defaults = lib.recursiveUpdate (lineField unit) {
        custom.fillOpacity = fillOpacity;
        custom.stacking.mode = stackingMode;
        inherit mappings;
      };
      inherit overrides;
    };
    gridPos = gridPos;
    id = id;
    options = {
      legend = { calcs = [ "lastNotNull" ]; displayMode = "table"; placement = "bottom"; showLegend = true; };
      tooltip = { mode = "multi"; sort = "none"; };
    };
    targets = targets;
    title = title;
    type = "timeseries";
  };

  # Fixed Total=blue / Used=red / Free=green coloring for panels
  # that show total/used/free series.
  totalUsedFreeOverrides = [
    { matcher = { id = "byName"; options = "Total"; }; properties = [{ id = "color"; value = { mode = "fixed"; fixedColor = "blue"; }; }]; }
    { matcher = { id = "byName"; options = "Used"; }; properties = [{ id = "color"; value = { mode = "fixed"; fixedColor = "red"; }; }]; }
    { matcher = { id = "byName"; options = "Free"; }; properties = [{ id = "color"; value = { mode = "fixed"; fixedColor = "green"; }; }]; }
  ];
in
{
  inherit ds mkTarget lineField tsPanel totalUsedFreeOverrides;
}
