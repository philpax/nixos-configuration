{ config, lib, pkgs, ... }:

# Host side of the sandboxed Hermes Agent and its Honcho memory backend. See
# ./README.md for the enrolment and recovery procedures.
#
# The guest side is imperative and lives in ./cloud-init and ./ansible.

let
  folders = import ../folders.nix;
  net = import ./net.nix;

  ananke = config.ai.ananke;
  anankeBaseUrl = "http://${net.hostAddr}:${toString ananke.openaiPort}/v1";

  # Loaded by ansible/hermes.yml via vars_files, so the playbook does not repeat
  # values Nix already holds. Only the keys the playbook consumes are emitted;
  # host_addr/guest_addr are dead (the bridge addresses come from net.nix and
  # the inventory) and are deliberately not included.
  ansibleVars = pkgs.writeText "hermes-ansible-vars.yml" (builtins.toJSON {
    ananke_base_url = anankeBaseUrl;
    deriver_model = ananke.defaultModel;
    dashboard_port = net.dashboardPort;
    honcho_port = net.honchoPort;
  });

  # The ansible inventory is derived from net.nix so the guest address and
  # SSH user have a single source of truth. The host writes it to
  # /etc/hermes/inventory.ini; there is no inventory in git.
  hermesInventory = pkgs.writeText "inventory.ini" ''
    ; Generated from net.nix. Do not edit; the canonical source is
    ; redline/hermes/net.nix (guestAddr) and redline/hermes/ansible/hermes.yml.
    [hermes]
    ${net.guestAddr}

    [hermes:vars]
    ansible_user=root
    ansible_python_interpreter=/usr/bin/python3
  '';

  # The floating `release/` symlink is rebuilt for point releases, which would
  # break the hash at an arbitrary time rather than at a chosen one.
  ubuntuImage = pkgs.fetchurl {
    url = "https://cloud-images.ubuntu.com/releases/24.04/release-20260801/ubuntu-24.04-server-cloudimg-amd64.img";
    sha256 = "0533b0655c32e68b31d792ecd6ccfca95abdbc536c4446874fe0513bd4140ffe";
  };

  adminKeys = config.users.users.philpax.openssh.authorizedKeys.keys;

  cloudInit = import ./cloud-init { inherit pkgs lib net adminKeys; };

  domainXml = pkgs.writeText "hermes-domain.xml"
    (import ./domain.nix { inherit folders net; });

  osDisk = "${folders.hermes.images}/os.qcow2";
  stateDisk = "${folders.hermes.images}/state.qcow2";
  seedIso = "${folders.hermes.images}/seed.iso";

  freshnessCheck = pkgs.writeShellScript "hermes-backup-freshness" ''
    set -euo pipefail
    drop=${folders.hermes.drop}

    virsh="${pkgs.libvirt}/bin/virsh -c qemu:///system"
    state="$($virsh domstate ${net.name} 2>/dev/null || true)"
    autostart="$($virsh dominfo ${net.name} 2>/dev/null \
      | ${pkgs.gnugrep}/bin/grep -i '^Autostart:' | ${pkgs.gawk}/bin/awk '{print $2}' || true)"

    # The agent has root in the guest and can stop the VM, which would otherwise
    # silence this check. Autostart distinguishes a deliberate shutdown from one.
    if [ "$state" != "running" ]; then
      if [ "$autostart" = "enable" ]; then
        echo "VM ${net.name} has autostart enabled but is not running (state: ''${state:-undefined})" >&2
        exit 1
      fi
      echo "VM ${net.name} is not running and autostart is off (state: ''${state:-undefined}); nothing to check"
      exit 0
    fi

    if [ ! -d "$drop" ]; then
      echo "drop directory $drop does not exist" >&2
      exit 1
    fi

    # Both artefact types must be present and non-empty: a working tar with a
    # broken pg_dump is still a broken backup.
    fresh() {
      ${pkgs.findutils}/bin/find "$drop" -type f -name "$1" -mmin -180 -size +1c \
        | ${pkgs.gnugrep}/bin/grep -q .
    }

    if ! fresh '*.dump'; then
      echo "no Honcho database dump written to $drop in the last 3 hours" >&2
      ${pkgs.coreutils}/bin/ls -la "$drop" >&2 || true
      exit 1
    fi

    if ! fresh '*.tar.zst'; then
      echo "no HERMES_HOME archive written to $drop in the last 3 hours" >&2
      ${pkgs.coreutils}/bin/ls -la "$drop" >&2 || true
      exit 1
    fi

    echo "backup drop is fresh"
  '';
