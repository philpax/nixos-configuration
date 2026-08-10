# Network and sizing constants for the Hermes VM. Read by default.nix,
# domain.nix and the cloud-init seed.
#
# ananke's ports are not here: ../ai/ananke.nix owns them and exposes them as
# read-only options under `config.ai.ananke`.
rec {
  name = "hermes";

  # Fixed, so that `virsh define` is idempotent.
  uuid = "29074038-4a2d-4d0e-a6e9-500d003d31be";

  bridge = "br-hermes";

  # Avoids docker0 (172.17/16), the compose bridge (172.18/16), the LAN
  # (192.168.50/24) and tailscale (100.64/10).
  hostAddr = "10.100.0.1";
  guestAddr = "10.100.0.2";
  subnet = "10.100.0.0/24";
  prefixLength = 24;

  # Locally administered (02: prefix). cloud-init matches the interface on it.
  guestMac = "02:00:00:5e:77:a1";

  uplink = "enp67s0f0";

  tailscaleIface = "tailscale0";

  # External resolver: the host's would require opening a host service to
  # the guest.
  resolver = "1.1.1.1";

  dashboardPort = 9119;

  # Guest-internal. Honcho's Postgres and Redis publish no ports at all.
  honchoPort = 8000;

  vcpu = 6;
  memoryMiB = 6144;
  osDiskGiB = 20;
  stateDiskGiB = 20;
}
