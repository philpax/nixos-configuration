#!/usr/bin/env python3
"""Inspect-only by default, bounded scenarios for a separately approved Frame trial.

Run on the device, not through an SSH client. No normal-home installation, SSH
connection, credentials, assistant executable, GC, sudo, or system mutation is
part of this helper. The scenario root must be a new named child of TRIAL_ROOT.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pty
import re
import select
import shlex
import signal
import stat
import subprocess
import tarfile
import time
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

TRIAL_ROOT = Path("/home/steamos/.local/share/frame-cli-smoke-20261007")
STEEL_SUBMODULES = ("steel-cogs/forest", "steel-cogs/glyph", "steel-cogs/notify")
# Source roots, not a copy of the checkout or the user's dotfiles/state.
SOURCE_ALLOWLIST = (
    "frame",
    "sync.py",
    "home_sync.py",
    "common-all/packages",
    "common-dev/packages",
    "common-desktop/packages/fonts.nix",
    "common-all/overlays/helix-steel.nix",
    "common-all/dotfiles/.gitconfig",
    "common-all/dotfiles/.config/fish",
    "common-all/dotfiles/.config/helix",
    "common-all/dotfiles/.config/zellij",
    "common-dev/dotfiles/.config/fish",
    "common-all/dotfiles/.config/nixpkgs/config.nix",
    "common-all/dotfiles/.config/polytoken",
    "common-all/dotfiles/.claude/CLAUDE.md",
    "common-all/dotfiles/.claude/settings.json",
    "common-dev/dotfiles/.config/makima",
    "common-dev/dotfiles/.agents/skills",
    "common-dev/dotfiles/.claude-plugins",
    "common-desktop/dotfiles/.config/inlyne",
    "common-dev-desktop/dotfiles/.config/fish",
    "common-dev-desktop/dotfiles/.config/alacritty",
    "common-dev-desktop/dotfiles/.config/ghostty",
    "common-dev-desktop/dotfiles/.config/niri",
    "common-dev-desktop/dotfiles/.config/quickshell",
    "common-dev-desktop/dotfiles/.config/anyrun",
    "common-dev-desktop/dotfiles/.config/fuzzel",
    "common-dev-desktop/dotfiles/.config/mako",
    "common-dev-desktop/dotfiles/.config/swaylock",
    "common-dev-desktop/dotfiles/.config/sunsetr",
    "common-dev-desktop/dotfiles/.local/bin/audio-action.sh",
    "common-dev-desktop/dotfiles/.local/bin/window-action.sh",
    "common-dev-desktop/dotfiles/.local/bin/record-screen.sh",
    "common-dev-desktop/dotfiles/.local/bin/niri-sync-workspaces.py",
    "common-dev-desktop/dotfiles/.local/bin/panel-backlight",
    "tests/frame_device_scenarios.py",
    "tests/device_report.py",
    "tests/ssh_transport.py",
    "tests/host_fontconfig.py",
    "tests/terminal_scenarios.py",
    ".gitmodules",
)
FORBIDDEN_PARTS = {
    ".git",
    ".ssh",
    ".gnupg",
    ".aws",
    ".cache",
    "__pycache__",
    ".pytest_cache",
    ".ruff_cache",
    ".venv",
    "node_modules",
    "target",
    "auth",
    "credentials",
    "tokens",
    "state",
    "saved-state",
}
FORBIDDEN_NAMES = {".env", ".sync-state.json", "auth.json", "credentials.json", "token.json"}


class ScenarioError(RuntimeError):
    pass


def source_path_allowed(relative):
    path = PurePosixPath(relative)
    if path.is_absolute() or ".." in path.parts:
        return False
    if any(part.lower() in FORBIDDEN_PARTS for part in path.parts):
        return False
    if path.name.lower() in FORBIDDEN_NAMES or path.suffix.lower() in (".pem", ".key", ".pyc"):
        return False
    if re.search(r"(^|[._-])(credential|secret|token|auth)([._-]|$)", path.name, re.I):
        return False
    return any(
        path == PurePosixPath(root) or PurePosixPath(root) in path.parents
        for root in (*SOURCE_ALLOWLIST, *STEEL_SUBMODULES)
    )


def _git(repository, *args):
    result = subprocess.run(
        ["git", "-C", str(repository), *args],
        capture_output=True,
        check=True,
        timeout=20,
        env={**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull},
    )
    return result.stdout.decode().strip()


def checked_steel_files(repository):
    """Only clean, initialized gitlinks at the superproject's recorded commits."""
    files = []
    for relative in STEEL_SUBMODULES:
        entry = _git(repository, "ls-files", "--stage", "--", relative).split()
        if len(entry) != 4 or entry[0] != "160000" or entry[2] != "0":
            raise ScenarioError(f"Steel source is not a recorded gitlink: {relative}")
        submodule = repository / relative
        if submodule.is_symlink() or not submodule.is_dir():
            raise ScenarioError(f"Steel submodule is not checked out: {relative}")
        if _git(submodule, "rev-parse", "HEAD") != entry[1]:
            raise ScenarioError(f"Steel submodule commit differs from recorded gitlink: {relative}")
        if _git(submodule, "status", "--porcelain", "--untracked-files=all"):
            raise ScenarioError(f"Steel submodule is dirty: {relative}")
        for item in _git(submodule, "ls-files", "-z").split("\0"):
            if item:
                files.append(repository / relative / item)
    return files