in
# Gated for the reason ../services/audiomuse.nix documents: unconditional
# tmpfiles rules recreate these directories on the root filesystem under an
# unmounted mountpoint.
lib.mkIf config.redline.ssd0.enable {
  # ── Storage ───────────────────────────────────────────────────────────────

  environment.etc."hermes/ansible-vars.yml".source = ansibleVars;
  environment.etc."hermes/inventory.ini".source = hermesInventory;

  systemd.services.hermes-vm-provision = {
    description = "Create the Hermes VM disks and define the libvirt domain";
    wantedBy = [ "multi-user.target" ];
    after = [ "libvirtd.service" ];
    requires = [ "libvirtd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # /mnt/ssd0 is mounted nofail, so `after` on the mount unit is vacuous when
    # the device does not probe.
    unitConfig.RequiresMountsFor = folders.mounts.ssd0;
    path = [ pkgs.qemu_kvm pkgs.libvirt pkgs.coreutils pkgs.e2fsprogs ];
    script = ''
      set -euo pipefail

      # Created here rather than through systemd.tmpfiles: at switch time this
      # unit can start before activation's tmpfiles pass has run. +C must also
      # be set before any file exists inside images/, which ordering alone does
      # not guarantee.
      install -d -m 0700 ${folders.hermes.base}
      install -d -m 0700 ${folders.hermes.images}
      install -d -m 0755 ${folders.hermes.drop}

      # +C disables btrfs checksums as well as copy-on-write, which is why the
      # drop directory is a sibling of images/ rather than a child.
      chattr +C ${folders.hermes.images} 2>/dev/null || true

      # Deleting os.qcow2 by hand and re-running this unit rebuilds the guest
      # environment. Deleting state.qcow2 discards the agent's memory.
      if [ ! -e ${osDisk} ]; then
        echo "creating OS disk from ${ubuntuImage}"
        install -m 0600 ${ubuntuImage} ${osDisk}
        qemu-img resize ${osDisk} ${toString net.osDiskGiB}G
      fi

      if [ ! -e ${stateDisk} ]; then
        echo "creating state disk"
        qemu-img create -f qcow2 ${stateDisk} ${toString net.stateDiskGiB}G
        chmod 0600 ${stateDisk}
      fi

      install -m 0400 ${cloudInit.seedIso} ${seedIso}

      # Idempotent because domain.nix carries a fixed UUID. A running domain
      # keeps its current definition until next boot.
      virsh define ${domainXml}
      virsh autostart ${net.name}
    '';
  };

  # ── Networking ────────────────────────────────────────────────────────────

  networking.bridges.${net.bridge}.interfaces = [ ];
  networking.interfaces.${net.bridge}.ipv4.addresses = [{
    address = net.hostAddr;
    prefixLength = net.prefixLength;
  }];

  networking.nat = {
    enable = true;
    internalInterfaces = [ net.bridge ];
    externalInterface = net.uplink;
  };

  # The host stays on the iptables backend: Docker manages its own rules here
  # and the nftables backend breaks them.
  networking.firewall.extraCommands = ''
    # networking.firewall.allowedTCPPorts renders as nixos-fw accepts with no
    # interface predicate, emitted before extraCommands. Guest-to-host traffic
    # is INPUT, so an appended rule cannot subtract from them; these are
    # inserted above them instead. Repeated insertion at 1 reverses the order,
    # so they are written back to front and end up: established, ananke, drop.
    #
    # The established accept cannot be left to the firewall's own global rule,
    # which sits below position 1.
    iptables -D nixos-fw -i ${net.bridge} -j DROP 2>/dev/null || true
    iptables -D nixos-fw -i ${net.bridge} -p tcp --dport ${toString ananke.openaiPort} -j nixos-fw-accept 2>/dev/null || true
    iptables -D nixos-fw -i ${net.bridge} -m conntrack --ctstate ESTABLISHED,RELATED -j nixos-fw-accept 2>/dev/null || true

    iptables -I nixos-fw 1 -i ${net.bridge} -j DROP
    iptables -I nixos-fw 1 -i ${net.bridge} -p tcp --dport ${toString ananke.openaiPort} -j nixos-fw-accept
    iptables -I nixos-fw 1 -i ${net.bridge} -m conntrack --ctstate ESTABLISHED,RELATED -j nixos-fw-accept

    iptables -N HERMES-FWD 2>/dev/null || iptables -F HERMES-FWD
    iptables -A HERMES-FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    iptables -A HERMES-FWD -i ${net.tailscaleIface} -o ${net.bridge} \
      -d ${net.guestAddr} -p tcp --dport ${toString net.dashboardPort} -j ACCEPT

    iptables -A HERMES-FWD -i ${net.bridge} -d 10.0.0.0/8 -j DROP
    iptables -A HERMES-FWD -i ${net.bridge} -d 172.16.0.0/12 -j DROP
    iptables -A HERMES-FWD -i ${net.bridge} -d 192.168.0.0/16 -j DROP
    iptables -A HERMES-FWD -i ${net.bridge} -d 169.254.0.0/16 -j DROP
    # tailscale's CGNAT range.
    iptables -A HERMES-FWD -i ${net.bridge} -d 100.64.0.0/10 -j DROP
    iptables -A HERMES-FWD -i ${net.bridge} -j ACCEPT
    iptables -A HERMES-FWD -j DROP

    # tailscaled and dockerd both insert at FORWARD position 1 when they restart
    # or reconcile, and ts-forward ends with `-o tailscale0 -j ACCEPT`. A -C
    # guard would find a displaced rule and leave it displaced, so these are
    # deleted and reinserted. A restart of either daemon after this point still
    # displaces them; see README.md.
    iptables -D FORWARD -i ${net.bridge} -j HERMES-FWD 2>/dev/null || true
    iptables -D FORWARD -o ${net.bridge} -j HERMES-FWD 2>/dev/null || true
    iptables -I FORWARD 1 -i ${net.bridge} -j HERMES-FWD
    iptables -I FORWARD 2 -o ${net.bridge} -j HERMES-FWD

    iptables -t nat -C PREROUTING -i ${net.tailscaleIface} -p tcp \
      --dport ${toString net.dashboardPort} -j DNAT \
      --to-destination ${net.guestAddr}:${toString net.dashboardPort} 2>/dev/null \
      || iptables -t nat -A PREROUTING -i ${net.tailscaleIface} -p tcp \
        --dport ${toString net.dashboardPort} -j DNAT \
        --to-destination ${net.guestAddr}:${toString net.dashboardPort}
  '';

  networking.firewall.extraStopCommands = ''
    iptables -D nixos-fw -i ${net.bridge} -m conntrack --ctstate ESTABLISHED,RELATED -j nixos-fw-accept 2>/dev/null || true
    iptables -D nixos-fw -i ${net.bridge} -p tcp --dport ${toString ananke.openaiPort} -j nixos-fw-accept 2>/dev/null || true
    iptables -D nixos-fw -i ${net.bridge} -j DROP 2>/dev/null || true
    iptables -t nat -D PREROUTING -i ${net.tailscaleIface} -p tcp \
      --dport ${toString net.dashboardPort} -j DNAT \
      --to-destination ${net.guestAddr}:${toString net.dashboardPort} 2>/dev/null || true
    iptables -D FORWARD -i ${net.bridge} -j HERMES-FWD 2>/dev/null || true
    iptables -D FORWARD -o ${net.bridge} -j HERMES-FWD 2>/dev/null || true
    iptables -F HERMES-FWD 2>/dev/null || true
    iptables -X HERMES-FWD 2>/dev/null || true
  '';

  # ── Backup freshness ──────────────────────────────────────────────────────

  systemd.services.hermes-backup-check = {
    description = "Check that the Hermes VM is still writing backups";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${freshnessCheck}";
    };
  };

  systemd.timers.hermes-backup-check = {
    description = "Hourly Hermes backup freshness check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      RandomizedDelaySec = "10m";
      Persistent = true;
    };
  };

  # libvirt resolves virtiofsd through /var/lib/qemu/vhost-user, populated from
  # this option. It defaults to empty, and domain.nix declares a virtiofs mount.
  virtualisation.libvirtd.qemu.vhostUserPackages = [ pkgs.virtiofsd ];

  environment.systemPackages = [ pkgs.ansible pkgs.libvirt ];
}
