# Sandboxed Hermes Agent

A [Hermes Agent](https://github.com/NousResearch/hermes-agent) instance with a self-hosted [Honcho](https://github.com/plastic-labs/honcho) memory backend. Both run in an Ubuntu VM under libvirt. The agent uses ananke for inference and Discord for input.

```
redline ─ ananke (OpenAI port) ─┐  inference + embeddings
        ─ br-hermes 10.100.0.1  │  host-only, NAT out, LAN dropped
        ─ tailscale0 ─DNAT:9119─┤  dashboard, tailnet only
        ─ /mnt/ssd0/hermes/     │
            images/       os.qcow2, state.qcow2, seed.iso
            drop/         ◄─ virtiofs ─┐
                                       │
   hermes VM (Ubuntu 24.04, 10.100.0.2, 6 vCPU / 6 GB)
     hermes-agent ── dashboard :9119
          └─► honcho api :8000 ─ deriver ─ postgres/pgvector ─ redis
```

## Layout

| Path | Contents |
|---|---|
| `default.nix` | Host: bridge, NAT, egress policy, DNAT, disks, domain, backup check |
| `net.nix` | Constants shared by the host module, domain and cloud-init |
| `domain.nix` | libvirt domain XML |
| `cloud-init/` | First-boot seed: user, key, static IP, disk format, mounts |
| `ansible/` | Everything above the OS. Run from redline over SSH |

## Division between declarative and imperative configuration

The host side is declarative and lives in this directory. The guest side is imperative and lives in `ansible/`. Enrolment happens through Hermes' own wizards and dashboard, so a declaratively built guest would describe only the layer that does not vary, while the state that matters stays imperative.

Two mechanisms recover most of the reproducibility this costs. The Ansible playbook is re-runnable and converges an existing VM. The hourly backup captures `config.yaml`, and therefore captures the enrolment.

## Bring-up

`/dev/kvm` must exist, which requires SVM enabled in the UEFI setup.

```bash
sudo nixos-rebuild switch          # creates disks, defines the domain
virsh start hermes
virsh console hermes               # watch cloud-init; ctrl-] to exit
ssh philpax@10.100.0.2             # once it is up

cd nixos/redline/hermes/ansible
ansible-playbook -i inventory.ini hermes.yml
```

The playbook installs Hermes with upstream's own installer, `scripts/install.sh`, run from the pinned checkout rather than curled from the website. Two of its flags are load-bearing. `--dir` and `--hermes-home` both default under `~`, which is on the OS disk, and this design treats that disk as disposable; without them the agent's configuration and memory are destroyed by the OS-disk rebuild procedure below. `--skip-setup` suppresses the enrolment wizard, which otherwise blocks the run on a `read` indefinitely.

Node is installed from NodeSource because Ubuntu 24.04 ships 18.19 and the dashboard's frontend needs 20 or newer. The dashboard builds that frontend itself on first start, provided npm is on the path; nothing in the playbook builds it.

## Enrolment

Enrolment runs once, by hand.

```bash
ssh philpax@10.100.0.2
export HERMES_HOME=/srv/hermes/hermes

hermes memory setup honcho     # baseUrl is Honcho on localhost; local URLs
                               # auto-skip API key auth
hermes config set model ...    # ananke; the base URL is in
                               # /etc/hermes/ansible-vars.yml
```

The remaining steps use the dashboard on redline's tailnet address. Ansible generates its basic-auth password at `/srv/hermes/.dashboard-pass`; the username is `philpax`. The Channels page takes the Discord bot token, which requires Message Content Intent enabled in the Discord developer portal first. The Config page sets the approval mode. The Profiles page sets the agent's persona.

Approval mode defaults to `manual`, which prompts in the Discord thread. `smart` sends borderline commands to an auxiliary model first; its guard prompt is hardened against injection by stripping shell comments, delimiting the command, and returning ESCALATE for anything that appears to manipulate the review. `off` disables approval entirely and is not recommended.

## Recovery

### The agent has damaged its environment

The OS disk is disposable, which is why it is a separate disk.

```bash
virsh destroy hermes && virsh undefine hermes
sudo rm /mnt/ssd0/hermes/images/os.qcow2
sudo systemctl restart hermes-vm-provision   # recreates it and redefines
virsh start hermes

# The rebuilt guest has new SSH host keys. Without this the playbook fails at
# Gathering Facts with "REMOTE HOST IDENTIFICATION HAS CHANGED".
ssh-keygen -R 10.100.0.2

ansible-playbook -i inventory.ini hermes.yml
```

The state disk is untouched, so memory, config and Honcho's database survive. The procedure takes about 20 minutes.

### State is lost or corrupt

Restore from `/storage/backup/hermes`, using the newest timestamp:

Copy the pair into `/mnt/ssd0/hermes/drop` on the host so they appear at `/srv/drop` in the guest, then:

```bash
# in the guest
systemctl stop hermes-gateway hermes-dashboard
cd /srv/hermes/honcho/src
docker compose stop api deriver

tar --zstd -xf /srv/drop/hermes-home-<stamp>.tar.zst -C /srv/hermes
docker compose exec -T database \
  pg_restore -U honcho -d honcho --clean --if-exists < /srv/drop/honcho-<stamp>.dump

docker compose start api deriver
systemctl start hermes-gateway hermes-dashboard
```

`--if-exists` is required: without it `--clean` errors on a database that does not already hold the objects. `api` and `deriver` must be stopped, or their open connections block the drops.

The enrolment returns with `config.yaml`, which carries the model provider, the Honcho connection, the Discord token and the channel binding. The wizards do not need to be re-run.

### Memory is poisoned and the damage is noticed late

`/storage` is on ZFS with auto-snapshots (4 frequent, 24 hourly, 7 daily, 4 weekly, 12 monthly). Roll back to a snapshot from before the damage and restore from there.

### Total host loss

Restore with restic from the external drive, then follow the two procedures above.

## Operational notes

The backup contains secrets. `config.yaml` carries the Discord bot token, and the Honcho database password is on the state disk. The `/storage` copy is plaintext on a pool readable only by the owner. The restic copy to the external drive is encrypted. This trade is deliberate, because it is what allows a restore to return the enrolment, but it is a trade.

The backup is not trustworthy without the freshness check. `hermes-backup-check` on the host fails if nothing has been written to `drop/` for three hours, and is wired into `unit-alerts.nix`. A drop directory that stops updating is indistinguishable from a healthy one from rsync's perspective. This is the failure mode that most often defeats a backup, and it has the same shape as the 2026-07-27 btrfs miss.

The egress policy was verified from inside the guest on 2026-08-07. ananke's OpenAI port, the internet and DNS resolve; ananke's management port, host SSH, host Samba, the LAN gateway, Navidrome on redline's LAN address, redline over the tailnet, and the Docker bridge are all blocked. Re-run those checks after any change to the firewall rules or to `allowedTCPPorts` anywhere in the host configuration, because that option renders INPUT accepts with no interface predicate and would otherwise reopen the host to the guest.

The backup path was verified on the same date: `hermes-backup.service` produced both artefacts, the host read them through virtiofs, and `hermes-backup-check` reported fresh.

A restore drill has not been performed. The recovery section is design rather than evidence. Until the VM has been destroyed once and returned with its memory intact, the accurate description of confidence is "should work".

Honcho's cost falls on the GPUs, not on VM memory. The deriver performs multi-pass dialectic reasoning per message, so one Discord turn can produce several ananke calls beyond the agent's own. These contend with AudioMuse, whisper-lyrics and ComfyUI on the same two 3090s. If contention is a problem, point the deriver and the lower dialectic levels at a small resident model in `ansible/templates/honcho-config.toml.j2`.

The agent's working directory is `/srv/hermes/workspace`, on the state disk. Placed in `$HOME` it would sit on the disk that is designed to be deleted and rebuilt.

Both upstreams move quickly, and both refs are pinned in `ansible/hermes.yml`. When `honcho_ref` is bumped, diff their `docker-compose.yml.example` against `templates/honcho-compose.yml.j2`. The template removes the Postgres and Redis port mappings and sets real credentials, so upstream's example will drift from it.

The FORWARD chain position is contested. tailscaled and dockerd both insert at position 1 when they restart or reconcile, and `ts-forward` ends with `-o tailscale0 -j ACCEPT`, which would let the guest reach the tailnet. `iptables -S FORWARD` should show both `HERMES-FWD` jumps first; re-run `systemctl restart firewall` if it does not.

The off-host copy runs weekly, not hourly. `backup-sync` is scheduled Sundays at 02:00, so hourly dumps sit in `/mnt/ssd0/hermes/drop` for up to a week before reaching `/storage`. The retention described above is accurate; the latency to the ZFS copy is not hourly.

The agent is in the guest's `docker` group, which is root-equivalent inside the VM. The unpublished Postgres port and the drop directory raise the cost of tampering rather than preventing it; the VM boundary and the ZFS snapshots are what actually hold.

Editing `domain.nix` does not restart the VM. `virsh define` re-runs on every rebuild and the new definition applies at next boot. This is deliberate: a host rebuild should not interrupt a conversation in progress.
