#!/usr/bin/env python3
"""Pull, sync, and rebuild each machine in sequence over SSH.

The shared sudo password is read once and typed into sudo prompts as they
appear, so it never reaches a remote command line or file. Each step runs in a
pseudo-terminal passed through to this one: unexpected prompts can be answered
directly, and Ctrl-] detaches from a stuck step. Unreachable hosts are skipped
and reported as offline; any other failed step offers a menu to retry, open a
shell on the host, force the sync, continue, skip the host, or quit.

--channel points root's nixos channel at the named channel and updates it
before rebuilding. Frame also gets the matching system-manager branch as its
system-manager channel.
"""

from __future__ import annotations

import argparse
import getpass
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from sync_workflow import bold, cyan, dim, green, red, yellow

REPO_DIR = Path(__file__).resolve().parent
REMOTE_REPO = "~/nixos-configuration"
SSH_OPTIONS = ("-o", "ConnectTimeout=10")


@dataclass(frozen=True)
class Host:
    name: str
    user: str | None = None
    frame: bool = False

    @property
    def destination(self) -> str:
        return f"{self.user}@{self.name}" if self.user else self.name


HOSTS = (
    Host("jinroh"),
    Host("mindgame"),
    Host("paprika"),
    Host("patlabor"),
    Host("redline"),
    Host("frame", user="steamos", frame=True),
)
STEPS = ("connect", "pull", "sync", "channel", "rebuild")
OFFLINE = "offline"
SUCCESS_STATES = {"ok", "forced", OFFLINE}
CHANNEL_RE = re.compile(r"nixos-[a-z0-9][a-z0-9.-]*")
CHANNEL_BASE = "https://nixos.org/channels/"
SYSTEM_MANAGER_BASE = "https://github.com/numtide/system-manager/archive/"
# bootstrap.sh installs Nix here, outside sudo's PATH on SteamOS.
FRAME_NIX_CHANNEL = "/nix/var/nix/profiles/default/bin/nix-channel"


def channel_url(channel: str) -> str:
    if not CHANNEL_RE.fullmatch(channel):
        raise ValueError(f"Not a NixOS channel name: {channel!r}")
    return CHANNEL_BASE + channel


def system_manager_url(channel: str) -> str:
    """Map a NixOS channel to system-manager's branch for the same release.

    system-manager's main branch tracks nixos-unstable, and each release-YY.MM
    branch tracks nixos-YY.MM.
    """
    if match := re.fullmatch(r"nixos-(\d\d\.\d\d)(-small)?", channel):
        branch = f"release-{match.group(1)}"
    elif re.fullmatch(r"nixos-unstable(-small)?", channel):
        branch = "main"
    else:
        raise ValueError(f"No system-manager branch corresponds to {channel!r}")
    return f"{SYSTEM_MANAGER_BASE}{branch}.tar.gz"


def step_command(
    host: Host, step: str, *, action: str, force: bool = False, channel: str | None = None
) -> str:
    """Return the shell command for a step, run from the host's checkout."""
    if step == "connect":
        return "true"
    if step == "pull":
        return "git pull --ff-only"
    if step == "sync":
        return f"./sync.sh {host.name}" + (" --force" if force else "")
    if step == "channel":
        if channel is None:
            raise ValueError("The channel step needs a channel")
        if not host.frame:
            return (
                f"sudo nix-channel --add {channel_url(channel)} nixos"
                " && sudo nix-channel --update nixos"
            )
        nix_channel = f"sudo {FRAME_NIX_CHANNEL}"
        return (
            f"{nix_channel} --add {channel_url(channel)} nixos"
            f" && {nix_channel} --add {system_manager_url(channel)} system-manager"
            f" && {nix_channel} --update nixos system-manager"
        )
    if step == "rebuild":
        if host.frame:
            return f"frame/rebuild.sh {action}"
        # Building needs no root, and a root-owned ./result would be awkward.
        return "sudo nixos-rebuild switch" if action == "switch" else "nixos-rebuild build"
    raise ValueError(f"Unknown step: {step}")


