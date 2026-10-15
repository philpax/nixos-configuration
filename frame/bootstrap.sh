#!/usr/bin/env bash
# Multi-user Nix on the Steam Frame's read-only SteamOS root, plus the boot
# unit that reactivates system-manager. Run once per device; rebuild.sh does
# everything after that.
#
# The store lives in /home/nix and is bind-mounted on /nix. The only rootfs
# write is the empty /nix mountpoint, recreated after OS updates by
# nix-mountpoint.service. Everything else lives in /etc paths kept by SteamOS
# atomic updates (/usr/lib/rauc/atomic-update-keep.conf) or in our drop-in at
# /etc/atomic-update.conf.d/nix.conf.
#
# Usage:
#   sudo bootstrap.sh install            install Nix; idempotent
#   bootstrap.sh check                   report what is present
#   sudo bootstrap.sh simulate-update    remove /nix as an OS update would; reboot to test
#   sudo bootstrap.sh uninstall [--purge-store]
set -euo pipefail

NIX_VERSION=2.35.3
NIX_SYSTEM=aarch64-linux
TARBALL_SHA256=4a770896faa4d308806d0b4516575e0581443dc817d634b951a219a280554c09
TARBALL_URL="https://releases.nixos.org/nix/nix-${NIX_VERSION}/nix-${NIX_VERSION}-${NIX_SYSTEM}.tar.xz"

STORE_HOME=/home/nix
UNIT_DIR=/etc/systemd/system
USER_DROPIN_DIR=$UNIT_DIR/user@.service.d
USER_DROPIN=$USER_DROPIN_DIR/after-system-manager.conf
KEEP_CONF=/etc/atomic-update.conf.d/nix.conf
PROFILE_SNIPPET=/etc/profile.d/nix-daemon.sh
TMPFILES_CONF=/etc/tmpfiles.d/nix-daemon.conf
NIX_CONF=/etc/nix/nix.conf
NIXBLD_GID=30000
NIXBLD_COUNT=32
MAIN_USER="${SUDO_USER:-steamos}"
DEFAULT_PROFILE=/nix/var/nix/profiles/default
SYSTEM_MANAGER_PROFILE=/nix/var/nix/profiles/system-manager-profiles/system-manager

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need_root() { [[ $(id -u) -eq 0 ]] || die "run as root (sudo $0 $*)"; }

preflight() {
    [[ $(uname -m) == aarch64 ]] || die "expected aarch64"
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ ${ID:-} == steamos ]] || die "expected SteamOS, found ${ID:-unknown}"
}

rootfs_set_ro() { btrfs property set / ro "$1"; }

ensure_mountpoint() {
    [[ -d /nix ]] && return
    log "creating /nix on the read-only root (brief unlock)"
    rootfs_set_ro false
    mkdir -m 0755 /nix || { rootfs_set_ro true; die "mkdir /nix failed"; }
    rootfs_set_ro true
}

write_units() {
    log "writing systemd units to $UNIT_DIR"
    cat >"$UNIT_DIR/nix-mountpoint.service" <<'EOF'
[Unit]
Description=Recreate the /nix mountpoint on the read-only SteamOS root
Documentation=https://github.com/philpax/nixos-configuration/blob/main/frame/README.md
DefaultDependencies=no
ConditionPathExists=!/nix
After=systemd-remount-fs.service
Before=nix.mount local-fs.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/bin/btrfs property set / ro false
ExecStart=/usr/bin/mkdir -m 0755 /nix
# Runs after ExecStart whether or not it succeeded, so the root is relocked.
ExecStopPost=/usr/bin/btrfs property set / ro true
EOF

    cat >"$UNIT_DIR/nix.mount" <<EOF
[Unit]
Description=Nix store (bind mount of $STORE_HOME)
RequiresMountsFor=$STORE_HOME
Wants=nix-mountpoint.service
After=nix-mountpoint.service

[Mount]
What=$STORE_HOME
Where=/nix
Type=none
Options=bind

[Install]
# Wanted, not required: a failed mount leaves SteamOS booting without Nix.
WantedBy=local-fs.target
EOF

    # Upstream units, but pointing at the default profile rather than a fixed
    # store path, so upgrading Nix in that profile upgrades the daemon.
    cat >"$UNIT_DIR/nix-daemon.socket" <<'EOF'
[Unit]
Description=Nix Daemon Socket
Before=multi-user.target
RequiresMountsFor=/nix/store
ConditionPathIsReadWrite=/nix/var/nix/daemon-socket

[Socket]
ListenStream=/nix/var/nix/daemon-socket/socket

[Install]
WantedBy=sockets.target
EOF

    cat >"$UNIT_DIR/nix-daemon.service" <<'EOF'
[Unit]
Description=Nix Daemon
Documentation=man:nix-daemon https://nixos.org/manual
RequiresMountsFor=/nix/store
RequiresMountsFor=/nix/var
RequiresMountsFor=/nix/var/nix/db
ConditionPathIsReadWrite=/nix/var/nix/daemon-socket

[Service]
ExecStart=@/nix/var/nix/profiles/default/bin/nix-daemon nix-daemon --daemon
KillMode=process
LimitNOFILE=1048576
TasksMax=1048576
Delegate=

[Install]
WantedBy=multi-user.target
EOF

    # A plain file: system-manager's own units link into /nix/store and dangle
    # until nix.mount, so this restores its /etc entries and starts its target.
    cat >"$UNIT_DIR/system-manager-boot.service" <<EOF
[Unit]
Description=Reactivate system-manager once /nix is mounted
Requires=nix.mount
After=nix.mount nix-daemon.socket
ConditionPathExists=$SYSTEM_MANAGER_PROFILE/bin/activate

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=$SYSTEM_MANAGER_PROFILE/bin/activate
# User managers wait for this; bound how long a hung activation delays login.
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

    # After an OS update, system-manager's /etc entries, including the user
    # environment generator, exist only once reactivation finishes; a session
    # started earlier would miss them. After= orders without requiring, so a
    # failed activation still lets the user log in.
    mkdir -p "$USER_DROPIN_DIR"
    cat >"$USER_DROPIN" <<EOF
[Unit]
After=system-manager-boot.service
EOF
}