def source_files(repository, *, include_steel=True):
    repository = Path(repository).resolve(strict=True)
    selected = []
    for relative in SOURCE_ALLOWLIST:
        source = repository / relative
        if not source.exists() and not source.is_symlink():
            continue
        if source.is_symlink():
            raise ScenarioError(f"Source symlink is not allowed: {relative}")
        if source.is_file():
            selected.append(source)
        else:
            for directory, dirs, names in os.walk(source, followlinks=False):
                parent = Path(directory)
                for name in list(dirs):
                    item = parent / name
                    rel = item.relative_to(repository)
                    if item.is_symlink():
                        raise ScenarioError(f"Source directory symlink is not allowed: {rel}")
                    if not source_path_allowed(str(rel)):
                        dirs.remove(name)
                selected.extend(parent / name for name in names)
    if include_steel:
        selected.extend(checked_steel_files(repository))
    result = []
    for path in sorted(set(selected)):
        relative = path.relative_to(repository)
        if not source_path_allowed(str(relative)):
            continue
        if path.is_symlink() or not stat.S_ISREG(path.lstat().st_mode):
            raise ScenarioError(f"Only regular source bytes can be staged: {relative}")
        if not path.resolve().is_relative_to(repository):
            raise ScenarioError(f"Source escapes repository: {relative}")
        result.append(path)
    return result


def stage_source_archive(repository, destination, *, include_steel=True):
    """Create a new regular-file tar; inspect its manifest before any transfer."""
    repository = Path(repository).resolve(strict=True)
    files = source_files(repository, include_steel=include_steel)
    destination = Path(destination)
    manifest = []
    total_size = sum(source.stat().st_size for source in files)
    if len(files) > 4096 or total_size > 32 * 1024 * 1024:
        raise ScenarioError("Source archive exceeds the bounded 4096-file/32-MiB budget")
    with destination.open("xb") as output, tarfile.open(fileobj=output, mode="w:gz") as archive:
        for source in files:
            relative = str(source.relative_to(repository))
            data = source.read_bytes()
            manifest.append({"path": relative, "sha256": hashlib.sha256(data).hexdigest()})
            info = tarfile.TarInfo(relative)
            info.size = len(data)
            info.mode = 0o755 if os.access(source, os.X_OK) else 0o644
            import io

            archive.addfile(info, io.BytesIO(data))
    return manifest


