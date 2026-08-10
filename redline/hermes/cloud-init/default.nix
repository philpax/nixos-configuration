{ pkgs, lib, net, adminKeys }:

# cloud-init NoCloud seed for the Hermes VM. Read once, on first boot, so
# changes here apply only to the next VM built. Everything above the base
# system is Ansible's, which can converge an existing VM.

let
  userData = pkgs.writeText "user-data" ''
    #cloud-config
    hostname: ${net.name}
    fqdn: ${net.name}.local
    preserve_hostname: false

    # The agent runs as root. The libvirt VM boundary and the host egress
    # firewall are the sandbox; a named user would add no capability limit.
    # Root login is key-only (redline's key).
    users:
      - name: root
        lock_passwd: true
        ssh_authorized_keys:
    ${lib.concatMapStrings (k: "          - ${k}\n") adminKeys}
    ssh_pwauth: false
    disable_root: false

    packages:
      - qemu-guest-agent
      - python3
      - python3-apt
    package_update: true

    # vdb is the state disk. Formatted once; every later OS-disk rebuild
    # reattaches it unchanged.
    disk_setup:
      /dev/vdb:
        table_type: gpt
        layout: true
        overwrite: false

    fs_setup:
      - device: /dev/vdb
        partition: 1
        filesystem: ext4
        label: hermes-state
        overwrite: false

    # The virtiofs drop is mounted by Ansible: cc_mounts discards any device that
    # is neither a block device nor a host:/export spec.
    mounts:
      - [/dev/vdb1, /srv/hermes, ext4, "defaults,noatime,nofail", "0", "2"]

    runcmd:
      - [systemctl, enable, --now, qemu-guest-agent]
      - [mkdir, -p, /srv/hermes, /srv/drop]

    final_message: "hermes VM up after $UPTIME seconds. Run the ansible playbook next."
  '';

  metaData = pkgs.writeText "meta-data" ''
    instance-id: ${net.name}-01
    local-hostname: ${net.name}
  '';

  # Matched by MAC so that it survives interface renaming.
  networkConfig = pkgs.writeText "network-config" ''
    version: 2
    ethernets:
      primary:
        match:
          macaddress: "${net.guestMac}"
        set-name: eth0
        addresses:
          - ${net.guestAddr}/${toString net.prefixLength}
        routes:
          - to: default
            via: ${net.hostAddr}
        nameservers:
          addresses: [${net.resolver}]
  '';
in
{
  seedIso = pkgs.runCommand "hermes-seed.iso"
    {
      nativeBuildInputs = [ pkgs.cdrkit ];
    } ''
    mkdir -p seed
    cp ${userData} seed/user-data
    cp ${metaData} seed/meta-data
    cp ${networkConfig} seed/network-config

    # NoCloud requires the CIDATA label.
    genisoimage -output $out -volid CIDATA -joliet -rock \
      seed/user-data seed/meta-data seed/network-config
  '';
}
