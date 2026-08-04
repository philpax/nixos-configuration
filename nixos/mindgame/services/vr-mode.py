"""vr-mode — pick which OpenXR runtime is active, and set up the headset for it.

Nothing runs at startup (wivrn autoStart is off, monado is socket-activated);
this is how a runtime is turned on and off, so exactly one — or neither — is
ever active. Switching sets the per-user active_runtime.json (~/.config wins
over /etc/xdg) and starts the matching service, stopping the other so they
never fight over the runtime slot or the headset.

Configuration comes from VR_MODE_* environment variables, set by the Nix
wrapper (see vr-mode.nix).
"""

import argparse
import fcntl
import glob
import json
import os
import re
import select
import shlex
import struct
import subprocess
import sys
import time

# --- configuration -----------------------------------------------------------
#
# Supplied by the Nix wrapper (see vr-mode.nix), which also puts pactl,
# systemctl, journalctl and systemd-run on PATH. The tunables have defaults so
# this stays runnable straight from a checkout for development; the store paths
# don't, because guessing them would be worse than failing.


def env(name, default=None):
    value = os.environ.get("VR_MODE_" + name)
    if value is not None:
        return value
    if default is None:
        sys.exit(f"vr-mode: VR_MODE_{name} is unset (it should be set by the Nix wrapper)")
    return default


MONADO_JSON = env("MONADO_JSON")
WIVRN_JSON = env("WIVRN_JSON")
WAYVR = env("WAYVR")
XRIZER_RUNTIME = env("XRIZER_RUNTIME")
IPD_LAUNCHER = env("IPD_LAUNCHER")

# The Beyond 2e's lenses are positioned by hand with a hex tool and there's no
# encoder behind them, so Monado has no way to discover the IPD — it has to be
# told. Parsed as a float and reprinted with %g at the point of use, so Nix can
# pass a plain number (it renders floats with %f, i.e. "68.300000").
BEYOND_IPD_MM = float(env("BEYOND_IPD_MM", "68.3"))

# Product name in the Beyond's EDID, used to find which connector it's on.
BEYOND_EDID_NAME = env("BEYOND_EDID_NAME", "Beyond")

# The Beyond stays powered whenever it's plugged in — deliberately, so the
# lenses stay unfogged and it's ready to wear — but its fan is off at power-on
# and nothing on Linux turns it on, since that lives in Bigscreen's Windows-only
# SteamVR driver. Left alone the board just soaks. Runtime-only, so we reapply
# on every activation.
FAN_IDLE = int(env("FAN_IDLE", "40"))  # not in use, but still powered
FAN_ACTIVE = int(env("FAN_ACTIVE", "70"))  # on a face

# --- constants ---------------------------------------------------------------

# The Index takes audio over the GPU's DisplayPort link, not USB. That output is
# only exposed once the GB202's audio card is in its "Pro Audio" profile, where
# the HMD panel's PCM shows up as the "Pro 8" sink.
# https://wiki.vronlinux.org/docs/hardware/#valve-index-quirks
INDEX_CARD = "alsa_card.pci-0000_01_00.1"
INDEX_SINK = "alsa_output.pci-0000_01_00.1.pro-output-8"

# The Beyond's strap is an ordinary USB audio device, so none of the Index's
# pro-audio machinery applies. Prefix-matched: the node name is generated from
# the USB descriptors.
BEYOND_SINK_PREFIX = "alsa_output.usb-Bigscreen_Beyond_Audio_Strap"

# Beyond HID, for fan control and telemetry. Protocol recovered from
# BeyondHID.exe: feature report [0]=report id 0, [1]=opcode, [2..]=args.
#   0x46 'F' + duty   set fan speed
#   0x23 '#'          unsolicited telemetry, ~1Hz, 24-byte payload
# Runtime only — this never touches the persistent config area (0x55/0x57/0x56),
# which shares flash with the tracking serial and proximity calibration. The fan
# is off at power-on and the stored value is applied only by Bigscreen's
# Windows-only driver, so we reapply on every activation.
BEYOND_HID_ID = "0003:000035BD:00000101"
OP_SET_FAN = 0x46
OP_TELEMETRY = 0x23
FAN_MIN, FAN_MAX = 40, 100
FAN_GEN = 2  # gen 2 halves the wire value

RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
CONFIG_DIR = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
ACTIVE_RUNTIME = os.path.join(CONFIG_DIR, "openxr/1/active_runtime.json")
ENV_FILE = os.path.join(RUNTIME_DIR, "vr-mode.env")
PREV_SINK_FILE = os.path.join(RUNTIME_DIR, "vr-mode.prev-sink")
BEYOND_MARKER = "# headset=beyond"


def say(msg, err=False):
    print(f"vr-mode: {msg}", file=sys.stderr if err else sys.stdout)


# --- systemd -----------------------------------------------------------------


def run(argv):
    """Run a tool, tolerating its absence. The wrapper puts systemd and
    pulseaudio on PATH, but this is also runnable straight from a checkout,
    where a missing pactl shouldn't be fatal to `status`."""
    try:
        return subprocess.run(argv, capture_output=True, text=True)
    except FileNotFoundError:
        return subprocess.CompletedProcess(argv, 127, "", "")


def sysctl(*args):
    return run(["systemctl", "--user", *args])


def is_active(unit):
    return sysctl("is-active", unit).stdout.strip() == "active"


def stop(*units):
    sysctl("stop", *units)


def stop_monado():
    # Stop the socket too, so nothing socket-activates monado while it's meant
    # to be off / while WiVRn is active.
    stop("monado.service", "monado.socket")


# WayVR and the IPD overlay run as transient units so we can stop them cleanly.
def stop_extras():
    stop("vr-wayvr.service", "vr-ipd-overlay.service")


def run_transient(unit, argv):
    sysctl("reset-failed", f"{unit}.service")
    run(["systemd-run", "--user", f"--unit={unit}", "--collect", "--", *argv])


# --- monado ------------------------------------------------------------------


def write_env(*lines):
    """Per-run overrides for monado.service, via its EnvironmentFile drop-in
    (see monado.nix). Every mode rewrites or removes this, so one run's
    overrides can't leak into the next."""
    with open(ENV_FILE, "w") as f:
        for line in lines:
            f.write(line + "\n")


def monado_ready(tries=40):
    """Monado needs several seconds to probe Lighthouse devices and lease the
    headset panel before it accepts OpenXR clients, and it stays systemd-active
    even when the compositor fails (IPC_EXIT_ON_DISCONNECT=off) — so is-active
    is not a readiness signal. Poll this run's journal for the compositor-up
    marker, bailing early on the failure markers."""
    inv = sysctl("show", "-p", "InvocationID", "--value", "monado.service").stdout.strip()
    for _ in range(tries):
        log = run(
            [
                "journalctl",
                "--user",
                "-u",
                "monado.service",
                f"_SYSTEMD_INVOCATION_ID={inv}",
                "--no-pager",
            ]
        ).stdout
        if "Started vblank event thread" in log:
            return True
        if re.search(r"create_system failed|Failed to init compositor", log):
            return False
        time.sleep(0.5)
    return False


def start_monado():
    """Bring monado up and wait until it's actually usable. The SteamVR-LH
    driver intermittently fails device creation, so retry; each attempt starts
    from a clean socket, because a stale/unlinked monado_comp_ipc (e.g. from an
    unclean exit) leaves the unit "active" while clients get ENOENT, which a
    plain restart wouldn't recover from."""
    for attempt in range(1, 4):
        stop("monado.service", "monado.socket")
        sysctl("reset-failed", "monado.service", "monado.socket")
        try:
            os.unlink(os.path.join(RUNTIME_DIR, "monado_comp_ipc"))
        except OSError:
            pass
        sysctl("start", "monado.service")
        if monado_ready():
            return True
        say(f"monado init failed (attempt {attempt}/3), retrying...", err=True)
        time.sleep(2)
    return False


def start_wayvr():
    """Monado has no built-in app launcher, so bring up the WayVR desktop
    overlay ourselves — otherwise the headset is a black void. (WiVRn starts its
    own, which is why the wivrn path doesn't call this.)"""
    run_transient("vr-wayvr", [WAYVR])


# --- runtime selection -------------------------------------------------------


def set_active_runtime(target):
    os.makedirs(os.path.dirname(ACTIVE_RUNTIME), exist_ok=True)
    try:
        os.unlink(ACTIVE_RUNTIME)
    except OSError:
        pass
    os.symlink(target, ACTIVE_RUNTIME)