@dataclass(frozen=True)
class TrialPaths:
    trial: Path
    root: Path
    home: Path
    state: Path
    checkout: Path
    work: Path

    @classmethod
    def create(cls, trial_root, name):
        trial = Path(trial_root)
        if trial != TRIAL_ROOT or ".." in trial.parts:
            raise ScenarioError(f"Explicit trial root must be {TRIAL_ROOT}")
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,7}", name):
            raise ScenarioError(
                "Scenario name must be 1-8 safe characters (Unix agent socket bound)"
            )
        # Do not follow a redirected existing trial or scenario component.
        for part in (trial, *trial.parents):
            if part.is_symlink():
                raise ScenarioError(f"Trial parent is a symlink: {part}")
        root = trial / ("scenario-" + name)
        if root.is_symlink():
            raise ScenarioError("Scenario root must not be a symlink")
        home = root / "home"
        return cls(trial, root, home, home / "state", root / "checkout", root / "work")

    def check(self, path):
        path = Path(path)
        if not path.is_absolute() or ".." in path.parts or not path.is_relative_to(self.root):
            raise ScenarioError(f"Scenario write escapes named test root: {path}")
        for part in (path, *path.parents):
            if part == self.trial:
                break
            if part.is_symlink():
                raise ScenarioError(f"Scenario control path is a symlink: {part}")
        return path

    def initialize(self):
        if self.root.exists():
            raise ScenarioError(
                "Use a new scenario name; existing trial state is never overwritten"
            )
        if not self.trial.is_dir() or self.trial.stat().st_uid != os.getuid():
            raise ScenarioError("Trial root must already exist and be owned by the current user")
        self.root.mkdir(mode=0o700)
        for path in (self.home, self.checkout, self.work):
            path.mkdir(mode=0o700)

    def unpack(self, archive):
        with tarfile.open(archive) as source:
            members = source.getmembers()
            if (
                len(members) > 4096
                or sum(member.size for member in members) > 32 * 1024 * 1024
                or len({member.name for member in members}) != len(members)
            ):
                raise ScenarioError("Source archive exceeds budget or contains duplicate paths")
            for member in members:
                if not member.isfile() or not source_path_allowed(member.name):
                    raise ScenarioError(f"Unapproved source archive member: {member.name}")
                self.check(self.checkout / member.name)
            source.extractall(self.checkout, members=members, filter="data")


@dataclass(frozen=True)
class Command:
    argv: tuple[str, ...]
    timeout: int = 120
    input: bytes = b""


