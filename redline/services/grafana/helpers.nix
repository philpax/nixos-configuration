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
  # `softMax` sets a preferred y-axis ceiling (expands if data exceeds it);
  # use it to bound "used" series to their total capacity.
  tsPanel = { id, title, gridPos, unit ? "none", targets, fillOpacity ? 10, stackingMode ? "none", overrides ? [], mappings ? [], softMax ? null }: {
    datasource = ds;
    fieldConfig = {
      defaults = lib.recursiveUpdate (lineField unit) (
        lib.recursiveUpdate {
          custom.fillOpacity = fillOpacity;
          custom.stacking.mode = stackingMode;
          inherit mappings;
        }
        (lib.optionalAttrs (softMax != null) { max = softMax; })
      );
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

  # Build a state-timeline panel from time series data. `states` is a list
  # of { value, color, text } describing each numeric state (must be sorted
  # ascending by value, contiguous from 0). Both the value→text mappings
  # (for labels/tooltips) and the threshold steps (which actually drive the
  # band colors in a state-timeline) are derived from it, so the two can't
  # drift out of sync. Colors come from thresholds, not mappings — a
  # state-timeline colors each segment by which threshold band its value
  # falls into, and value-mapping colors alone are not enough.
  stateTimelinePanel = { id, title, gridPos, targets, states }: {
    datasource = ds;
    fieldConfig = {
      defaults = {
        color.mode = "thresholds";
        custom = {
          fillOpacity = 70;
          lineWidth = 0;
        };
        mappings = [{
          type = "value";
          options = builtins.listToAttrs (map (s: {
            name = toString s.value;
            value = { inherit (s) color text; index = s.value; };
          }) states);
        }];
        # First step is the -Infinity base (value = null); the rest sit at
        # each integer state so value N lands squarely in state N's band.
        thresholds = {
          mode = "absolute";
          steps = map (s: {
            inherit (s) color;
            value = if s.value == 0 then null else s.value;
          }) states;
        };
        unit = "none";
      };
      overrides = [];
    };
    gridPos = gridPos;
    id = id;
    options = {
      mergeValues = true;
      rowHeight = 0.9;
      showValue = "never";
      tooltip = { mode = "single"; sort = "none"; };
    };
    targets = targets;
    title = title;
    type = "state-timeline";
  };
in
{
  inherit ds mkTarget lineField tsPanel totalUsedFreeOverrides stateTimelinePanel;
}