def command_argv(
    host: Host, command: str, *, local: bool, forward_agent: bool = False, batch: bool = False
) -> list[str]:
    """Build argv that runs ``command`` in the host's checkout, locally or over SSH."""
    repo = shlex.quote(str(REPO_DIR)) if local else REMOTE_REPO
    script = f"cd {repo} && {command}"
    if local:
        return ["bash", "-c", script]
    # The remote login shell (fish on NixOS) parses this line. Fish treats
    # backslashes inside single quotes as escapes, so refuse them outright.
    if "\\" in script:
        raise ValueError(f"Backslashes are not portable across remote shells: {script!r}")
    options = ["-o", "BatchMode=yes"] if batch else ["-t"]
    if forward_agent:
        options.append("-A")
    return ["ssh", *options, *SSH_OPTIONS, host.destination, "--", f"bash -c {shlex.quote(script)}"]


def order_hosts(names: list[str] | None, local_name: str) -> list[Host]:
    """Select hosts in declaration order, moving the local machine last."""
    by_name = {host.name: host for host in HOSTS}
    if names:
        unknown = [name for name in names if name not in by_name]
        if unknown:
            raise ValueError(f"Unknown host(s): {', '.join(unknown)}; known: {', '.join(by_name)}")
        selected = [by_name[name] for name in dict.fromkeys(names)]
    else:
        selected = list(HOSTS)
    # Switching this machine mid-run could disturb the run itself.
    return sorted(selected, key=lambda host: host.name == local_name)


SUDO_PROMPT = re.compile(rb"\[sudo\] password for [^\r\n]*:\s*\Z")
SUDO_RETRY = b"Sorry, try again."
SYNC_PROMPT = b"Are these changes OK? (y/n) "
DETACH_KEY = b"\x1d"  # Ctrl-]


class PromptResponder:
    """Decide what to type in response to a step's output stream."""

    def __init__(self, password: str, *, auto_confirm: bool):
        self.password = password.encode()
        self.auto_confirm = auto_confirm
        self.bad_password = False
        self._tail = b""

    def feed(self, data: bytes) -> bytes:
        # Prompts can straddle reads, so match against a bounded rolling tail.
        self._tail = (self._tail + data)[-512:]
        if SUDO_RETRY in self._tail:
            # Abort rather than let sudo burn the remaining attempts.
            self.bad_password = True
            self._tail = b""
            return b"\x03"
        if SUDO_PROMPT.search(self._tail):
            self._tail = b""
            return self.password + b"\n"
        if self.auto_confirm and self._tail.endswith(SYNC_PROMPT):
            self._tail = b""
            # The sync prompt reads a single raw key on a TTY.
            return b"y"
        return b""


@dataclass(frozen=True)
class Outcome:
    ok: bool
    detail: str = ""
    bad_password: bool = False


def run_in_pty(argv: list[str], responder: PromptResponder) -> Outcome:
    """Run argv in a pseudo-terminal wired to ours, answering known prompts."""
    import pexpect

    size = shutil.get_terminal_size()
    child = pexpect.spawn(argv[0], argv[1:], dimensions=(size.lines, size.columns))

    detached = False

    def input_filter(data: bytes) -> bytes:
        nonlocal detached
        detached = detached or DETACH_KEY in data
        return data

    def output_filter(data: bytes) -> bytes:
        reply = responder.feed(data)
        if reply:
            child.send(reply)
        return data

    def resize(_signum, _frame):
        new = shutil.get_terminal_size()
        child.setwinsize(new.lines, new.columns)

    previous = signal.signal(signal.SIGWINCH, resize)
    try:
        child.interact(
            escape_character=DETACH_KEY.decode(),
            input_filter=input_filter,
            output_filter=output_filter,
        )
    finally:
        signal.signal(signal.SIGWINCH, previous)
    if detached:
        child.close(force=True)
        return Outcome(False, "detached", responder.bad_password)
    # interact() returns once the terminal closes, which can precede the
    # process exiting; wait for it rather than mistaking it for a detach.
    child.wait()
    child.close()
    if responder.bad_password:
        return Outcome(False, "sudo rejected the password", True)
    if child.signalstatus is not None:
        return Outcome(False, f"killed by signal {child.signalstatus}")
    if child.exitstatus:
        detail = f"exit status {child.exitstatus}"
        if child.exitstatus == 255 and argv[0] == "ssh":
            detail += " (SSH failure?)"
        return Outcome(False, detail)
    return Outcome(True)


class Quit(Exception):
    pass


