{ config, lib, pkgs, ... }:

let
  grafanaPort = 3010;
  prometheusPort = 9090;
  metricsPort = config.ai.ananke.managementPort;
  dashboardFile = import ./grafana/ananke.nix { inherit lib pkgs; };
in
{
  # Prometheus scrapes ananke's /metrics endpoint.
  # Bound to loopback only — only Grafana (on the same host) needs it.
  services.prometheus = {
    enable = true;
    port = prometheusPort;
    listenAddress = "127.0.0.1";
    scrapeConfigs = [
      {
        job_name = "ananke";
        metrics_path = "/metrics";
        static_configs = [
          { targets = [ "redline:${toString metricsPort}" ]; }
        ];
      }
    ];
  };

  # Grafana dashboard. Bound to 0.0.0.0 so anything that can reach
  # the server can access it. Default credentials: admin / admin
  # (change on first login).
  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = grafanaPort;
        enable_gzip = true;
      };
      # NixOS 26.05 removed the default secret_key; we supply the old
      # upstream default here since this Grafana instance has no secrets
      # in its DB that need protection.
      security.secret_key = "SW2YcwTIb9zpOOhoPsMm";
      analytics.reporting_enabled = false;
    };
    provision = {
      enable = true;
      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          uid = "prometheus";
          url = "http://127.0.0.1:${toString prometheusPort}";
          isDefault = true;
          editable = false;
        }
      ];
      dashboards.settings.providers = [
        {
          name = "Ananke";
          disableDeletion = false;
          options = {
            path = "/etc/grafana-dashboards";
            foldersFromFilesStructure = true;
          };
        }
      ];
    };
  };

  environment.etc."grafana-dashboards/ananke.json".source = dashboardFile;

  networking.firewall.allowedTCPPorts = [ grafanaPort ];
}