class DeviceRunner:
    """Argument-array runner for commands within an explicit isolated home/state."""

    def __init__(self, paths, *, execute=False):
        self.paths = paths
        self.execute = execute
        self.commands = []
        self.env = {
            "HOME": str(paths.home),
            "XDG_CONFIG_HOME": str(paths.home / ".config"),
            "XDG_DATA_HOME": str(paths.home / ".local/share"),
            "XDG_STATE_HOME": str(paths.home / ".local/state"),
            "XDG_CACHE_HOME": str(paths.home / ".cache"),
            "TMPDIR": str(paths.root / "tmp"),
            "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color",
            "LANG": "C.UTF-8",
            "FRAME_CLI_NO_AUTO": "1",
        }

    def cli(self, *args, timeout=120, input=b""):
        return Command(
            (
                "/usr/bin/python3",
                str(self.paths.checkout / "frame/cli.py"),
                "--home",
                str(self.paths.home),
                "--state-dir",
                str(self.paths.state),
                *map(str, args),
            ),
            timeout,
            input,
        )

    def enter(self, *args, timeout=120):
        return self.cli("enter", "--", *args, timeout=timeout)

    def run(self, command, *, expected=0):
        self.commands.append(command)
        if not self.execute:
            return None
        # This helper never inherits auth sockets, agent metadata, or Nix overrides.
        self.paths.check(self.paths.root / "tmp").mkdir(exist_ok=True, mode=0o700)
        process = subprocess.Popen(
            command.argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.env,
            cwd=self.paths.work,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(command.input, timeout=command.timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise ScenarioError(
                f"Scenario timed out after {command.timeout}s: {command.argv}"
            ) from None
        if expected is not None and process.returncode != expected:
            raise ScenarioError(
                f"Scenario exited {process.returncode}, expected {expected}: {command.argv}\n"
                + stderr.decode(errors="replace")[-3000:]
            )
        return subprocess.CompletedProcess(command.argv, process.returncode, stdout, stderr)

    def fixture(self, relative, content):
        path = self.paths.check(self.paths.work / relative)
        if self.execute:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        return path

    def pty(self, command, exchanges, *, timeout=45):
        """Wait for observable output before each input; kill all descendants on timeout."""
        self.commands.append(command)
        if not self.execute:
            return b""
        master, slave = pty.openpty()
        import fcntl
        import termios

        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        env = dict(self.env)
        env.pop("FRAME_CLI_NO_AUTO", None)
        process = subprocess.Popen(
            command.argv,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            cwd=self.paths.work,
            preexec_fn=controlling_terminal,
        )
        os.close(slave)
        if command.input:
            os.write(master, command.input + b"\x04")
        transcript = bytearray()
        deadline = time.monotonic() + timeout
        try:
            for pattern, data in exchanges:
                start = len(transcript)
                while (
                    re.search(
                        pattern,
                        re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", bytes(transcript[start:])),
                    )
                    is None
                ):
                    if time.monotonic() >= deadline:
                        raise ScenarioError(
                            f"PTY expected {pattern!r}; tail: {transcript[-2000:]!r}"
                        )
                    if select.select([master], [], [], 0.2)[0]:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            chunk = b""
                        if not chunk:
                            raise ScenarioError(f"PTY exited before expected {pattern!r}")
                        transcript.extend(chunk)
                os.write(master, data)
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise ScenarioError("PTY exit timed out")
                if select.select([master], [], [], 0.2)[0]:
                    try:
                        transcript.extend(os.read(master, 65536))
                    except OSError:
                        break
            process.wait(timeout=max(1, deadline - time.monotonic()))
            if process.returncode:
                raise ScenarioError(f"PTY exited {process.returncode}: {transcript[-2000:]!r}")
            return bytes(transcript)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            os.close(master)

    def exact_commands(self):
        return [shlex.join(command.argv) for command in self.commands]


def frame_fish_and_subprocess_scenario(runner):
    argv = ["space argument", "$HOME;literal", "'quoted'", ""]
    check = "import json,sys; print(json.dumps(sys.argv[1:]))"
    result = runner.run(runner.enter("python3", "-c", check, *argv))
    if result:
        assert json.loads(result.stdout) == argv
    runner.run(runner.enter("python3", "-c", "import sys; sys.exit(37)"), expected=37)
    fish = (
        "functions -q fish_prompt; or exit 41; functions -q aicmd; or exit 42; "
        "functions -q gfp; or exit 43; test $HOME = "
        + shlex.quote(str(runner.paths.home))
        + "; or exit 44; test $STEEL_HOME = $HOME/.config/steel; or exit 45; "
        'python3 -c \'import subprocess; subprocess.run(["node", "-e", '
        '"process.stdout.write(String(6*7))"],check=True)\'; or exit 46; '
        "printf '\\nFISH-SHARED-CONFIG-OK\\n'"
    )
    result = runner.run(runner.enter("fish", "-i", "-c", fish))
    if result:
        assert b"42\nFISH-SHARED-CONFIG-OK" in result.stdout
    runner.pty(
        runner.cli("enter"),
        [(rb"> ", b"printf 'FRESH-FISH-OK\\n'\r"), (rb"FRESH-FISH-OK\r?\n", b"exit\r")],
    )


def frame_terminal_workflow_scenario(runner):
    c = runner.fixture(
        "openssl-test.c",
        "#include <openssl/crypto.h>\n#include <stdio.h>\n"
        "int main(void) { puts(OpenSSL_version(OPENSSL_VERSION)); return 0; }\n",
    )
    out = runner.paths.work / "openssl-test"
    script = (
        "set -eu; pkg-config --exists openssl; "
        f"cc {shlex.quote(str(c))} -o {shlex.quote(str(out))} "
        "$(pkg-config --cflags --libs openssl); "
        f"{shlex.quote(str(out))}; gcc --version; clang --version; "
        "python3 -c 'import subprocess; "
        'subprocess.run(["node","-e","console.log(42)"],check=True)\''
    )
    runner.run(runner.enter("bash", "--noprofile", "--norc", "-c", script))
    runner.fixture(
        "direnv/shell.nix",
        "{ pkgs ? import <nixpkgs> {} }: pkgs.mkShell {\n"
        '  packages = [ pkgs.hello ]; FRAME_DIRENV_SENTINEL = "frame-direnv-ok";\n}\n',
    )
    project = runner.fixture("direnv/.envrc", "use nix\n").parent
    fish = (
        f"cd {shlex.quote(str(project))}; direnv allow; or exit 51; "
        "direnv export fish | source; test $FRAME_DIRENV_SENTINEL = frame-direnv-ok; or exit 52; "
        "hello; or exit 53; printf 'DIRENV-NIX-OK\\n'"
    )
    result = runner.run(runner.enter("fish", "-i", "-c", fish), expected=0)
    if result:
        assert b"DIRENV-NIX-OK" in result.stdout
    repo = runner.paths.work / "git-project"
    git_script = (
        f"set -eu; mkdir -p {shlex.quote(str(repo))}; cd {shlex.quote(str(repo))}; "
        "git init -q; git -c user.name=FrameTest -c user.email=test@invalid "
        "-c commit.gpgsign=false commit --allow-empty -qm synthetic; "
        "printf 'one\\n' > example; git add example; "
        "git -c user.name=FrameTest -c user.email=test@invalid -c commit.gpgsign=false "
        "commit -qm fixture; printf 'two\\n' > example; "
        "git --no-pager diff --no-ext-diff | delta --paging=never"
    )
    runner.run(runner.enter("bash", "--noprofile", "--norc", "-c", git_script))


def active_profile_identity(result):
    data = json.loads(result.stdout)
    assert data["ready"], data
    return {key: data[key] for key in ("profile", "generation", "build_info")}


def frame_profile_rollback_scenario(runner):
    before = runner.run(runner.cli("status"))
    invalid = runner.fixture(
        "invalid-overrides.nix",
        '{ pkgs, cliPackages, fontPackages }: throw "intentional-frame-test-update-failure"\n',
    )
    result = runner.run(
        runner.cli("update", "--overrides", str(invalid), timeout=3600), expected=None
    )
    after = runner.run(runner.cli("status"))
    if result:
        assert result.returncode != 0, "invalid override unexpectedly published"
        assert active_profile_identity(before) == active_profile_identity(after), (
            "failed update changed the active profile or its build information"
        )
    override = runner.fixture(
        "overrides.nix",
        "{ pkgs, cliPackages, fontPackages }: {\n"
        "  cliPackages = cliPackages ++ [ pkgs.hello ]; inherit fontPackages;\n}\n",
    )
    # An explicit source override uses the same tested pin: no invented revision.
    pin = runner.paths.checkout / "frame/nixpkgs.json"
    runner.run(
        runner.cli("update", "--nixpkgs-pin", str(pin), "--overrides", str(override), timeout=7200)
    )
    result = runner.run(runner.enter("hello"))
    if result:
        assert b"Hello" in result.stdout
    updated = runner.run(runner.cli("status"))
    runner.run(runner.cli("rollback", timeout=1800))
    restored = runner.run(runner.cli("status"))
    if restored:
        assert active_profile_identity(updated) != active_profile_identity(restored), (
            "rollback did not restore distinct build information"
        )
        assert active_profile_identity(before) == active_profile_identity(restored), (
            "rollback did not restore the original profile and build information"
        )


def frame_ssh_agent_scenario(runner):
    """Explicit temporary-key signing, no endpoint authentication; always stop owned agent."""
    key = runner.paths.work / "agent-test-key"
    data = runner.fixture("agent-message", "synthetic agent signing fixture\n")
    try:
        runner.pty(
            runner.cli("enter"),
            [
                (rb"> ", b"printf 'AGENT-READY:%s\\n' $SSH_AUTH_SOCK\r"),
                (rb"AGENT-READY:[^\r\n]+", b"exit\r"),
            ],
        )
        result = runner.run(runner.cli("agent", "status"))
        if runner.execute:
            status = json.loads(result.stdout)
            socket = status["socket"]
            assert Path(socket).is_relative_to(runner.paths.root)
            assert stat.S_ISSOCK(Path(socket).stat().st_mode)
            assert Path(socket).stat().st_uid == os.getuid()
        else:
            socket = str(runner.paths.state / "agent/agent.sock")
        runner.run(runner.enter("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)))
        runner.run(runner.enter("env", "SSH_AUTH_SOCK=" + socket, "ssh-add", str(key)))
        runner.run(runner.enter("env", "SSH_AUTH_SOCK=" + socket, "ssh-add", "-l"))
        runner.run(Command(("/usr/bin/env", "SSH_AUTH_SOCK=" + socket, "/usr/bin/ssh-add", "-l")))
        runner.run(
            runner.enter(
                "env",
                "SSH_AUTH_SOCK=" + socket,
                "ssh-keygen",
                "-Y",
                "sign",
                "-f",
                str(key) + ".pub",
                "-n",
                "frame-test",
                str(data),
            )
        )
        signature = str(data) + ".sig"
        check = runner.enter(
            "ssh-keygen", "-Y", "check-novalidate", "-n", "frame-test", "-s", signature
        )
        runner.pty(Command(check.argv, input=b"synthetic agent signing fixture\n"), [])
    finally:
        runner.run(runner.cli("agent", "stop"))
        if runner.execute:
            for path in (key, Path(str(key) + ".pub"), Path(str(data) + ".sig")):
                runner.paths.check(path).unlink(missing_ok=True)


def frame_helix_forest_scenario(runner):
    runner.fixture("forest-test.rs", 'fn main() { println!("frame"); }\n')
    runner.fixture("forest-visible-marker/fixture", "synthetic forest tree marker\n")
    python = runner.fixture("forest-test.py", 'print("frame-python")\n')
    provenance = runner.run(runner.cli("status"))
    if provenance:
        packages = json.loads(provenance.stdout)["build_info"]["cliPackages"]
        assert any(
            item["name"].startswith("helix-") and "-steel-8d189f4" in item["name"]
            for item in packages
        ), "the default profile must retain pinned Steel Helix; no upstream substitute is allowed"
    runner.run(runner.enter("fish", "-l", "-c", "exec hx $argv", "--", "--health"))
    transcript = runner.pty(
        runner.enter(
            "fish", "-l", "-c", "exec hx $argv", "--", str(runner.paths.work / "forest-test.rs")
        ),
        [
            (rb"forest-test\.rs", b":forest-open\r"),
            (rb"forest-visible-marker", b"q"),
            (rb"forest-test\.rs", b":open " + str(python).encode() + b"\r"),
            (rb"forest-test\.py", b":quit!\r"),
        ],
    )
    if runner.execute:
        text = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", transcript)
        assert not re.search(rb"(?i)(unknown command|error|exception|query.*fail|unbound)", text), (
            text
        )
        assert b"forest-test.rs" in text and b"forest-test.py" in text
        assert provenance is not None
        log = runner.paths.home / ".cache/helix/helix.log"
        if log.exists():
            assert not re.search(
                rb"(?i)(failed.*(query|highlights)|steel.*error|unbound|exception)",
                log.read_bytes(),
            ), log.read_bytes()[-3000:]
    # Never accept a host/upstream hx fallback. This command resolves hx only
    # through managed entry and requires shared forest command success.


def build_scenario_commands(runner, *, agents=False):
    runner.run(runner.cli("install", timeout=14400))
    runner.run(runner.cli("activate", "--dry-run"))
    runner.pty(runner.cli("activate", input=b"y\n"), [], timeout=1800)
    if runner.execute:
        import sys

        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from ssh_transport import ssh_file_transfer_startup_scenario

        ssh_file_transfer_startup_scenario(
            runner.paths.root / "transport", rc=(runner.paths.home / ".bashrc").read_bytes()
        )
    frame_fish_and_subprocess_scenario(runner)
    frame_terminal_workflow_scenario(runner)
    frame_profile_rollback_scenario(runner)
    frame_helix_forest_scenario(runner)
    if agents:
        frame_ssh_agent_scenario(runner)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trial-root", required=True, type=Path)
    parser.add_argument("--name", required=True)
    parser.add_argument("--source-archive", type=Path)
    parser.add_argument(
        "--agents", action="store_true", help="test owned agent with a temporary key"
    )
    parser.add_argument(
        "--execute", action="store_true", help="write/run only in the named synthetic root"
    )
    parser.add_argument(
        "--archive-source", type=Path, help="local source root to archive, no execution"
    )
    parser.add_argument("--archive-output", type=Path)
    args = parser.parse_args(argv)
    paths = TrialPaths.create(args.trial_root, args.name)
    if args.archive_source:
        if args.execute or not args.archive_output:
            parser.error("archive mode requires --archive-output and cannot execute")
        print(json.dumps(stage_source_archive(args.archive_source, args.archive_output), indent=2))
        return 0
    runner = DeviceRunner(paths, execute=args.execute)
    if args.execute:
        if not args.source_archive:
            parser.error("--execute requires an explicit source archive")
        archive = args.source_archive
        if (
            not archive.is_absolute()
            or ".." in archive.parts
            or archive.is_symlink()
            or not archive.resolve().is_relative_to(paths.trial)
        ):
            parser.error("execution source archive must be a regular file beneath the trial root")
        paths.initialize()
        paths.unpack(archive)
    try:
        build_scenario_commands(runner, agents=args.agents)
    finally:
        if args.execute:
            runner.run(runner.cli("agent", "stop"))
    if not args.execute:
        print(
            json.dumps(
                {
                    "home": str(paths.home),
                    "state": str(paths.state),
                    "commands": runner.exact_commands(),
                },
                indent=2,
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