def write_openvrpaths():
    """SteamVR-only games (VRChat, Resonite, ...) reach VR through the OpenVR
    API, which resolves its runtime from openvrpaths.vrpath. Point that at
    xrizer (the OpenVR -> OpenXR shim) so those games route through whichever
    OpenXR runtime is active instead of launching SteamVR — SteamVR can't lease
    the panel out from under monado, so the game would drop to flatscreen.
    SteamVR rewrites this file and re-registers itself as the first runtime
    whenever it runs, so we reassert xrizer on every activation rather than
    trusting it to stick."""
    steam = os.path.expanduser("~/.local/share/Steam")
    path = os.path.join(CONFIG_DIR, "openvr/openvrpaths.vrpath")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(
            {
                "config": [f"{steam}/config"],
                "external_drivers": None,
                "jsonid": "vrpathreg",
                "log": [f"{steam}/logs"],
                "runtime": [XRIZER_RUNTIME],
                "version": 1,
            },
            f,
            indent="\t",
        )
    say("openvrpaths -> xrizer (OpenVR games route through OpenXR)")


# --- audio -------------------------------------------------------------------


def pactl(*args):
    return run(["pactl", *args])


def remember_sink(new_sink):
    """Remember the current default sink, unless we're already pointed at the
    headset, so off/wivrn can put it back."""
    cur = pactl("get-default-sink").stdout.strip()
    if cur and cur != new_sink:
        with open(PREV_SINK_FILE, "w") as f:
            f.write(cur + "\n")


def index_audio_on():
    remember_sink(INDEX_SINK)
    if pactl("set-card-profile", INDEX_CARD, "pro-audio").returncode:
        say(f"could not put {INDEX_CARD} into pro-audio", err=True)
    # The Pro 8 sink can take a beat to register after a profile change.
    for _ in range(5):
        if pactl("set-default-sink", INDEX_SINK).returncode == 0:
            say("audio routed to Index (Pro 8)")
            return
        time.sleep(0.3)
    say(f"Index sink {INDEX_SINK} not available", err=True)


def beyond_audio_on():
    for line in pactl("list", "short", "sinks").stdout.splitlines():
        if BEYOND_SINK_PREFIX in line:
            sink = line.split("\t")[1]
            break
    else:
        say("Beyond audio strap sink not found (is the strap attached?)", err=True)
        return
    remember_sink(sink)
    if pactl("set-default-sink", sink).returncode == 0:
        say("audio routed to Beyond audio strap")
    else:
        say(f"could not route audio to {sink}", err=True)


def audio_off():
    """Shared by both headsets; the card-profile reset is a no-op when the Index
    isn't the one in use."""
    try:
        with open(PREV_SINK_FILE) as f:
            prev = f.read().strip()
        if prev:
            pactl("set-default-sink", prev)
        os.unlink(PREV_SINK_FILE)
    except OSError:
        pass
    pactl("set-card-profile", INDEX_CARD, "off")


# --- hardware discovery ------------------------------------------------------


def beyond_connector():
    """Which connector is the Beyond on? Resolved from EDID rather than
    hardcoded: ports renumber whenever cables move, and Monado falls back to
    "the first available connector" when the one it was asked for is absent — so
    a stale name fails silently, leasing whatever it finds instead."""
    for edid in sorted(glob.glob("/sys/class/drm/card*-*/edid")):
        try:
            data = open(edid, "rb").read()
        except OSError:
            continue
        if BEYOND_EDID_NAME.encode() in data:
            card = os.path.basename(os.path.dirname(edid))  # card1-DP-3
            return card.split("-", 1)[1]  # DP-3
    return None


def hmd_present():
    """Is a wired HMD attached? Without this, quiesce spins monado up at every
    login only to time out when nothing is plugged in. The Index HMD and its
    controllers share 28de:2300, so the product string is what tells them apart;
    the Beyond is matched on vendor alone, since it moves between product IDs."""
    for dev in glob.glob("/sys/bus/usb/devices/*"):
        try:
            vid = open(os.path.join(dev, "idVendor")).read().strip()
        except OSError:
            continue
        try:
            product = open(os.path.join(dev, "product")).read().strip()
        except OSError:
            product = ""
        if vid == "35bd" or (vid == "28de" and product == "Index HMD"):
            return True
    return False


# --- Beyond fan / telemetry --------------------------------------------------


def beyond_hidraw():
    for d in glob.glob("/sys/class/hidraw/hidraw*"):
        try:
            uevent = open(os.path.join(d, "device", "uevent")).read()
        except OSError:
            continue
        if BEYOND_HID_ID in uevent:
            return "/dev/" + os.path.basename(d)
    return None


