{ config, lib, pkgs, ... }:

let
  grafanaPort = 3010;
  prometheusPort = 9090;
  metricsPort = config.ai.ananke.managementPort;
  anankeDashboard = import ./grafana/ananke.nix { inherit lib pkgs; };
  systemDashboard = import ./grafana/system.nix { inherit lib pkgs; };
in
{
  # Prometheus scrapes ananke's /metrics endpoint and the host/GPU/ZFS
  # exporters. All bound to loopback — only Grafana (on the same host)
  # needs to reach Prometheus.
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
      {
        job_name = "node";
        static_configs = [
          { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ]; }
        ];
      }
      {
        job_name = "nvidia-gpu";
        static_configs = [
          { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.nvidia-gpu.port}" ]; }
        ];
      }
      {
        job_name = "zfs";
        static_configs = [
          { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.zfs.port}" ]; }
        ];
      }
    ];
  };

  # Host-level metrics: CPU, RAM, disk, network, filesystems.
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    enabledCollectors = [ "filesystem" "systemd" ];
  };

  # NVIDIA GPU metrics via nvidia-smi: utilization, temperature, power,
  # memory, fan speed. PrivateDevices = false is set by the NixOS module
  # to allow nvidia-smi access.
  services.prometheus.exporters.nvidia-gpu = {
    enable = true;
    listenAddress = "127.0.0.1";
  };

  # ZFS pool health and space metrics for the "storage" pool.
  services.prometheus.exporters.zfs = {
    enable = true;
    listenAddress = "127.0.0.1";
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
          name = "Redline";
          disableDeletion = false;
          options = {
            path = "/etc/grafana-dashboards";
            foldersFromFilesStructure = true;
          };
        }
      ];
    };
  };

  environment.etc."grafana-dashboards/ananke.json".source = anankeDashboard;
  environment.etc."grafana-dashboards/system.json".source = systemDashboard;

  networking.firewall.allowedTCPPorts = [ grafanaPort ];
}
