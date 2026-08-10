# Sandboxed Hermes Agent

A [Hermes Agent](https://github.com/NousResearch/hermes-agent) instance runs in an Ubuntu VM under libvirt. The agent uses ananke for inference, Signal for input, and Hermes' built-in memory (MEMORY.md / USER.md) for persistence.

The VM runs as a single root account, reachable only from redline over a host-only bridge. Concrete addresses, ports, sizes and refs live in `net.nix`, `domain.nix` and `ansible/hermes.yml`; this README states decisions and procedures, and points at those files rather than restating values.

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

Two mechanisms recover most of the reproducibility this costs. The Ansible playbook is re-runnable and converges an existing VM. The hourly backup captures `config.yaml` and `.env`, and therefore captures the enrolment.

## Bring-up

`/dev/kvm` must exist, which requires SVM enabled in the UEFI setup.

```bash
sudo nixos-rebuild switch          # creates disks, defines the domain
virsh start hermes
virsh console hermes               # watch cloud-init; ctrl-] to exit
hermes-ssh                         # once it is up

cd redline/hermes/ansible
ansible-playbook -i /etc/hermes/inventory.ini hermes.yml
```

The VM is reachable only from redline, over the host-only bridge. `hermes-ssh` (redline's fish dotfiles, `redline/dotfiles/.config/fish/functions/hermes-ssh.fish`) connects as root with redline's own key, which the seed pulls from the primary user account (`config.mainUser`) and installs for root. There is no other route into the guest and no other account.

The agent runs as root. The sandbox is the libvirt VM boundary, the host egress firewall (`HERMES-FWD`), the ZFS snapshots and the backup-freshness check, not the guest UID. Root login is key-only. The gateway, dashboard and signal-cli daemon run as root, so the agent can restart its own gateway with `systemctl restart hermes-gateway` and no extra grant.

The playbook installs Hermes with upstream's own installer, `scripts/install.sh`, from the pinned checkout rather than curled from the website. The installer flags and pinned refs are in `ansible/hermes.yml`. `--dir` and `--hermes-home` are load-bearing: both default under `~`, which is on the disposable OS disk, so without them the agent's configuration and memory are destroyed by the OS-disk rebuild procedure below. `--skip-setup` suppresses the enrolment wizard, which otherwise blocks the run on a `read` indefinitely.

Node is installed from NodeSource by the playbook, because the dashboard's frontend build needs a newer Node than Ubuntu 24.04 ships; the repository and version are in `ansible/hermes.yml`.

## Enrolment

Enrolment runs once, by hand.

```bash
hermes-ssh
# HERMES_HOME is exported by /etc/profile.d/hermes.sh on the guest.

hermes config set model ...    # the provider/base URL are in
                               # /etc/hermes/ansible-vars.yml
```

The agent home is defined by `hermes_home` in `ansible/hermes.yml` and exported by `/etc/profile.d/hermes.sh` on the guest.

The remaining steps use the dashboard on redline's tailnet address. Ansible generates its basic-auth password at `/srv/hermes/.dashboard-pass`; the username is in the dashboard template. The Config page sets the approval mode. The Profiles page sets the agent's persona. The Signal channel is configured through the gateway env vars in the agent `.env` (`SIGNAL_HTTP_URL`, `SIGNAL_ACCOUNT`, `SIGNAL_ALLOWED_USERS`) with `platforms.signal.enabled: true` in `config.yaml`.

Approval mode runs `smart`. Borderline commands go to an auxiliary model first; the guard prompt is hardened against injection by stripping shell comments, delimiting the command, and returning ESCALATE for anything that appears to manipulate the review. `manual` prompts in the message thread. `off` disables approval entirely and is not recommended.

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
ssh-keygen -R "$(sed -n 's/^  guestAddr = "\([^"]*\)";/\1/p' net.nix)"

ansible-playbook -i /etc/hermes/inventory.ini hermes.yml
```

The state disk is untouched, so memory and config survive. The procedure takes about 20 minutes.

### State is lost or corrupt

Restore from `/storage/backup/hermes`, using the newest timestamp.

Copy the pair into `/mnt/ssd0/hermes/drop` on the host so they appear at `/srv/drop` in the guest, then:

```bash
# in the guest
systemctl stop hermes-gateway hermes-dashboard
tar --zstd -xf /srv/drop/hermes-home-<stamp>.tar.zst -C /srv/hermes
systemctl start hermes-gateway hermes-dashboard
```

The `hermes-home-*.tar.zst` archive holds `state.db`, `sessions/` and `config.yaml`, which carry the memory and enrolment. The `honcho-*.dump` artefacts are legacy: Honcho is no longer provisioned, and the database it produced is not used.

The enrolment returns with `config.yaml`, which carries the model provider. The `SIGNAL_*` env vars live in the agent `.env`, captured in the same backup. The wizards do not need to be re-run.

### Memory is poisoned and the damage is noticed late

`/storage` is on ZFS with auto-snapshots. Roll back to a snapshot from before the damage and restore from there.

### Total host loss

Restore with restic from the external drive, then follow the two procedures above.

## Operational notes

The backup contains secrets. `config.yaml` and `.env` carry the model provider, the approval config and the `SIGNAL_*` vars. The `/storage` copy is plaintext on a pool readable only by the owner. The restic copy to the external drive is encrypted. This trade is deliberate: it is what allows a restore to return the enrolment.

The backup is not trustworthy without the freshness check. `hermes-backup-check` (in `default.nix`) fails if nothing has been written to the drop for the window defined there, and is wired into `unit-alerts.nix`. A drop directory that stops updating is indistinguishable from a healthy one from rsync's perspective. This is the failure mode that most often defeats a backup.

The egress policy was verified from inside the guest on 2026-08-07. ananke's OpenAI port, the internet and DNS resolve; ananke's management port, host SSH, host Samba, the LAN gateway, Navidrome on redline's LAN address, redline over the tailnet, and the Docker bridge are all blocked. Re-run those checks after any change to the firewall rules or to `allowedTCPPorts` anywhere in the host configuration, because that option renders INPUT accepts with no interface predicate and would otherwise reopen the host to the guest.

The backup path was verified on the same date: `hermes-backup.service` produced both artefacts, the host read them through virtiofs, and `hermes-backup-check` reported fresh.

A restore drill has not been performed. The recovery section is design rather than evidence. Until the VM has been destroyed once and returned with its memory intact, the accurate description of confidence is "should work".

The agent uses Hermes' built-in memory (`MEMORY.md` / `USER.md`), which makes no LLM calls in the background. Honcho was previously the external memory provider; its per-message deriver and dialectic pipeline issued several model calls beyond the agent's own. It is removed from provisioning, and the remaining `honcho-*.dump` backup artefacts are retained but unused.

The agent's working directory is defined by `workspace` in `ansible/hermes.yml`, on the state disk. In `$HOME` it would sit on the disk that is designed to be deleted and rebuilt.

The FORWARD chain position is contested. tailscaled and dockerd both insert at position 1 when they restart or reconcile, and `ts-forward` ends with `-o tailscale0 -j ACCEPT`, which would let the guest reach the tailnet. `iptables -S FORWARD` should show both `HERMES-FWD` jumps first; re-run `systemctl restart firewall` if it does not.

The off-host copy schedule is defined in the host's backup module; hourly dumps sit in the host drop directory until the weekly sync reaches `/storage`. The latency to the ZFS copy is not hourly.

The agent is in the guest's `docker` group, which is root-equivalent inside the VM. The drop directory raises the cost of tampering rather than preventing it; the VM boundary and the ZFS snapshots are what actually hold.

Signal is the messaging channel. The Ansible playbook installs the bridge and its daemon unit; the daemon stays disabled until the phone completes device linking. The linking procedure and secret-handling are described in the playbook's Signal section. The gateway enables Signal when `SIGNAL_HTTP_URL` and `SIGNAL_ACCOUNT` are set in the agent `.env`; `SIGNAL_ALLOWED_USERS` lists the numbers allowed to DM, and should be set to the account number. Groups default to off; opt in with `SIGNAL_GROUP_ALLOWED_USERS`.

Editing `domain.nix` does not restart the VM. `virsh define` re-runs on every rebuild and the new definition applies at next boot. This is deliberate: a host rebuild should not interrupt a conversation in progress.