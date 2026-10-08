"""User-local SSH agents with namespace supervision and process-bound cleanup.

The caller supplies namespace_argv for every OpenSSH/supervisor invocation and a
profile_lock context factory. The lock order is profile, then agent. Generation
roots are direct links in the selected physical Nix store, independent of the
profile link. No operation loads keys or interprets ssh-agent shell output.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import select
import signal
import stat
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

SOCKET_LIMIT = 107
RECORD_LIMIT = 65536
LOG_LIMIT = 65536
GENERATION = re.compile(r"/nix/store/[a-zA-Z0-9][a-zA-Z0-9+._?=-]*\Z")


class AgentError(RuntimeError):
    """An agent operation cannot satisfy its ownership or lifecycle checks."""


class CapabilityError(AgentError):
    """The host lacks a required race-safe process operation."""


def _absolute(path):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise AgentError(f"An absolute path without traversal is required: {path}")
    return path


def _no_symlinks(path):
    path = _absolute(path)
    for part in [*reversed(path.parents), path]:
        try:
            info = part.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise AgentError(f"Refusing redirected agent path: {part}")


def _directory(path, uid, *, create=False, private=True):
    path = _absolute(path)
    _no_symlinks(path)
    if create and not path.exists():
        _directory(path.parent, uid, create=True, private=private)
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            pass
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != uid:
        raise AgentError(f"Agent directory must be owned by UID {uid}: {path}")
    mode = stat.S_IMODE(info.st_mode)
    if mode & 0o022 or (private and mode != 0o700):
        raise AgentError(
            f"Agent directory must have mode {'0700' if private else 'non-writable'}: {path}"
        )
    return path


def _home_path(path, home, uid, *, create=False, private=True):
    path = _absolute(path)
    home = _absolute(home)
    if not path.is_relative_to(home):
        raise AgentError(f"Agent state must remain under HOME: {path}")
    _directory(home, uid, private=False)
    for part in reversed(path.parents):
        if part != home and part.is_relative_to(home):
            _directory(part, uid, create=create, private=False)
    return _directory(path, uid, create=create, private=private)


def _regular(path, uid):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or stat.S_IMODE(info.st_mode) != 0o600:
        raise AgentError(f"Agent file must be an owned mode-0600 regular file: {path}")
    if info.st_nlink != 1:
        raise AgentError(f"Refusing hard-linked agent file: {path}")
    return info


def _read(path, uid):
    try:
        before = _regular(path, uid)
    except FileNotFoundError:
        return None
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        if (info.st_dev, info.st_ino) != (before.st_dev, before.st_ino):
            raise AgentError(f"Agent file changed during validation: {path}")
        data = os.read(fd, RECORD_LIMIT + 1)
    finally:
        os.close(fd)
    if len(data) > RECORD_LIMIT:
        raise AgentError(f"Agent record is too large: {path}")
    try:
        value = json.loads(data)
    except (ValueError, UnicodeError) as exc:
        raise AgentError(f"Invalid agent record: {path}") from exc
    if not isinstance(value, dict):
        raise AgentError(f"Invalid agent record: {path}")
    return value


def _write(path, value, uid):
    _directory(path.parent, uid)
    if path.exists() or path.is_symlink():
        _regular(path, uid)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(json.dumps(value, sort_keys=True).encode())
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)


def _unlink_file(path, uid):
    try:
        _regular(path, uid)
    except FileNotFoundError:
        return
    path.unlink()


@contextlib.contextmanager
def private_lock(path, uid=None, timeout=5.0):
    """Acquire an owned private flock without an unbounded wait."""
    uid = os.getuid() if uid is None else uid
    _directory(path.parent, uid)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != uid
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
        ):
            raise AgentError(f"Unsafe agent lock: {path}")
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise AgentError(f"Timed out acquiring agent lock: {path}") from None
                select.select([], [], [], min(0.02, max(0, deadline - time.monotonic())))
        yield fd
    finally:
        os.close(fd)


def _boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def process_identity(pid):
    """Read Linux identity fields; callers bind a pidfd before trusting them."""
    try:
        directory = Path("/proc") / str(pid)
        raw = (directory / "stat").read_text()
        fields = raw[raw.rfind(")") + 2 :].split()
        status = (directory / "status").read_text()
        uids = next(line.split()[1:] for line in status.splitlines() if line.startswith("Uid:"))
        environ = (directory / "environ").read_bytes().split(b"\0")
        token = next(
            (
                item.split(b"=", 1)[1].decode()
                for item in environ
                if item.startswith(b"FRAME_AGENT_LAUNCH_ID=")
            ),
            "",
        )
        return {
            "pid": int(pid),
            "start": fields[19],
            "ppid": int(fields[1]),
            "uid": [int(value) for value in uids],
            "exe": os.readlink(directory / "exe"),
            "namespaces": {
                name: os.readlink(directory / "ns" / name) for name in ("mnt", "user", "pid")
            },
            "argv": [
                item.decode() for item in (directory / "cmdline").read_bytes().split(b"\0") if item
            ],
            "launch_id": token,
        }
    except (FileNotFoundError, ProcessLookupError):
        return None
    except (PermissionError, OSError, ValueError, StopIteration) as exc:
        raise AgentError(f"Cannot verify process {pid} through /proc: {exc}") from exc


def child_identity(pid, record, supervisor):
    """Read public child fields and bind protected fields to the verified spawn."""
    directory = Path("/proc") / str(pid)
    try:
        raw = (directory / "stat").read_text()
        fields = raw[raw.rfind(")") + 2 :].split()
        status = (directory / "status").read_text()
        uids = next(line.split()[1:] for line in status.splitlines() if line.startswith("Uid:"))
        return {
            "pid": pid,
            "start": fields[19],
            "ppid": int(fields[1]),
            "uid": [int(value) for value in uids],
            "argv": [
                item.decode() for item in (directory / "cmdline").read_bytes().split(b"\0") if item
            ],
            "exe": record["resolved_agent_exe"],
            "namespaces": supervisor["namespaces"],
            "launch_id": record["launch_id"],
        }
    except (FileNotFoundError, ProcessLookupError):
        return None
    except (OSError, ValueError, StopIteration) as exc:
        raise AgentError(f"Cannot verify managed child {pid}: {exc}") from exc


class ProcessHandle:
    """A Linux pidfd. Signals and exit waits never use a numeric PID."""

    def __init__(self, pid):
        if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
            raise CapabilityError(
                "Agent management requires Linux pidfds and Python pidfd_send_signal; "
                "upgrade the kernel/Python."
            )
        try:
            self.fd = os.pidfd_open(pid, 0)
        except ProcessLookupError:
            raise
        except OSError as exc:
            raise CapabilityError(
                f"Cannot open a race-safe pidfd: {exc}; automatic agent recovery is refused."
            ) from exc
        self.pid = pid

    def associated(self, pid):
        try:
            lines = Path(f"/proc/self/fdinfo/{self.fd}").read_text().splitlines()
            return next(int(line.split()[1]) for line in lines if line.startswith("Pid:")) == pid
        except (OSError, ValueError, StopIteration) as exc:
            raise CapabilityError(
                "Cannot verify pidfd process association through /proc/self/fdinfo."
            ) from exc

    def exited(self):
        return bool(select.select([self.fd], [], [], 0)[0])

    def wait(self, timeout):
        return bool(select.select([self.fd], [], [], timeout)[0])

    def send(self, sig):
        signal.pidfd_send_signal(self.fd, sig, None, 0)

    def close(self):
        os.close(self.fd)


def _terminate(handle, timeout):
    if handle.exited():
        return
    try:
        handle.send(signal.SIGTERM)
    except ProcessLookupError:
        pass
    if not handle.wait(timeout):
        try:
            handle.send(signal.SIGKILL)
        except ProcessLookupError:
            pass
        if not handle.wait(timeout):
            raise AgentError(
                "Agent exit could not be confirmed; its record and generation root remain."
            )


class _GatedChild:
    """A direct child cannot exec until the parent owns its pidfd."""

    def __init__(self, timeout, *, handle_factory=ProcessHandle, boundary=None):
        self.timeout = timeout
        self.handle_factory = handle_factory
        self.boundary = boundary or (lambda _name, _child: None)
        self.pid = None
        self.handle = None
        self.stdout = None
        self.gate = None
        self.released = False
        self.returncode = None
        self.confirmed = False

    @staticmethod
    def _pipe():
        descriptors = list(os.pipe2(os.O_CLOEXEC))
        try:
            for index, fd in enumerate(descriptors):
                if fd < 3:
                    descriptors[index] = fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 3)
                    os.close(fd)
            return descriptors
        except BaseException:
            for fd in descriptors:
                os.close(fd)
            raise

    def spawn(self, argv, *, env, cwd):
        gate_read = log_write = None
        blocked = {signal.SIGTERM, signal.SIGHUP, signal.SIGINT}
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
        try:
            gate_read, self.gate = self._pipe()
            log_read, log_write = self._pipe()
            self.stdout = os.fdopen(log_read, "rb", buffering=0)
            close_limit = max(
                os.sysconf("SC_OPEN_MAX"),
                max(int(fd) for fd in os.listdir("/proc/self/fd")) + 1,
            )
            self.pid = os.fork()
            if self.pid == 0:
                # A single-threaded namespace supervisor forks this child. No
                # Python handler or inherited lock descriptor survives exec.
                try:
                    null = os.open(os.devnull, os.O_RDONLY)
                    os.dup2(null, 0)
                    os.dup2(log_write, 1)
                    os.dup2(log_write, 2)
                    os.closerange(3, gate_read)
                    os.closerange(gate_read + 1, close_limit)
                    for sig in (*blocked, signal.SIGPIPE):
                        signal.signal(sig, signal.SIG_DFL)
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous)
                    ready = select.select([gate_read], [], [], self.timeout * 3)[0]
                    if not ready or os.read(gate_read, 1) != b"G":
                        os._exit(125)
                    os.close(gate_read)
                    os.chdir(cwd)
                    os.execve(argv[0], argv, env)
                except BaseException:
                    os._exit(126)
            os.close(gate_read)
            gate_read = None
            os.close(log_write)
            log_write = None
            self.boundary("fork", self)
            self.handle = self.handle_factory(self.pid)
            if not self.handle.associated(self.pid) or self.handle.exited():
                raise AgentError("Gated child pidfd association could not be verified.")
            self.boundary("pidfd", self)
        except BaseException:
            self.abort()
            raise
        finally:
            if gate_read is not None:
                os.close(gate_read)
            if log_write is not None:
                os.close(log_write)
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)

    def release(self):
        if self.handle is None or self.gate is None:
            raise AgentError("Child exec requires an acquired pidfd and an open gate.")
        self.boundary("before_release", self)
        blocked = {signal.SIGTERM, signal.SIGHUP, signal.SIGINT}
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
        try:
            # Mark execution as possible before writing. Cleanup then uses only
            # the retained pidfd even if a write or pending signal interrupts it.
            self.released = True
            os.write(self.gate, b"G")
            self._close_gate()
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        self.boundary("release", self)

    def _close_gate(self):
        if self.gate is not None:
            os.close(self.gate)
            self.gate = None

    def wait(self, timeout=None):
        if self.pid is None or self.confirmed:
            return self.returncode
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        while True:
            # The direct child is never reaped elsewhere, so waitpid cannot
            # address a reused PID. It confirms exit and never sends a signal.
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid == self.pid:
                self.returncode = os.waitstatus_to_exitcode(status)
                self.confirmed = True
                return self.returncode
            if time.monotonic() >= deadline:
                raise AgentError("Gated child exit is unconfirmed; preserving launch intent/root.")
            select.select([], [], [], min(0.02, max(0, deadline - time.monotonic())))

    def abort(self):
        self._close_gate()
        if self.pid is None:
            self.confirmed = True
            return
        if self.released:
            if self.handle is None:
                raise AgentError("Executed child lacks its required retained pidfd.")
            _terminate(self.handle, self.timeout)
        # Before release, EOF makes the child self-exit without executing any
        # agent binary. This path needs no pidfd and never signals a numeric PID.
        self.wait()


@dataclass(frozen=True)
class AgentStatus:
    kind: str
    socket: str | None = None
    detail: str = ""
    generation: str | None = None

    def as_dict(self):
        return {
            "kind": self.kind,
            "socket": self.socket,
            "detail": self.detail,
            "generation": self.generation,
        }


class AgentManager:
    """Manage one shared agent for one canonical Frame state directory.

    namespace_argv(argv) returns a subprocess argv inside the selected namespace.
    generation is an immutable /nix/store output, not the mutable profile link.
    profile_lock() must be the same bounded lock used by profile mutations.
    runner and popen use subprocess-compatible signatures. handle_factory returns
    a ProcessHandle-compatible object. boundary(name) permits fault injection.
    """

    def __init__(
        self,
        home,
        state_dir,
        *,
        store_dir,
        generation,
        namespace_argv,
        generation_factory=None,
        dependency_resolver=None,
        namespace_environment=False,
        profile_lock=None,
        runner=subprocess.run,
        popen=subprocess.Popen,
        handle_factory=ProcessHandle,
        identity_reader=process_identity,
        child_reader=child_identity,
        boot_reader=_boot_id,
        timeout=5.0,
        probe_timeout=2.0,
        supervisor_python="/usr/bin/python3",
        agent_executable=None,
        add_executable=None,
        boundary=None,
    ):
        self.home = _absolute(home)
        self.state_dir = _absolute(state_dir)
        self.store_dir = _absolute(store_dir)
        if not self.state_dir.is_relative_to(self.home) or not self.store_dir.is_relative_to(
            self.state_dir
        ):
            raise AgentError(
                "Agent state/store must be confined beneath the selected HOME and state."
            )
        if not GENERATION.fullmatch(str(generation)):
            raise AgentError("Agent generation must be one immutable /nix/store output.")
        self.generation = str(generation)
        self.agent_executable = str(_absolute(agent_executable or f"{generation}/bin/ssh-agent"))
        self.add_executable = str(_absolute(add_executable or f"{generation}/bin/ssh-add"))
        self.namespace_argv = namespace_argv
        self.namespace_environment = namespace_environment
        self.generation_factory = generation_factory
        self.dependency_resolver = dependency_resolver or self._dependency_path
        self.uid = os.getuid()
        self.control = self.state_dir / "agent"
        self.state_id = hashlib.sha256(str(self.state_dir).encode()).hexdigest()[:16]
        self.runner = runner
        self.popen = popen
        self.handle_factory = handle_factory
        self.identity_reader = identity_reader
        self.child_reader = child_reader
        self.boot_reader = boot_reader
        self.timeout = timeout
        self.probe_timeout = probe_timeout
        self.supervisor_python = supervisor_python
        self.boundary = boundary or (lambda _name: None)
        self.profile_lock = profile_lock or (
            lambda: private_lock(self.state_dir / "profile.lock", self.uid, self.timeout)
        )

    def _setup(self):
        _home_path(self.state_dir, self.home, self.uid, create=True)
        _home_path(self.control, self.home, self.uid, create=True)

    @contextlib.contextmanager
    def _lock(self):
        with private_lock(self.control / "agent.lock", self.uid, self.timeout) as fd:
            self._lock_fd = fd
            try:
                yield
            finally:
                self._lock_fd = None

    def _wait_unlocked(self, handle, timeout):
        fd = self._lock_fd
        fcntl.flock(fd, fcntl.LOCK_UN)
        try:
            return handle.wait(timeout)
        finally:
            deadline = time.monotonic() + self.timeout
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise AgentError(
                            "Timed out reacquiring agent lock after supervised stop."
                        ) from None
                    select.select([], [], [], 0.02)

    def _record(self):
        value = _read(self.control / "intent.json", self.uid)
        if value is None:
            return None
        required = {
            "version",
            "state",
            "home",
            "uid",
            "boot",
            "launch_id",
            "generation",
            "socket",
            "root",
        }
        if not required.issubset(value) or value["version"] != 1:
            raise AgentError("Malformed managed-agent intent; preserving its process and root.")
        if (
            value["state"] != str(self.state_dir)
            or value["home"] != str(self.home)
            or value["uid"] != self.uid
        ):
            raise AgentError("Managed-agent state ownership does not match this Frame home.")
        if not re.fullmatch(r"[a-f0-9]{32}", str(value["launch_id"])):
            raise AgentError("Invalid agent launch identity.")
        if not GENERATION.fullmatch(str(value["generation"])):
            raise AgentError("Invalid rooted agent generation.")
        if value["root"] != str(self._root_path(value["launch_id"])):
            raise AgentError("Managed-agent generation root escapes the selected store.")
        self._validate_socket_path(Path(value["socket"]), missing=True)
        if value["boot"] != self.boot_reader():
            raise AgentError(
                "Managed-agent record is from a prior boot; refusing to signal a saved PID."
            )
        return value

    def _root_path(self, token):
        return self.store_dir / "var/nix/gcroots" / f"frame-agent-{self.state_id}-{token}"

    def _root(self, record):
        parent = self._root_path(record["launch_id"]).parent
        _home_path(parent, self.home, self.uid, create=True, private=False)
        root = Path(record["root"])
        if root.exists() or root.is_symlink():
            raise AgentError(f"Conflicting agent generation root: {root}")
        root.symlink_to(record["generation"])
        self._root_validate(record)

    def _root_validate(self, record):
        root = Path(record["root"])
        _home_path(root.parent, self.home, self.uid, private=False)
        info = root.lstat()
        if (
            not stat.S_ISLNK(info.st_mode)
            or info.st_uid != self.uid
            or os.readlink(root) != record["generation"]
        ):
            raise AgentError("Agent generation root changed; preserving it.")

    def _root_release(self, record):
        root = Path(record["root"])
        try:
            self._root_validate(record)
        except FileNotFoundError:
            return
        root.unlink()

    def _socket_path(self, env):
        runtime = env.get("XDG_RUNTIME_DIR")
        if runtime:
            try:
                base = _directory(_absolute(runtime), self.uid)
            except (AgentError, FileNotFoundError):
                base = None
            if base is not None:
                directory = base / "frame-cli" / self.state_id
                _directory(base / "frame-cli", self.uid, create=True)
                _directory(directory, self.uid, create=True)
                socket = directory / "agent.sock"
                self._validate_socket_path(socket)
                return socket
        directory = _home_path(self.control / "run", self.home, self.uid, create=True)
        socket = directory / "agent.sock"
        self._validate_socket_path(socket)
        return socket

    def _validate_socket_path(self, path, *, missing=False):
        path = _absolute(path)
        if len(os.fsencode(path)) > SOCKET_LIMIT:
            raise AgentError(
                "Agent socket path exceeds the Unix socket limit; "
                "set a short private XDG_RUNTIME_DIR."
            )
        fallback = self.control / "run" / "agent.sock"
        if path != fallback:
            if (
                path.name != "agent.sock"
                or path.parent.name != self.state_id
                or path.parent.parent.name != "frame-cli"
            ):
                raise AgentError("Invalid managed-agent socket confinement.")
            anchor = path.parent.parent.parent
        else:
            anchor = self.control
        _no_symlinks(path)
        for directory in (anchor, path.parent.parent, path.parent):
            try:
                _directory(directory, self.uid)
            except FileNotFoundError:
                if not missing:
                    raise
        return path

    def _socket_info(self, path):
        self._validate_socket_path(path, missing=True)
        try:
            info = path.lstat()
        except FileNotFoundError:
            return None
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != self.uid or info.st_mode & 0o077:
            raise AgentError(
                f"Agent socket is not a private owned Unix socket; preserving conflict: {path}"
            )
        return info

    def _remove_socket(self, path):
        if self._socket_info(path) is not None:
            path.unlink()

    def _argv(self, argv, env):
        if self.namespace_environment:
            return self.namespace_argv(argv, env=env)
        return self.namespace_argv(argv)

    def _snapshot(self):
        if self.generation_factory is not None:
            generation = str(self.generation_factory())
            if not GENERATION.fullmatch(generation):
                raise AgentError("Profile snapshot is not one immutable /nix/store generation.")
            self.generation = generation
            self.agent_executable = f"{generation}/bin/ssh-agent"
            self.add_executable = f"{generation}/bin/ssh-add"
            self.supervisor_python = f"{generation}/bin/python3"

    def _dependency_path(self, executable):
        logical = _absolute(executable)
        if not logical.is_relative_to("/nix"):
            return logical.resolve(strict=True)
        _home_path(self.store_dir, self.home, self.uid, private=False)
        for _ in range(40):
            if not logical.is_relative_to("/nix/store") or len(logical.parts) < 4:
                raise AgentError(f"Agent executable escapes the selected store: {logical}")
            physical = self.store_dir
            for index, component in enumerate(logical.parts[2:], start=2):
                physical /= component
                info = physical.lstat()
                if stat.S_ISLNK(info.st_mode):
                    target = Path(os.readlink(physical))
                    if not target.is_absolute():
                        target = Path(*logical.parts[:index]) / target
                    logical = Path(os.path.normpath(target)) / Path(*logical.parts[index + 1 :])
                    break
            else:
                return physical
        raise AgentError("Agent executable store symlink chain is too long.")

    def _validate_dependencies(self):
        for executable in (self.supervisor_python, self.agent_executable, self.add_executable):
            try:
                physical = Path(self.dependency_resolver(executable))
                info = physical.stat()
                if not stat.S_ISREG(info.st_mode) or not os.access(physical, os.X_OK):
                    raise OSError("not an executable regular file")
            except (OSError, RuntimeError) as exc:
                raise AgentError(
                    f"Required agent executable is unavailable: {executable}; "
                    "rebuild the selected profile with Python and OpenSSH."
                ) from exc

    def probe(self, socket, env):
        """Quiet bounded agent-protocol check; an empty agent is usable."""
        if not socket:
            return False
        probe_env = dict(env, SSH_AUTH_SOCK=str(socket))
        try:
            result = self.runner(
                self._argv([self.add_executable, "-l"], probe_env),
                env=probe_env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=self.probe_timeout,
                check=False,
            )
            return result.returncode in (0, 1)
        except (OSError, subprocess.TimeoutExpired):
            return False

    def _verified_handle(self, identity, record, *, child=True):
        if (
            not isinstance(identity, dict)
            or not isinstance(identity.get("pid"), int)
            or identity["pid"] <= 1
        ):
            raise AgentError("Missing process identity; agent lifecycle remains unresolved.")
        try:
            handle = self.handle_factory(identity["pid"])
        except ProcessLookupError:
            return None
        try:
            if handle.exited():
                return handle
            if not handle.associated(identity["pid"]):
                raise AgentError("pidfd is not associated with the recorded process.")
            current = self.identity_reader(identity["pid"])
            if current != identity or handle.exited():
                if handle.exited():
                    return handle
                raise AgentError(
                    "Managed-agent PID/start time, UID, executable or namespace identity changed."
                )
            if current["uid"] != [self.uid] * 4 or current["launch_id"] != record["launch_id"]:
                raise AgentError("Managed-agent UID or per-launch process identity does not match.")
            if child:
                if current["argv"] != [record["agent_exe"], "-D", "-a", record["socket"]]:
                    raise AgentError("Managed process is not the recorded foreground ssh-agent.")
                if current["exe"] != record["resolved_agent_exe"]:
                    raise AgentError("Managed ssh-agent executable identity does not match.")
                supervisor = record.get("supervisor")
                if (
                    not supervisor
                    or current["ppid"] != supervisor["pid"]
                    or current["namespaces"] != supervisor["namespaces"]
                ):
                    raise AgentError(
                        "Managed agent is not bound to its recorded namespace supervisor."
                    )
            if not handle.associated(identity["pid"]):
                raise AgentError("pidfd process association changed during verification.")
            return handle
        except BaseException:
            handle.close()
            raise

    def _verified_supervisor(self, record, *, require_child=True):
        identity = record.get("supervisor")
        if not isinstance(identity, dict):
            raise AgentError("Missing namespace supervisor identity.")
        handle = self._verified_handle(identity, record, child=False)
        if handle is None or handle.exited():
            if handle is not None:
                handle.close()
            raise AgentError("Namespace supervisor is absent; child lifecycle remains unresolved.")
        expected = record.get("supervisor_argv")
        if not expected or identity["argv"] != expected or "--supervise" not in expected:
            handle.close()
            raise AgentError("Managed process is not the recorded namespace agent supervisor.")
        if not require_child:
            return handle
        try:
            child = record.get("child")
            if not isinstance(child, dict) or not isinstance(child.get("pid"), int):
                raise AgentError("Missing supervisor child lifecycle identity.")
            child_handle = self.handle_factory(child["pid"])
            try:
                if child_handle.exited() or not child_handle.associated(child["pid"]):
                    raise AgentError("Child pidfd association or lifecycle identity changed.")
                current = self.child_reader(child["pid"], record, identity)
                if current != child or child_handle.exited():
                    raise AgentError(
                        "Managed child PID/start time, UID, argv or parent identity changed."
                    )
            finally:
                child_handle.close()
            return handle
        except BaseException:
            handle.close()
            raise

    def _authorize_spawn(self, record):
        authorization = _read(self.control / "spawn.json", self.uid)
        if authorization is not None:
            if authorization != {"launch_id": record["launch_id"]}:
                raise AgentError("Supervisor spawn authorization does not match this launch.")
            return
        ready = _read(self.control / "supervisor.json", self.uid)
        if ready is None:
            return
        if ready.get("launch_id") != record["launch_id"] or ready.get("no_child") is not True:
            raise AgentError("Supervisor startup handshake is not a no-child acknowledgement.")
        pending = dict(record, supervisor=ready.get("identity"))
        handle = self._verified_supervisor(pending, require_child=False)
        try:
            self.boundary("supervisor_ready")
            _write(self.control / "spawn.json", {"launch_id": record["launch_id"]}, self.uid)
            self.boundary("spawn_authorized")
        finally:
            handle.close()

    def _candidate(self, record):
        candidate = _read(self.control / "candidate.json", self.uid)
        if candidate is None:
            return None
        if candidate.get("launch_id") != record["launch_id"]:
            raise AgentError("Launch candidate identity does not match the pending intent.")
        merged = dict(
            record, **{key: candidate[key] for key in ("child", "supervisor", "resolved_agent_exe")}
        )
        handle = self._verified_supervisor(merged)
        handle.close()
        child = merged["child"]
        supervisor = merged["supervisor"]
        if (
            child["uid"] != [self.uid] * 4
            or child["launch_id"] != record["launch_id"]
            or child["argv"] != [record["agent_exe"], "-D", "-a", record["socket"]]
            or child["exe"] != merged["resolved_agent_exe"]
            or child["ppid"] != supervisor["pid"]
            or child["namespaces"] != supervisor["namespaces"]
        ):
            raise AgentError("Supervisor child attestation does not match the managed launch.")
        return merged

    def _cleanup(self, record):
        self._remove_socket(Path(record["socket"]))
        self._root_release(record)
        for name in (
            "managed.json",
            "candidate.json",
            "ack.json",
            "cancel.json",
            "exited.json",
            "supervisor.json",
            "spawn.json",
            "intent.json",
        ):
            _unlink_file(self.control / name, self.uid)

    def _managed(self, record):
        managed = _read(self.control / "managed.json", self.uid)
        if managed is None:
            return None
        if any(managed.get(key) != value for key, value in record.items()):
            raise AgentError("Managed launch record does not match its intent.")
        ack = _read(self.control / "ack.json", self.uid)
        if ack != {"launch_id": record["launch_id"]}:
            return None
        return managed

    def _supervised_stop(self, record, handle):
        try:
            handle.send(signal.SIGTERM)
        except ProcessLookupError:
            pass
        if not self._wait_unlocked(handle, self.timeout * 3):
            raise AgentError(
                "Namespace supervisor did not confirm exit; retaining the child record/root."
            )
        completion = _read(self.control / "exited.json", self.uid)
        if completion != {"launch_id": record["launch_id"], "confirmed": True}:
            raise AgentError(
                "Supervisor exited without confirmed child exit; retaining the record/root."
            )
        self._cleanup(record)

    def _cancel_unspawned(self, record, *, launcher=None):
        if (
            record.get("spawn_protocol") != 1
            or _read(self.control / "spawn.json", self.uid) is not None
        ):
            return False
        if _read(self.control / "candidate.json", self.uid) is not None:
            raise AgentError(
                "Child candidate exists without spawn authorization; preserving the root."
            )
        _write(self.control / "cancel.json", {"launch_id": record["launch_id"]}, self.uid)
        ready = _read(self.control / "supervisor.json", self.uid)
        handle = None
        try:
            if ready is not None:
                if (
                    ready.get("launch_id") != record["launch_id"]
                    or ready.get("no_child") is not True
                ):
                    raise AgentError(
                        "Unverified no-child supervisor acknowledgement; retaining launch root."
                    )
                pending = dict(record, supervisor=ready.get("identity"))
                handle = self._verified_handle(pending["supervisor"], pending, child=False)
                if handle is not None and not handle.exited():
                    if pending["supervisor"]["argv"] != record["supervisor_argv"]:
                        raise AgentError("No-child supervisor argv does not match this launch.")
                    try:
                        handle.send(signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    if not self._wait_unlocked(handle, self.timeout):
                        raise AgentError(
                            "No-child supervisor has not exited; retaining launch root."
                        )
            elif launcher is not None and launcher.poll() is None:
                # This unreaped direct child is Popen's process, not a saved PID.
                # It cannot start an agent because spawn authorization is absent.
                try:
                    handle = self.handle_factory(launcher.pid)
                except ProcessLookupError:
                    pass
                if handle is not None:
                    if not handle.associated(launcher.pid):
                        raise AgentError("Direct namespace launcher pidfd association failed.")
                    _terminate(handle, self.timeout)
        finally:
            if handle is not None:
                handle.close()
        self._cleanup(record)
        return True

    def _reconcile(self, env, *, stop=False):
        record = self._record()
        if record is None:
            return None
        if self._cancel_unspawned(record):
            return None
        completion = _read(self.control / "exited.json", self.uid)
        if completion == {"launch_id": record["launch_id"], "confirmed": True}:
            self._cleanup(record)
            return None
        managed = self._managed(record)
        if managed is None:
            candidate = _read(self.control / "candidate.json", self.uid)
            if candidate is None or candidate.get("launch_id") != record["launch_id"]:
                raise AgentError(
                    "Agent publication is unresolved; retaining its intent and generation root."
                )
            managed = dict(
                record,
                **{key: candidate[key] for key in ("child", "supervisor", "resolved_agent_exe")},
            )
            stop = True
        handle = self._verified_supervisor(managed)
        try:
            self._root_validate(managed)
            socket = Path(managed["socket"])
            healthy = self._socket_info(socket) is not None and self.probe(socket, env)
            if stop or not healthy:
                self._supervised_stop(managed, handle)
                return None
            return managed
        finally:
            handle.close()

    def prepare_environment(
        self, env, *, interactive=True, explicit_command=False, readiness=False, dry_run=False
    ):
        """Select an agent only for interactive default entry; return an env copy."""
        result = dict(env)
        if not interactive or explicit_command or readiness or dry_run:
            return result
        if self.probe(result.get("SSH_AUTH_SOCK"), result):
            return result
        result.pop("SSH_AUTH_SOCK", None)
        result.pop("SSH_AGENT_PID", None)
        self._setup()
        with self.profile_lock():
            self._snapshot()
            if self.generation_factory is not None and self.probe(env.get("SSH_AUTH_SOCK"), env):
                return dict(env)
            with self._lock():
                managed = self._reconcile(result)
                if managed is not None:
                    result["SSH_AUTH_SOCK"] = managed["socket"]
                    return result
                self._validate_dependencies()
                socket = self._socket_path(result)
                info = self._socket_info(socket)
                if info is not None:
                    if self.probe(socket, result):
                        raise AgentError(
                            "An unrecorded responding local agent occupies the shared socket; "
                            "refusing takeover."
                        )
                    self._remove_socket(socket)
                token = uuid.uuid4().hex
                record = {
                    "version": 1,
                    "spawn_protocol": 1,
                    "home": str(self.home),
                    "state": str(self.state_dir),
                    "uid": self.uid,
                    "boot": self.boot_reader(),
                    "launch_id": token,
                    "generation": self.generation,
                    "socket": str(socket),
                    "root": str(self._root_path(token)),
                    "agent_exe": self.agent_executable,
                    "add_exe": self.add_executable,
                    "supervisor_argv": [
                        self.supervisor_python,
                        str(Path(__file__).absolute()),
                        "--supervise",
                        str(self.control),
                    ],
                    "timeout": self.timeout,
                    "probe_timeout": self.probe_timeout,
                }
                self.boundary("before_intent")
                _write(self.control / "intent.json", record, self.uid)
                spawned = False
                acknowledged = False
                try:
                    self.boundary("intent")
                    self._root(record)
                    self.boundary("root")
                    # Capability validation precedes spawning. The supervisor repeats it.
                    capability = self.handle_factory(os.getpid())
                    capability.close()
                    launch_env = dict(result, FRAME_AGENT_LAUNCH_ID=token)
                    argv = [
                        self.supervisor_python,
                        str(Path(__file__).absolute()),
                        "--supervise",
                        str(self.control),
                    ]
                    launcher = self.popen(
                        self._argv(argv, launch_env),
                        env=launch_env,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        close_fds=True,
                        start_new_session=True,
                        cwd=self.home,
                    )
                    spawned = True
                except BaseException:
                    self._cleanup(record)
                    raise
            try:
                self.boundary("spawn")
                deadline = time.monotonic() + self.timeout
                while True:
                    with self._lock():
                        exited = _read(self.control / "exited.json", self.uid)
                        if exited is not None:
                            raise AgentError(
                                "The namespace agent supervisor failed before publication; "
                                "inspect the private agent log."
                            )
                        self._authorize_spawn(record)
                        if (
                            launcher.poll() is not None
                            and _read(self.control / "candidate.json", self.uid) is None
                        ):
                            raise AgentError(
                                "Namespace helper or supervisor exited before agent publication."
                            )
                        candidate = self._candidate(record)
                        if candidate is not None:
                            self.boundary("candidate")
                            self._socket_info(Path(record["socket"]))
                            if not self.probe(record["socket"], result):
                                raise AgentError(
                                    "The managed agent failed its bounded readiness probe."
                                )
                            self.boundary("before_publication")
                            _write(self.control / "managed.json", candidate, self.uid)
                            self.boundary("publication")
                            self.boundary("before_acknowledgement")
                            _write(self.control / "ack.json", {"launch_id": token}, self.uid)
                            acknowledged = True
                            self.boundary("acknowledgement")
                            result["SSH_AUTH_SOCK"] = record["socket"]
                            return result
                    if time.monotonic() >= deadline:
                        raise AgentError("Timed out waiting for the namespace agent supervisor.")
                    select.select([], [], [], 0.02)
            except BaseException:
                if not acknowledged:
                    self._cancel_launch(record, spawned, launcher=launcher)
                raise
            finally:
                # Popen must not own a live transport pipe or inherited lock fd.
                if launcher.poll() is not None:
                    launcher.wait()

    def _cancel_launch(self, record, spawned, *, launcher=None):
        with self._lock():
            if self._cancel_unspawned(record, launcher=launcher):
                return
            _write(self.control / "cancel.json", {"launch_id": record["launch_id"]}, self.uid)
        if not spawned:
            return
        deadline = time.monotonic() + self.timeout * 3
        while time.monotonic() < deadline:
            with self._lock():
                exited = _read(self.control / "exited.json", self.uid)
                if exited == {"launch_id": record["launch_id"], "confirmed": True}:
                    self._cleanup(record)
                    return
            select.select([], [], [], 0.02)
        raise AgentError(
            "Interrupted publication remains unresolved; its intent/root are retained. "
            "Retry agent status after checking the supervisor."
        )

    def status(self, env=None):
        """Report agent availability without starting one or listing keys."""
        env = dict(os.environ if env is None else env)
        if self.probe(env.get("SSH_AUTH_SOCK"), env):
            if self.control.exists():
                try:
                    self._setup()
                    with self.profile_lock(), self._lock():
                        record = self._record()
                        if record is not None and record["socket"] == env["SSH_AUTH_SOCK"]:
                            managed = self._managed(record)
                            if managed is not None:
                                handle = self._verified_supervisor(managed)
                                handle.close()
                                return AgentStatus(
                                    "managed",
                                    managed["socket"],
                                    "Managed local agent responds.",
                                    managed["generation"],
                                )
                except (AgentError, OSError) as exc:
                    return AgentStatus("conflict", detail=str(exc))
            return AgentStatus(
                "inherited", env["SSH_AUTH_SOCK"], "Inherited or forwarded agent responds."
            )
        if not self.control.exists():
            return AgentStatus("stopped", detail="No managed agent.")
        try:
            self._setup()
            with self.profile_lock(), self._lock():
                managed = self._reconcile(env)
                if managed:
                    return AgentStatus(
                        "managed",
                        managed["socket"],
                        "Managed local agent responds.",
                        managed["generation"],
                    )
                return AgentStatus("stopped", detail="No managed agent.")
        except (AgentError, OSError) as exc:
            return AgentStatus("conflict", detail=str(exc))

    def stop(self):
        """Stop only the positively identified managed child through its pidfd."""
        if not self.control.exists():
            return AgentStatus("stopped", detail="No managed agent.")
        self._setup()
        with self.profile_lock(), self._lock():
            self._reconcile({}, stop=True)
        return AgentStatus(
            "stopped", detail="Managed agent exit confirmed; owned socket and root released."
        )


def manager_for_frame(frame):
    """Construct a manager against Frame's validated profile and controlled env."""
    with frame.lock():
        generation = frame.validate_profile()
    return AgentManager(
        frame.home,
        frame.state,
        store_dir=frame.paths.store,
        generation=generation,
        generation_factory=frame.validate_profile,
        dependency_resolver=frame.resolve_store_path,
        namespace_argv=lambda argv, env: frame.namespace_argv(argv, env=env),
        namespace_environment=True,
        profile_lock=frame.lock,
        runner=frame.runner,
        supervisor_python=f"{generation}/bin/python3",
    )