def hidiocsfeature(n):
    """HIDIOCSFEATURE(len) = _IOC(_IOC_WRITE|_IOC_READ, 'H', 0x06, len)"""
    return (3 << 30) | (n << 16) | (0x48 << 8) | 0x06


def set_fan(percent, quiet=True):
    """Set the Beyond's fan. The utility's user-facing range is 40..100, halved
    on the wire for fan-generation-2 headsets, so 100% goes out as 50."""
    node = beyond_hidraw()
    if node is None:
        if not quiet:
            say("no Beyond attached, not setting fan", err=True)
        return
    pct = max(FAN_MIN, min(FAN_MAX, percent))
    wire = pct // (2 if FAN_GEN == 2 else 1)
    buf = bytearray(65)
    buf[1] = OP_SET_FAN
    buf[2] = wire
    fd = os.open(node, os.O_RDWR | os.O_NONBLOCK)
    try:
        fcntl.ioctl(fd, hidiocsfeature(len(buf)), bytes(buf))
    finally:
        os.close(fd)
    say(f"Beyond fan -> {pct}% (wire {wire})")


def telemetry(seconds):
    """Watch the Beyond's unsolicited 1Hz status reports. Sends nothing."""
    node = beyond_hidraw()
    if node is None:
        say("no Beyond attached", err=True)
        return 1
    fd = os.open(node, os.O_RDONLY | os.O_NONBLOCK)
    deadline = time.time() + seconds
    try:
        while time.time() < deadline:
            if not select.select([fd], [], [], 0.3)[0]:
                continue
            try:
                d = os.read(fd, 128)
            except OSError:
                continue
            if len(d) < 24 or d[0] != OP_TELEMETRY:
                continue
            board, left, right = (struct.unpack_from("<f", d, o)[0] for o in (10, 14, 18))
            rpm = struct.unpack_from(">H", d, 2)[0]
            bright = struct.unpack_from(">H", d, 22)[0]
            print(
                f"  board={board:8.2f}  rpm={rpm:>5}  "
                f"displays={left:+.3f}/{right:+.3f}  brightness={bright}"
            )
    finally:
        os.close(fd)
    return 0


# --- modes -------------------------------------------------------------------


def mode_index():
    stop("vr-quiesce.service", "wivrn.service")
    stop_extras()
    write_env()  # no overrides: use monado.service's own environment
    set_active_runtime(MONADO_JSON)
    write_openvrpaths()
    if not start_monado():
        say("monado could not bring up the Index.", err=True)
        say("  check: journalctl --user -u monado.service -e", err=True)
        return 1
    start_wayvr()
    # IPD heads-up overlay. Index-only: it surfaces changes in the motorised
    # IPD, and the Beyond's is a fixed mechanical setting with nothing to report.
    run_transient("vr-ipd-overlay", shlex.split(IPD_LAUNCHER))
    index_audio_on()
    set_fan(FAN_IDLE)  # Beyond idle, if it is attached at all
    say("index (monado) active, WayVR + IPD overlay launched")
    return 0


def mode_beyond():
    stop("vr-quiesce.service", "wivrn.service")
    stop_extras()
    connector = beyond_connector()
    if connector is None:
        say("no Beyond found on any DisplayPort connector.", err=True)
        say("  is it plugged in and awake?", err=True)
        return 1
    say(f"beyond on {connector}")
    # The marker is a comment to systemd, and how `status` tells a beyond
    # session apart from an index one — both run on monado.
    write_env(
        BEYOND_MARKER,
        f"XRT_COMPOSITOR_WAYLAND_CONNECTOR={connector}",
        f"LH_OVERRIDE_IPD_MM={BEYOND_IPD_MM:g}",
    )
    set_active_runtime(MONADO_JSON)
    write_openvrpaths()
    if not start_monado():
        say("monado could not bring up the Beyond.", err=True)
        say("  check: journalctl --user -u monado.service -e", err=True)
        return 1
    start_wayvr()
    beyond_audio_on()
    set_fan(FAN_ACTIVE)
    say("beyond (monado) active, WayVR launched")
    return 0


def mode_wivrn():
    stop("vr-quiesce.service")
    stop_monado()
    stop_extras()  # WiVRn launches its own WayVR on session start
    audio_off()  # Quest uses its own audio; give the desktop sink back
    set_active_runtime(WIVRN_JSON)
    write_openvrpaths()
    sysctl("start", "wivrn.service")
    say("wivrn (quest) active")
    return 0