write_etc() {
    log "writing $NIX_CONF, $PROFILE_SNIPPET, $TMPFILES_CONF, $KEEP_CONF"
    mkdir -p /etc/nix /etc/atomic-update.conf.d /etc/tmpfiles.d
    if [[ ! -e $NIX_CONF ]]; then
        cat >"$NIX_CONF" <<EOF
build-users-group = nixbld
trusted-users = root $MAIN_USER
experimental-features = nix-command flakes
max-jobs = auto
ssl-cert-file = /etc/ssl/certs/ca-certificates.crt
EOF
    else
        log "$NIX_CONF exists; leaving it alone"
    fi

    cat >"$PROFILE_SNIPPET" <<'EOF'
# Multi-user Nix. Guarded so shells still start when /nix is absent.
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
EOF

    cat >"$TMPFILES_CONF" <<'EOF'
d /nix/var/nix/daemon-socket 0755 root root -  -
d /nix/var/nix/builds        0755 root root 7d -
EOF

    # Patterns are rsync include patterns (see /usr/lib/steamos/holo-sync-var).
    # Units, .wants links and users are already covered by Valve's keep list.
    cat >"$KEEP_CONF" <<'EOF'
## Multi-user Nix (nixos-configuration frame/bootstrap.sh)
/etc/nix/**
/etc/profile.d/nix-daemon.sh
/etc/tmpfiles.d/nix-daemon.conf
EOF
}

create_users() {
    if ! getent group nixbld >/dev/null; then
        log "creating group nixbld ($NIXBLD_GID)"
        groupadd --system --gid "$NIXBLD_GID" nixbld
    fi
    local i
    for ((i = 1; i <= NIXBLD_COUNT; i++)); do
        getent passwd "nixbld$i" >/dev/null && continue
        useradd --system --no-create-home --uid $((NIXBLD_GID + i)) \
            --gid nixbld --groups nixbld --home-dir /var/empty \
            --shell /usr/bin/nologin --comment "Nix build user $i" "nixbld$i"
    done
}

populate_store() {
    if [[ -x $DEFAULT_PROFILE/bin/nix ]]; then
        log "default profile already has Nix; skipping store population"
        return
    fi
    local work tarball unpack nix cacert
    work=$(mktemp -d)
    trap 'rm -rf "${work:-}"; trap - RETURN' RETURN
    tarball="$work/nix.tar.xz"
    log "downloading $TARBALL_URL"
    curl -fL --proto '=https' -o "$tarball" "$TARBALL_URL"
    echo "$TARBALL_SHA256  $tarball" | sha256sum -c - >/dev/null || die "tarball hash mismatch"
    tar -xJf "$tarball" -C "$work"
    unpack="$work/nix-${NIX_VERSION}-${NIX_SYSTEM}"

    install -d -m 0755 /nix/var /nix/var/log /nix/var/log/nix /nix/var/log/nix/drvs \
        /nix/var/nix /nix/var/nix/db /nix/var/nix/gcroots /nix/var/nix/profiles \
        /nix/var/nix/temproots /nix/var/nix/userpool /nix/var/nix/daemon-socket \
        /nix/var/nix/gcroots/per-user /nix/var/nix/profiles/per-user
    install -d -g nixbld -m 1775 /nix/store

    log "copying bootstrap store paths"
    local path
    for path in "$unpack"/store/*; do
        [[ -e /nix/store/${path##*/} ]] || cp -RPp "$path" /nix/store/
        chmod -R a-w "/nix/store/${path##*/}"
    done

    nix=$(echo /nix/store/*-nix-"$NIX_VERSION")
    cacert=$(sed -n 's/^cacert="\(.*\)"$/\1/p' "$unpack/install")
    [[ -x $nix/bin/nix-store && -d $cacert ]] || die "could not locate nix/cacert in tarball"

    "$nix/bin/nix-store" --load-db <"$unpack/.reginfo"
    NIX_REMOTE= "$nix/bin/nix-env" -p "$DEFAULT_PROFILE" -i "$nix" "$cacert"
}

cmd_install() {
    need_root install
    preflight
    [[ -d /home ]] && mountpoint -q /home || die "/home is not mounted"
    install -d -m 0755 "$STORE_HOME"

    create_users
    write_units
    write_etc
    ensure_mountpoint

    systemctl daemon-reload
    systemctl enable nix.mount nix-daemon.socket nix-daemon.service system-manager-boot.service
    systemctl start nix.mount
    mountpoint -q /nix || die "/nix did not mount"

    populate_store
    systemd-tmpfiles --create "$TMPFILES_CONF"
    # The socket refuses to listen while a previous daemon is still running.
    systemctl stop nix-daemon.service nix-daemon.socket
    systemctl start nix-daemon.socket

    log "installed; next: frame/rebuild.sh switch"
    cmd_check
}

check_line() {
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then printf '  ok       %s\n' "$label"; else printf '  MISSING  %s\n' "$label"; FAILED=1; fi
}

cmd_check() {
    FAILED=0
    echo "Nix on SteamOS:"
    check_line "rootfs is read-only" sh -c '[ "$(btrfs property get / ro)" = "ro=true" ]'
    check_line "/nix exists" test -d /nix
    check_line "/nix is mounted" mountpoint -q /nix
    check_line "$STORE_HOME populated" test -d "$STORE_HOME/store"
    for unit in nix-mountpoint.service nix.mount nix-daemon.socket nix-daemon.service system-manager-boot.service; do
        check_line "unit $unit" test -f "$UNIT_DIR/$unit"
    done
    check_line "nix.mount enabled" systemctl is-enabled nix.mount
    check_line "system-manager-boot.service enabled" systemctl is-enabled system-manager-boot.service
    check_line "user sessions wait for system-manager-boot" test -f "$USER_DROPIN"
    check_line "nix-daemon.socket active" systemctl is-active nix-daemon.socket
    check_line "nixbld group" getent group nixbld
    check_line "nixbld$NIXBLD_COUNT user" getent passwd "nixbld$NIXBLD_COUNT"
    check_line "$NIX_CONF" test -f "$NIX_CONF"
    check_line "$PROFILE_SNIPPET" test -f "$PROFILE_SNIPPET"
    check_line "$TMPFILES_CONF" test -f "$TMPFILES_CONF"
    check_line "$KEEP_CONF" test -f "$KEEP_CONF"
    check_line "daemon answers" "$DEFAULT_PROFILE/bin/nix" --extra-experimental-features nix-command store info --store daemon
    check_line "system-manager profile" test -x "$SYSTEM_MANAGER_PROFILE/bin/activate"
    return "$FAILED"
}

# Sandboxed system services hold copies of the /nix mount in their own
# namespaces, so a normal unmount of a live store reports busy; detach lazily.
unmount_store() {
    systemctl stop system-manager.target nix-daemon.service nix-daemon.socket || true
    systemctl stop nix.mount || umount --lazy /nix
    ! mountpoint -q /nix || die "/nix is still mounted"
}

cmd_simulate_update() {
    need_root simulate-update
    preflight
    log "simulating an OS update: unmounting and removing /nix"
    unmount_store
    rootfs_set_ro false
    rmdir /nix || { rootfs_set_ro true; die "rmdir /nix failed (not empty?)"; }
    rootfs_set_ro true
    log "done; reboot, then run: $0 check"
}

cmd_uninstall() {
    need_root uninstall
    preflight
    local purge=0
    [[ ${1:-} == --purge-store ]] && purge=1
    if [[ -x $SYSTEM_MANAGER_PROFILE/bin/deactivate ]]; then
        log "deactivating system-manager"
        "$SYSTEM_MANAGER_PROFILE/bin/deactivate"
    fi
    unmount_store
    systemctl disable nix-daemon.socket nix-daemon.service nix.mount system-manager-boot.service || true
    rm -f "$UNIT_DIR"/nix-mountpoint.service "$UNIT_DIR"/nix.mount \
        "$UNIT_DIR"/nix-daemon.socket "$UNIT_DIR"/nix-daemon.service \
        "$UNIT_DIR"/system-manager-boot.service "$USER_DROPIN"
    rmdir --ignore-fail-on-non-empty "$USER_DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
    rm -f "$PROFILE_SNIPPET" "$TMPFILES_CONF" "$KEEP_CONF"
    rm -rf /etc/nix
    local i
    for ((i = 1; i <= NIXBLD_COUNT; i++)); do
        getent passwd "nixbld$i" >/dev/null && userdel "nixbld$i"
    done
    getent group nixbld >/dev/null && groupdel nixbld
    if [[ -d /nix ]] && ! mountpoint -q /nix; then
        rootfs_set_ro false
        rmdir /nix || true
        rootfs_set_ro true
    fi
    if ((purge)); then
        log "removing $STORE_HOME"
        rm -rf --one-file-system "$STORE_HOME"
    else
        log "kept $STORE_HOME; pass --purge-store to delete it"
    fi
}

case ${1:-} in
    install) cmd_install ;;
    check) cmd_check ;;
    simulate-update) cmd_simulate_update ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