def interactive_entry(frame, env):
    """Default TTY adapter; failures leave a shell without a claimed agent."""
    if not os.isatty(0) or not os.isatty(1):
        return dict(env)
    try:
        manager = getattr(frame, "agent_manager", None) or manager_for_frame(frame)
        return manager.prepare_environment(env)
    except (RuntimeError, OSError, AttributeError) as exc:
        print(f"frame-cli: SSH agent unavailable: {exc}", file=sys.stderr)
        result = dict(env)
        result.pop("SSH_AUTH_SOCK", None)
        result.pop("SSH_AGENT_PID", None)
        return result


def handle_cli(frame, action):
    """Print structured key-free status or stop the owned namespace supervisor."""
    try:
        if action not in ("status", "stop"):
            raise AgentError("Agent action must be status or stop.")
        manager = manager_for_frame(frame)
        status = manager.status(frame.environ) if action == "status" else manager.stop()
        print(json.dumps(status.as_dict(), sort_keys=True))
        return 1 if status.kind == "conflict" else 0
    except (RuntimeError, OSError, AttributeError) as exc:
        print(f"frame-cli: agent {action}: {exc}", file=sys.stderr)
        return 1


def _supervise(control, *, child_factory=_GatedChild, handle_factory=ProcessHandle):
    """Run inside the selected namespace; own the child until ack or exit."""
    uid = os.getuid()
    control = _absolute(control)
    _directory(control, uid)
    record = _read(control / "intent.json", uid)
    if record is None or record["launch_id"] != os.environ.get("FRAME_AGENT_LAUNCH_ID"):
        raise AgentError("Supervisor launch identity does not match its durable intent.")
    manager = AgentManager(
        record["home"],
        record["state"],
        store_dir=str(Path(record["root"]).parents[3]),
        generation=record["generation"],
        namespace_argv=lambda argv: argv,
        timeout=record["timeout"],
        probe_timeout=record["probe_timeout"],
    )
    handle = None
    child = None
    acknowledged = False
    confirmed = False
    log_fd = None
    log_size = 0

    def drain(wait=0):
        nonlocal log_size
        if child is None or child.stdout is None:
            select.select([], [], [], wait)
            return
        if select.select([child.stdout], [], [], wait)[0]:
            data = os.read(child.stdout.fileno(), 4096)
            if data and log_size < LOG_LIMIT:
                data = data[: LOG_LIMIT - log_size]
                os.write(log_fd, data)
                log_size += len(data)

    def interrupted(_sig, _frame):
        raise InterruptedError("Namespace agent supervisor interrupted.")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        deadline = time.monotonic() + manager.timeout
        while True:
            with manager._lock():
                current = manager._record()
                if current is None or current["launch_id"] != record["launch_id"]:
                    confirmed = True
                    return
                manager._root_validate(record)
                ready = _read(control / "supervisor.json", uid)
                if ready is None:
                    _write(
                        control / "supervisor.json",
                        {
                            "launch_id": record["launch_id"],
                            "no_child": True,
                            "identity": process_identity(os.getpid()),
                        },
                        uid,
                    )
                if _read(control / "cancel.json", uid) is not None:
                    confirmed = True
                    return
                authorization = _read(control / "spawn.json", uid)
                if authorization is not None:
                    if authorization != {"launch_id": record["launch_id"]}:
                        raise AgentError(
                            "Supervisor spawn authorization does not match its intent."
                        )
                    break
                if time.monotonic() >= deadline:
                    confirmed = True
                    raise AgentError("Supervisor timed out before child-spawn authorization.")
            select.select([], [], [], 0.02)
        with manager._lock():
            current = manager._record()
            if current is None or current["launch_id"] != record["launch_id"]:
                confirmed = True
                return
            manager._root_validate(record)
            if _read(control / "spawn.json", uid) != {"launch_id": record["launch_id"]}:
                confirmed = True
                raise AgentError("Supervisor child-spawn authorization was revoked.")
            log = control / "agent.log"
            if log.exists() or log.is_symlink():
                _regular(log, uid)
            log_fd = os.open(
                log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600
            )
            if _read(control / "cancel.json", uid) is not None:
                confirmed = True
                return
            capability = handle_factory(os.getpid())
            capability.close()
            child = child_factory(manager.timeout, handle_factory=handle_factory)
            child.spawn(
                [record["agent_exe"], "-D", "-a", record["socket"]],
                env=dict(os.environ),
                cwd=record["home"],
            )
            handle = child.handle
            if _read(control / "cancel.json", uid) is not None:
                child.abort()
                confirmed = child.confirmed
                return
            child.release()
        deadline = time.monotonic() + manager.timeout
        probe_env = dict(os.environ, SSH_AUTH_SOCK=record["socket"])
        while True:
            if handle.exited():
                raise AgentError("Managed child exited before readiness.")
            try:
                response = subprocess.run(
                    [record["add_exe"], "-l"],
                    env=probe_env,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=manager.probe_timeout,
                    check=False,
                )
                if response.returncode in (0, 1):
                    break
            except subprocess.TimeoutExpired:
                pass
            if time.monotonic() >= deadline:
                raise AgentError("Managed child readiness timed out.")
            drain(0.02)
        with manager._lock():
            supervisor = process_identity(os.getpid())
            resolved = str(Path(record["agent_exe"]).resolve(strict=True))
            attestation = dict(record, resolved_agent_exe=resolved)
            identity = child_identity(child.pid, attestation, supervisor)
            if identity is None or not handle.associated(child.pid) or handle.exited():
                raise AgentError("Managed child exited during identity attestation.")
            candidate = {
                "launch_id": record["launch_id"],
                "child": identity,
                "supervisor": supervisor,
                "resolved_agent_exe": resolved,
            }
            _write(control / "candidate.json", candidate, uid)
        deadline = time.monotonic() + manager.timeout * 2
        while not handle.exited():
            if not acknowledged:
                with manager._lock():
                    ack = _read(control / "ack.json", uid)
                    if ack == {"launch_id": record["launch_id"]}:
                        acknowledged = True
                    if not acknowledged and (
                        _read(control / "cancel.json", uid) is not None
                        or time.monotonic() >= deadline
                    ):
                        break
            drain(0.05)
        if not handle.exited():
            _terminate(handle, manager.timeout)
        confirmed = handle.wait(manager.timeout)
        if confirmed:
            child.wait()
            drain()
    finally:
        if child is not None:
            try:
                child.abort()
                confirmed = child.confirmed
            finally:
                if child.handle is not None:
                    child.handle.close()
                if child.stdout is not None:
                    child.stdout.close()
        if log_fd is not None:
            os.close(log_fd)
        if confirmed:
            with manager._lock():
                # A completed old supervisor must not overwrite a subsequent launch.
                current = _read(control / "intent.json", uid)
                if current is not None and current.get("launch_id") == record["launch_id"]:
                    _write(
                        control / "exited.json",
                        {"launch_id": record["launch_id"], "confirmed": True},
                        uid,
                    )
                    manager._root_release(record)


def _main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--supervise", type=Path, required=True)
    args = parser.parse_args()
    try:
        _supervise(args.supervise)
    except (AgentError, OSError, InterruptedError) as exc:
        print(f"frame agent supervisor: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
