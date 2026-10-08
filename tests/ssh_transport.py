#!/usr/bin/env python3
"""Local OpenSSH protocol adapter: synthetic Bash startup, no SSH connection.

Only the harness host and known SCP/SFTP/command arguments are accepted. Clients
and actual server executables inherit the same byte streams through exec; this
is not an authentication, encryption, or sshd integration test.
"""

from __future__ import annotations

import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

HOST = "frame-test.invalid"
CONFIG_ENV = "FRAME_TEST_TRANSPORT_CONFIG"
SSH_OPTIONS = {
    "ForwardX11=no",
    "ForwardAgent=no",
    "PermitLocalCommand=no",
    "ClearAllForwardings=yes",
    "RemoteCommand=none",
    "RequestTTY=no",
    "BatchMode=yes",
    "ControlMaster=no",
}


@dataclass(frozen=True)
class ProcessResult:
    returncode: int
    stdout: bytes
    stderr: bytes


def bounded_process(argv, *, env=None, input=b"", timeout=20, cwd=None):
    """Bound a complete process group, including transport/server descendants."""
    process = subprocess.Popen(
        list(map(str, argv)),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        cwd=cwd,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(input, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise
    return ProcessResult(process.returncode, stdout, stderr)


def find_sftp_server():
    """Locate the server from the installed OpenSSH package, never download it."""
    candidates = [shutil.which("sftp-server")]
    scp = shutil.which("scp")
    if scp:
        package = Path(scp).resolve().parent.parent
        candidates.extend(
            str(package / part) for part in ("libexec/sftp-server", "lib/ssh/sftp-server")
        )
    candidates.extend(("/usr/lib/openssh/sftp-server", "/usr/libexec/sftp-server"))
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return str(Path(candidate).resolve())
    raise FileNotFoundError("actual OpenSSH sftp-server is required for protocol validation")


def parse_transport_args(argv, config):
    """Accept precisely the transport subset used by the real test clients."""
    args = list(argv)
    subsystem = False
    while args and args[0].startswith("-"):
        option = args.pop(0)
        if option == "--":
            break
        if option in ("-x", "-T", "-q"):
            continue
        if option == "-s":
            subsystem = True
            continue
        allowed_options = {item.lower() for item in SSH_OPTIONS}
        if option == "-o":
            if not args or "=".join(args.pop(0).split()).lower() not in allowed_options:
                raise ValueError("unsupported SSH option")
            continue
        if option.startswith("-o") and "=".join(option[2:].split()).lower() in allowed_options:
            continue
        raise ValueError(f"unsupported transport option: {option}")
    if not args or args.pop(0) != HOST:
        raise ValueError("only the synthetic harness host is allowed")
    if subsystem:
        if args != ["sftp"]:
            raise ValueError("only the sftp subsystem is allowed")
        return [config["sftp_server"], "-d", config["root"]]
    if args == ["frame-test-command"]:
        return [sys.executable, "-c", config["command_python"]]
    words = shlex.split(" ".join(args))
    if len(words) != 3 or words[0] != "scp" or words[1] not in ("-t", "-f"):
        raise ValueError("only bounded scp -t/-f commands are allowed")
    target = Path(words[2])
    root = Path(config["root"]).resolve()
    if not target.is_absolute() or not target.resolve().is_relative_to(root):
        raise ValueError("SCP target must be beneath the synthetic root")
    return [config["scp"], words[1], str(target)]


def adapter_main(argv):
    config = json.loads(Path(os.environ[CONFIG_ENV]).read_text())
    command = parse_transport_args(argv, config)
    home = Path(config["home"]).resolve()
    root = Path(config["root"]).resolve()
    if not home.is_relative_to(root) or not home.is_dir():
        raise ValueError("synthetic HOME must be beneath the fixture root")
    env = {
        "HOME": str(home),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "LANG": "C.UTF-8",
        "LC_ALL": "C",
        "BASH_ENV": str(home / "startup.bash"),
        "FRAME_CLI_NO_AUTO": "1",
    }
    # Bash's sshd .bashrc detection is version/build-specific. BASH_ENV makes
    # synthetic noninteractive .bashrc sourcing explicit and deterministic.
    script = "exec " + shlex.join(command)
    os.chdir(root)
    os.execve(config["bash"], [config["bash"], "--noprofile", "--norc", "-c", script], env)


class SyntheticTransport:
    """Create an isolated startup fixture and run real clients against it.

    The optional rc bytes may include the generated production hook, but must
    reference only synthetic state. The default fixture has an interactive-only
    sentinel which must never appear in a noninteractive protocol session.
    """

    def __init__(self, root: Path, *, rc: bytes | None = None, noisy=False):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=False)
        self.home = self.root / "home"
        self.home.mkdir()
        self.scp = shutil.which("scp")
        self.sftp = shutil.which("sftp")
        self.bash = shutil.which("bash")
        if not all((self.scp, self.sftp, self.bash)):
            raise FileNotFoundError("real bash, scp, and sftp clients are required")
        self.server = find_sftp_server()
        self.adapter = self.root / "ssh-adapter"
        shutil.copyfile(__file__, self.adapter)
        self.adapter.chmod(0o700)
        if rc is None:
            rc = b'case $- in *i*) printf "UNEXPECTED INTERACTIVE STARTUP\\n";; esac\n'
        if noisy:
            rc = b'printf "NOISY STARTUP\\n"\n' + rc
        (self.home / ".bashrc").write_bytes(rc)
        (self.home / "startup.bash").write_text('source "$HOME/.bashrc"\n')
        self.config = self.root / "transport.json"
        self.config.write_text(
            json.dumps(
                {
                    "root": str(self.root),
                    "home": str(self.home),
                    "bash": self.bash,
                    "scp": self.scp,
                    "sftp_server": self.server,
                    "command_python": (
                        "import sys; data=sys.stdin.buffer.read(); "
                        "sys.stdout.buffer.write(data); "
                        "sys.stderr.buffer.write(b'command-stderr\\n'); "
                        "sys.exit(23)"
                    ),
                }
            )
        )
        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.home),
            "LC_ALL": "C",
            CONFIG_ENV: str(self.config),
        }

    def command(self, payload):
        return bounded_process(
            [sys.executable, self.adapter, HOST, "frame-test-command"],
            env=self.env,
            input=payload,
        )

    def scp_roundtrip(self, payload):
        source = self.root / "scp-source"
        remote = self.root / "scp-remote"
        received = self.root / "scp-received"
        source.write_bytes(payload)
        for argv in (
            [self.scp, "-O", "-S", self.adapter, source, f"{HOST}:{remote}"],
            [self.scp, "-O", "-S", self.adapter, f"{HOST}:{remote}", received],
        ):
            result = bounded_process(argv, env=self.env)
            assert result.returncode == 0, result.stderr.decode(errors="replace")
            assert result.stdout == b"", "SCP startup contaminated stdout"
        assert remote.read_bytes() == payload
        assert received.read_bytes() == payload

    def sftp_roundtrip(self, payload):
        source = self.root / "sftp-source"
        remote = self.root / "sftp-remote"
        received = self.root / "sftp-received"
        source.write_bytes(payload)
        batch = f'put "{source}" "{remote}"\nget "{remote}" "{received}"\nbye\n'.encode()
        result = bounded_process(
            [self.sftp, "-q", "-b", "-", "-S", self.adapter, HOST], env=self.env, input=batch
        )
        assert result.returncode == 0, result.stderr.decode(errors="replace")
        assert b"STARTUP" not in result.stdout + result.stderr
        assert remote.read_bytes() == payload
        assert received.read_bytes() == payload


def ssh_file_transfer_startup_scenario(root, *, rc=None, noisy=False):
    transport = SyntheticTransport(Path(root), rc=rc, noisy=noisy)
    payload = bytes(range(256)) * 512 + b"literal ; $HOME 'quoted'\x00\n"
    result = transport.command(payload)
    assert result.stdout == payload, "command startup contaminated stdout"
    assert result.stderr == b"command-stderr\n"
    assert result.returncode == 23
    transport.scp_roundtrip(payload)
    transport.sftp_roundtrip(payload)
    return {"command": "passed", "scp_legacy": "passed", "sftp": "passed"}


if __name__ == "__main__":
    try:
        adapter_main(sys.argv[1:])
    except (ValueError, KeyError, OSError) as error:
        print(f"synthetic transport: {error}", file=sys.stderr)
        sys.exit(125)