@dataclass
class Session:
    action: str
    confirm_sync: bool
    local_name: str
    password: str
    run_step: Callable[[Session, Host, str, str], Outcome]
    open_shell: Callable[[Session, Host], None]
    choose: Callable[[str, dict[str, str]], str]
    ask_password: Callable[[], str]
    channel: str | None = None
    say: Callable[[str], None] = print
    results: dict[str, dict[str, str]] = field(default_factory=dict)


MENU = {
    "r": "retry",
    "s": "shell on host",
    "f": "force sync (back up conflicts)",
    "c": "continue to next step",
    "n": "skip rest of host",
    "q": "quit",
}


def menu_for(step: str) -> dict[str, str]:
    keys = {
        "pull": "rscnq",
        "sync": "rsfcnq",
        "channel": "rscnq",
        "rebuild": "rscnq",
    }[step]
    return {key: MENU[key] for key in keys}


def deploy_host(session: Session, host: Host) -> None:
    """Run every step for one host, consulting the operator on failures.

    An unreachable host is skipped without asking and reported as offline.
    """
    results = session.results.setdefault(host.name, {})
    local = host.name == session.local_name
    steps = [
        step
        for step in STEPS
        if not (local and step == "connect") and (step != "channel" or session.channel)
    ]
    index, force = 0, False
    while index < len(steps):
        step = steps[index]
        command = step_command(
            host, step, action=session.action, force=force, channel=session.channel
        )
        session.say(bold(cyan(f"\n==> {host.destination}: {step}")) + dim(f"  ({command})"))
        outcome = session.run_step(session, host, step, command)
        if outcome.bad_password:
            session.say(red("sudo rejected the password; enter it again."))
            session.password = session.ask_password()
            continue
        if outcome.ok:
            results[step] = "forced" if force else "ok"
            index, force = index + 1, False
            continue
        if step == "connect":
            # Offline machines are expected; report them rather than asking.
            session.say(yellow(f"{host.destination}: {outcome.detail}; skipping"))
            results[step] = OFFLINE
            return
        session.say(red(f"{host.destination}: {step} failed: {outcome.detail}"))
        while True:
            choice = session.choose(f"{host.destination} {step}", menu_for(step))
            if choice != "s":
                break
            session.open_shell(session, host)
        if choice == "r":
            continue
        if choice == "f":
            force = True
        elif choice == "c":
            results[step] = f"failed ({outcome.detail}), continued"
            index, force = index + 1, False
        elif choice == "n":
            results[step] = f"failed ({outcome.detail})"
            for rest in steps[index + 1 :]:
                results[rest] = "skipped"
            return
        elif choice == "q":
            results[step] = f"failed ({outcome.detail})"
            raise Quit


def default_run_step(session: Session, host: Host, step: str, command: str) -> Outcome:
    local = host.name == session.local_name
    if step == "connect":
        argv = command_argv(host, command, local=False, batch=True)
        completed = subprocess.run(argv, stdin=subprocess.DEVNULL)
        return Outcome(completed.returncode == 0, f"unreachable (exit {completed.returncode})")
    responder = PromptResponder(
        session.password, auto_confirm=step == "sync" and not session.confirm_sync
    )
    argv = command_argv(host, command, local=local, forward_agent=step == "pull")
    return run_in_pty(argv, responder)


def default_open_shell(session: Session, host: Host) -> None:
    session.say(dim("Exit the shell to return to the menu."))
    if host.name == session.local_name:
        subprocess.run([shutil.which("fish") or "bash"], cwd=REPO_DIR)
    else:
        subprocess.run(command_argv(host, "exec $SHELL -l", local=False))


def default_choose(prompt: str, options: dict[str, str]) -> str:
    listing = "  ".join(f"[{key}] {label}" for key, label in options.items())
    while True:
        try:
            answer = input(f"{yellow(prompt)}: {listing}\n> ").strip().lower()
        except EOFError:
            return "q"
        if answer in options:
            return answer


def url_exists(url: str) -> str | None:
    """Return None if url answers a HEAD request, or the reason it does not."""
    # curl uses the system CA bundle, which uv's standalone Python does not find.
    completed = subprocess.run(
        ["curl", "--fail", "--silent", "--show-error", "--head", "--location"]
        + ["--max-time", "15", "--output", "/dev/null", url],
        capture_output=True,
        text=True,
    )
    if completed.returncode == 0:
        return None
    return completed.stderr.strip() or f"curl exit {completed.returncode}"