def mode_off():
    stop("vr-quiesce.service", "wivrn.service")
    stop_monado()
    stop_extras()
    audio_off()
    for path in (ACTIVE_RUNTIME, ENV_FILE):
        try:
            os.unlink(path)
        except OSError:
            pass
    set_fan(FAN_IDLE)
    say("all runtimes stopped")
    return 0


def mode_quiesce():
    """A wired Lighthouse HMD powers its panels on by default and is only ever
    told to sleep when the driver tears the device down. Nothing activates it at
    boot, so it sits lit until the first activate/deactivate cycle. Do that once
    at login so it starts the day asleep.

    Lighter than a real session: no WayVR, no IPD overlay, no audio, no
    active_runtime change. Still waits for full readiness before stopping,
    though — tearing down on the earlier "Found lighthouse HMD" marker raced
    Context::create and segfaulted driver_lighthouse, which left the panels lit
    anyway."""
    if is_active("monado.service") or is_active("wivrn.service"):
        say("a runtime is already active, nothing to quiesce")
        return 0
    if not hmd_present():
        say("no wired HMD attached, nothing to quiesce")
        return 0
    # Base stations don't matter here, only that the HMD announces itself.
    write_env("LH_DISCOVER_WAIT_MS=1500")
    sysctl("reset-failed", "monado.service", "monado.socket")
    sysctl("start", "monado.service")
    if monado_ready():
        say("headset up, putting it back to sleep")
    else:
        # Still tear down — if a device was created late we want it asleep, and
        # if none was there's nothing lit to worry about either way.
        say("no headset activated during quiesce", err=True)
    stop_monado()
    try:
        os.unlink(ENV_FILE)
    except OSError:
        pass
    # stop_monado takes the socket down with the service; put it back so the
    # session returns to its normal idle, socket-activated state.
    sysctl("start", "monado.socket")
    return 0


def mode_status():
    target = os.path.realpath(ACTIVE_RUNTIME) if os.path.lexists(ACTIVE_RUNTIME) else None
    if target is None:
        print("active runtime: none")
    elif target.endswith("openxr_monado.json"):
        # Both headsets run on monado, so the runtime symlink alone can't tell
        # them apart — the per-run env file is what distinguishes them.
        beyond = False
        try:
            beyond = BEYOND_MARKER in open(ENV_FILE).read()
        except OSError:
            pass
        print(f"active runtime: {'beyond' if beyond else 'index'} (monado)")
    elif target.endswith("openxr_wivrn.json"):
        print("active runtime: wivrn (quest)")
    else:
        print("active runtime: unknown")
    for unit in ("monado.service", "wivrn.service", "vr-wayvr.service", "vr-ipd-overlay.service"):
        print(f"  {unit + ':':<23}{sysctl('is-active', unit).stdout.strip()}")
    sink = pactl("get-default-sink").stdout.strip() or "unknown"
    print(f"  {'default sink:':<23}{sink}")
    return 0


def main():
    ap = argparse.ArgumentParser(
        prog="vr-mode", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="mode")
    sub.add_parser("index", help="Valve Index via Monado (+ WayVR)")
    sub.add_parser("beyond", help="Bigscreen Beyond 2e via Monado (+ WayVR)")
    sub.add_parser("wivrn", help="Quest via WiVRn")
    sub.add_parser("off", help="stop everything, no runtime active")
    sub.add_parser("quiesce", help="wake headsets just long enough to sleep")
    sub.add_parser("status", help="show current runtime + service state")
    fan = sub.add_parser("fan", help="set the Beyond's fan speed")
    fan.add_argument("percent", type=int, help=f"{FAN_MIN}-{FAN_MAX}")
    tel = sub.add_parser("telemetry", help="watch the Beyond's status reports")
    tel.add_argument("seconds", type=float, nargs="?", default=15)
    args = ap.parse_args()

    if args.mode == "fan":
        set_fan(args.percent, quiet=False)
        return 0
    if args.mode == "telemetry":
        return telemetry(args.seconds)
    return {
        "index": mode_index,
        "beyond": mode_beyond,
        "wivrn": mode_wivrn,
        "off": mode_off,
        "quiesce": mode_quiesce,
        "status": mode_status,
        None: mode_status,
    }[args.mode]()


if __name__ == "__main__":
    sys.exit(main())
