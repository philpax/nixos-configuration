# libvirt domain for the Hermes VM, generated from ./net.nix.
# A oneshot unit in ./default.nix runs `virsh define` on every rebuild; a
# running domain keeps its current definition until next boot.
{ folders, net }:

let
  paths = {
    os = "${folders.hermes.images}/os.qcow2";
    state = "${folders.hermes.images}/state.qcow2";
    seed = "${folders.hermes.images}/seed.iso";
    drop = folders.hermes.drop;
  };
in
''
<domain type='kvm'>
  <name>${net.name}</name>
  <!-- Fixed UUID makes `virsh define` idempotent. -->
  <uuid>${net.uuid}</uuid>
  <memory unit='MiB'>${toString net.memoryMiB}</memory>
  <currentMemory unit='MiB'>${toString net.memoryMiB}</currentMemory>
  <vcpu placement='static'>${toString net.vcpu}</vcpu>

  <!-- virtiofs requires shareable guest memory. -->
  <memoryBacking>
    <source type='memfd'/>
    <access mode='shared'/>
  </memoryBacking>

  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>

  <features>
    <acpi/>
    <apic/>
  </features>

  <cpu mode='host-passthrough' check='none' migratable='off'/>

  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>

  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>

  <devices>
    <emulator>/run/libvirt/nix-emulators/qemu-system-x86_64</emulator>

    <!-- vda: OS disk. Disposable; reproducible from cloud-init and Ansible. -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap'/>
      <source file='${paths.os}'/>
      <target dev='vda' bus='virtio'/>
    </disk>

    <!-- vdb: state disk, /srv/hermes in the guest. HERMES_HOME and pgdata. -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap'/>
      <source file='${paths.state}'/>
      <target dev='vdb' bus='virtio'/>
    </disk>

    <!-- cloud-init NoCloud seed. Read once, on first boot. -->
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${paths.seed}'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>

    <!-- Backup drop. Only completed pg_dump output and tarballs cross this
         boundary; live state stays on vdb. -->
    <filesystem type='mount' accessmode='passthrough'>
      <driver type='virtiofs'/>
      <source dir='${paths.drop}'/>
      <target dir='hermes-drop'/>
    </filesystem>

    <interface type='bridge'>
      <source bridge='${net.bridge}'/>
      <mac address='${net.guestMac}'/>
      <model type='virtio'/>
    </interface>

    <!-- Serial console, for when the network is broken. -->
    <serial type='pty'>
      <target type='isa-serial' port='0'><model name='isa-serial'/></target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>

    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>

    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>

    <memballoon model='virtio'/>
  </devices>
</domain>
''