def check_channel(channel: str) -> None:
    """Fail early on a misspelt or retired channel, before touching any machine."""
    for label, url in (
        (channel, channel_url(channel)),
        ("system-manager's matching branch", system_manager_url(channel)),
    ):
        if reason := url_exists(url):
            raise ValueError(f"{label} is not available at {url}: {reason}")


def ask_password() -> str:
    return getpass.getpass("Shared sudo password: ")


def password_works(password: str) -> bool:
    """Check the password against this machine's sudo, ignoring cached credentials."""
    completed = subprocess.run(
        ["sudo", "-k", "-S", "-p", "", "-v"],
        input=password + "\n",
        text=True,
        stderr=subprocess.DEVNULL,
    )
    return completed.returncode == 0


def local_repo_warnings() -> list[str]:
    """Report local state that would not reach remote hosts via the pull."""
    status = subprocess.run(
        ["git", "-C", str(REPO_DIR), "status", "--porcelain=v2", "--branch"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()
    warnings = []
    for line in status:
        match = re.match(r"# branch\.ab \+(\d+) -\d+", line)
        if match and int(match.group(1)):
            warnings.append(f"{match.group(1)} local commit(s) not pushed to the upstream")
    if any(not line.startswith("#") for line in status):
        warnings.append("uncommitted changes in the local checkout")
    return warnings


def print_summary(session: Session, say: Callable[[str], None] = print) -> None:
    say(bold("\nSummary"))
    for name, steps in session.results.items():
        if steps == {"connect": OFFLINE}:
            say(f"  {name}: {yellow(OFFLINE)}")
            continue
        parts = []
        for step, state in steps.items():
            if state in {"ok", "forced"}:
                color = green
            elif state == "skipped":
                color = dim
            else:
                color = red
            parts.append(f"{step} {color(state)}")
        say(f"  {name}: " + ", ".join(parts))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("hosts", nargs="*", help=f"subset of: {' '.join(h.name for h in HOSTS)}")
    parser.add_argument(
        "--build", action="store_true", help="build instead of switching (sync still applies)"
    )
    parser.add_argument(
        "--confirm-sync", action="store_true", help="answer each sync confirmation yourself"
    )
    parser.add_argument(
        "--channel",
        metavar="NAME",
        help="switch every machine to this channel (e.g. nixos-26.05) and update it first",
    )
    args = parser.parse_args(argv)
    if args.channel:
        if args.build:
            parser.error("--channel persists, so it cannot be combined with --build")
        try:
            check_channel(args.channel)
        except ValueError as exc:
            parser.error(str(exc))
    local_name = socket.gethostname()
    try:
        hosts = order_hosts(args.hosts, local_name)
    except ValueError as exc:
        parser.error(str(exc))

    warnings = local_repo_warnings()
    if warnings:
        for warning in warnings:
            print(yellow(f"Warning: {warning}"))
        if input("Remote hosts will not see these. Continue? (y/n) ").strip().lower() != "y":
            return 1

    password = ask_password()
    if any(host.name == local_name for host in HOSTS):
        while not password_works(password):
            print(red("Incorrect password."))
            password = ask_password()

    print(dim("Order: " + " -> ".join(host.destination for host in hosts)))
    print(dim("Ctrl-] detaches from a running step."))
    if args.channel:
        print(dim(f"Switching every machine to {args.channel}."))
    session = Session(
        action="build" if args.build else "switch",
        channel=args.channel,
        confirm_sync=args.confirm_sync,
        local_name=local_name,
        password=password,
        run_step=default_run_step,
        open_shell=default_open_shell,
        choose=default_choose,
        ask_password=ask_password,
    )
    try:
        for host in hosts:
            deploy_host(session, host)
    except (Quit, KeyboardInterrupt):
        print(yellow("\nStopped."))
    print_summary(session)
    failed = any(
        state not in SUCCESS_STATES
        for steps in session.results.values()
        for state in steps.values()
    )
    return 1 if failed or len(session.results) < len(hosts) else 0


if __name__ == "__main__":
    sys.exit(main())
