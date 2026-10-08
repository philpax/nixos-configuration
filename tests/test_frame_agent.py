"""SSH-agent tests use only private temporary homes and ephemeral keys."""

import concurrent.futures
import contextlib
import errno
import os
import shutil
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from frame.agent import (
    AgentError,
    AgentManager,
    CapabilityError,
    ProcessHandle,
    _GatedChild,
    _read,
    _supervise,
    _write,
    handle_cli,
    interactive_entry,
    manager_for_frame,
    private_lock,
)

GEN = "/nix/store/00000000000000000000000000000000-test-frame-openssh"


class FakeHandle:
    def __init__(self, processes, pid):
        self.processes = processes
        self.pid = pid
        self.closed = False
        if pid not in processes:
            raise ProcessLookupError(pid)

    def associated(self, pid):
        return self.pid == pid and not self.processes[self.pid].get("bad_association", False)

    def exited(self):
        return self.processes[self.pid]["exited"]

    def wait(self, timeout):
        return self.exited()

    def send(self, sig):
        process = self.processes[self.pid]
        process["signals"].append(sig)
        process["exited"] = True
        if "on_signal" in process:
            process["on_signal"]()

    def close(self):
        self.closed = True


@pytest.fixture
def synthetic(tmp_path):
    home = tmp_path / "home"
    home.mkdir(mode=0o700)
    state = home / "state"
    processes = {os.getpid(): {"exited": False, "signals": []}}
    calls = []

    def runner(argv, **kwargs):
        calls.append((argv, kwargs))
        return SimpleNamespace(returncode=2)

    manager = AgentManager(
        home,
        state,
        store_dir=state / "store",
        generation=GEN,
        namespace_argv=lambda argv: ["namespace", *argv],
        dependency_resolver=lambda executable: Path(sys.executable),
        runner=runner,
        handle_factory=lambda pid: FakeHandle(processes, pid),
        identity_reader=lambda pid: processes.get(pid, {}).get("identity"),
        child_reader=lambda pid, record, supervisor: processes.get(pid, {}).get("identity"),
        boot_reader=lambda: "test-boot",
        timeout=0.2,
    )
    return SimpleNamespace(
        manager=manager, home=home, state=state, processes=processes, calls=calls
    )


def seed_managed(fixture, *, candidate_only=False):
    manager = fixture.manager
    manager._setup()
    sock = manager._socket_path({})
    token = "a" * 32
    record = {
        "version": 1,
        "home": str(manager.home),
        "state": str(manager.state_dir),
        "uid": manager.uid,
        "boot": "test-boot",
        "launch_id": token,
        "generation": GEN,
        "socket": str(sock),
        "root": str(manager._root_path(token)),
        "agent_exe": GEN + "/bin/ssh-agent",
        "timeout": 0.2,
        "probe_timeout": 0.2,
    }
    manager._root(record)
    _write(manager.control / "intent.json", record, manager.uid)
    supervisor = {
        "pid": 12345,
        "start": "100",
        "uid": [manager.uid] * 4,
        "exe": "/usr/bin/python3",
        "namespaces": {"mnt": "mnt:1", "user": "user:1", "pid": "pid:1"},
        "ppid": 1,
        "argv": ["python3", "--supervise", str(manager.control)],
        "launch_id": token,
    }
    record["supervisor_argv"] = supervisor["argv"]
    _write(manager.control / "intent.json", record, manager.uid)
    child = {
        "pid": 12346,
        "start": "101",
        "uid": [manager.uid] * 4,
        "exe": GEN + "/bin/ssh-agent",
        "namespaces": dict(supervisor["namespaces"]),
        "ppid": supervisor["pid"],
        "argv": [record["agent_exe"], "-D", "-a", str(sock)],
        "launch_id": token,
    }
    for identity in (supervisor, child):
        fixture.processes[identity["pid"]] = {"identity": identity, "exited": False, "signals": []}

    def supervise_exit():
        fixture.processes[child["pid"]]["signals"].append(signal.SIGTERM)
        fixture.processes[child["pid"]]["exited"] = True
        _write(
            manager.control / "exited.json", {"launch_id": token, "confirmed": True}, manager.uid
        )

    fixture.processes[supervisor["pid"]]["on_signal"] = supervise_exit
    candidate = {
        "launch_id": token,
        "child": child,
        "supervisor": supervisor,
        "resolved_agent_exe": child["exe"],
    }
    _write(manager.control / "candidate.json", candidate, manager.uid)
    managed = dict(
        record, **{key: candidate[key] for key in ("child", "supervisor", "resolved_agent_exe")}
    )
    if not candidate_only:
        _write(manager.control / "managed.json", managed, manager.uid)
        _write(manager.control / "ack.json", {"launch_id": token}, manager.uid)
    return managed


@pytest.mark.parametrize("status", [0, 1])
def test_agent_inherited_priority_and_empty_agent(synthetic, status):
    manager = synthetic.manager
    manager.runner = lambda argv, **kw: SimpleNamespace(returncode=status)
    manager.popen = lambda *a, **kw: pytest.fail("Inherited agent must not spawn")
    env = {
        "SSH_AUTH_SOCK": "/forwarded/socket",
        "SSH_AGENT_PID": "untrusted",
        "HOME": str(synthetic.home),
    }
    assert manager.prepare_environment(env) == env
    assert manager.status(env).kind == "inherited"
    assert not synthetic.state.exists()


@pytest.mark.parametrize("flag", ["interactive", "explicit_command", "readiness", "dry_run"])
def test_agent_noninteractive_no_start(synthetic, flag):
    manager = synthetic.manager
    manager.runner = lambda *a, **kw: pytest.fail("No agent probe for command/readiness/dryrun")
    manager.popen = lambda *a, **kw: pytest.fail("No agent startup")
    env = {"SSH_AUTH_SOCK": "/keep/inherited", "SSH_AGENT_PID": "123"}
    kwargs = {flag: False if flag == "interactive" else True}
    assert manager.prepare_environment(env, **kwargs) == env
    assert not synthetic.state.exists()


def test_agent_probe_quiet_bounded_and_no_diagnostic_parsing(synthetic):
    assert not synthetic.manager.probe("/unusable", {})
    argv, kwargs = synthetic.calls[-1]
    assert argv == ["namespace", GEN + "/bin/ssh-add", "-l"]
    assert kwargs["timeout"] == 2.0
    assert kwargs["stdin"] == kwargs["stdout"] == kwargs["stderr"] == subprocess.DEVNULL
    synthetic.manager.runner = lambda *a, **kw: (_ for _ in ()).throw(
        subprocess.TimeoutExpired("probe", 2)
    )
    assert not synthetic.manager.probe("/hung", {})


def test_agent_stale_and_foreign_socket(synthetic):
    manager = synthetic.manager
    manager._setup()
    path = manager._socket_path({})
    endpoint = socket.socket(socket.AF_UNIX)
    endpoint.bind(str(path))
    path.chmod(0o600)
    endpoint.close()
    manager._remove_socket(path)
    assert not path.exists()
    path.write_text("foreign")
    path.chmod(0o600)
    with pytest.raises(AgentError, match="preserving conflict"):
        manager._remove_socket(path)
    assert path.read_text() == "foreign"
    path.unlink()
    path.symlink_to(synthetic.home / "elsewhere")
    with pytest.raises(AgentError, match="redirected"):
        manager._remove_socket(path)
    assert path.is_symlink()


def test_agent_foreign_uid_socket(synthetic, monkeypatch):
    manager = synthetic.manager
    manager._setup()
    path = manager._socket_path({})
    endpoint = socket.socket(socket.AF_UNIX)
    endpoint.bind(str(path))
    path.chmod(0o600)
    original = Path.lstat

    def lstat(value):
        info = original(value)
        if value == path:
            return SimpleNamespace(st_mode=info.st_mode, st_uid=os.getuid() + 1)
        return info

    monkeypatch.setattr(Path, "lstat", lstat)
    with pytest.raises(AgentError, match="preserving conflict"):
        manager._remove_socket(path)
    assert path.exists()
    endpoint.close()


@pytest.mark.parametrize(
    "field",
    ["start", "uid", "exe", "namespaces", "launch_id", "argv", "ppid", "association", "boot"],
)
def test_agent_stop_identity_validation(synthetic, field):
    managed = seed_managed(synthetic)
    process = synthetic.processes[managed["supervisor"]["pid"]]
    if field == "association":
        process["bad_association"] = True
    elif field == "boot":
        synthetic.manager.boot_reader = lambda: "different-boot"
    else:
        changed = dict(process["identity"])
        changed[field] = "foreign"
        process["identity"] = changed
    with pytest.raises(AgentError):
        synthetic.manager.stop()
    assert process["signals"] == []
    assert Path(managed["root"]).is_symlink()
    assert (synthetic.manager.control / "intent.json").exists()


def test_agent_stop_no_numeric_signal_or_inherited_pid(synthetic, monkeypatch):
    managed = seed_managed(synthetic)
    monkeypatch.setattr(os, "kill", lambda *a: pytest.fail("Numeric PID signals are forbidden"))
    monkeypatch.setenv("SSH_AGENT_PID", str(os.getpid()))
    assert synthetic.manager.stop().kind == "stopped"
    assert synthetic.processes[managed["child"]["pid"]]["signals"] == [signal.SIGTERM]
    assert synthetic.processes[os.getpid()]["signals"] == []
    assert not Path(managed["root"]).is_symlink()


def test_agent_live_process_missing_socket(synthetic):
    managed = seed_managed(synthetic)
    assert not Path(managed["socket"]).exists()
    assert synthetic.manager.status({}).kind == "stopped"
    assert synthetic.processes[managed["child"]["pid"]]["exited"]
    assert not Path(managed["root"]).is_symlink()


def test_agent_missing_runtime_preserves_root_without_pidfd(synthetic):
    managed = seed_managed(synthetic)
    Path(managed["socket"]).parent.rmdir()
    synthetic.manager.handle_factory = lambda pid: (_ for _ in ()).throw(
        CapabilityError("pidfds unavailable")
    )
    status = synthetic.manager.status({})
    assert status.kind == "conflict"
    assert "pidfds" in status.detail
    assert Path(managed["root"]).is_symlink()
    assert synthetic.processes[managed["child"]["pid"]]["signals"] == []


def test_agent_pending_reconciliation(synthetic):
    managed = seed_managed(synthetic, candidate_only=True)
    synthetic.manager.stop()
    assert synthetic.processes[managed["child"]["pid"]]["exited"]
    assert not Path(managed["root"]).is_symlink()


def test_agent_generation_root_retention(synthetic):
    managed = seed_managed(synthetic)
    endpoint = socket.socket(socket.AF_UNIX)
    endpoint.bind(managed["socket"])
    Path(managed["socket"]).chmod(0o600)
    synthetic.manager.runner = lambda *a, **kw: SimpleNamespace(returncode=1)
    synthetic.manager.generation = "/nix/store/updated-openssh"
    env = synthetic.manager.prepare_environment({})
    assert env["SSH_AUTH_SOCK"] == managed["socket"]
    assert os.readlink(managed["root"]) == GEN
    assert synthetic.processes[managed["child"]["pid"]]["signals"] == []
    synthetic.manager.stop()
    endpoint.close()


def test_agent_lock_bounded_and_profile_before_agent(synthetic):
    manager = synthetic.manager
    manager._setup()
    with private_lock(manager.control / "agent.lock", timeout=0.1):
        with pytest.raises(AgentError, match="Timed out"):
            with private_lock(manager.control / "agent.lock", timeout=0.02):
                pass
    order = []

    @contextlib.contextmanager
    def profile():
        order.append("profile")
        try:
            yield
        finally:
            order.append("release-profile")

    manager.profile_lock = profile
    manager.popen = lambda *a, **kw: (_ for _ in ()).throw(OSError("spawn failed"))
    with pytest.raises(OSError):
        manager.prepare_environment({})
    assert order == ["profile", "release-profile"]
    assert not (manager.control / "intent.json").exists()


def test_agent_path_confinement_and_length(synthetic):
    manager = synthetic.manager
    manager._setup()
    runtime = synthetic.home.parents[1] / f"r{synthetic.manager.state_id[:4]}"
    runtime.mkdir(mode=0o755)
    assert (
        manager._socket_path({"XDG_RUNTIME_DIR": str(runtime)})
        == manager.control / "run/agent.sock"
    )
    runtime.chmod(0o700)
    assert manager._socket_path({"XDG_RUNTIME_DIR": str(runtime)}).is_relative_to(runtime)
    long_runtime = synthetic.home / ("x" * 100)
    long_runtime.mkdir(mode=0o700)
    with pytest.raises(AgentError, match="Unix socket limit"):
        manager._socket_path({"XDG_RUNTIME_DIR": str(long_runtime)})
    manager.control.rename(manager.control.with_name("old-agent"))
    manager.control.symlink_to(manager.control.with_name("old-agent"))
    with pytest.raises(AgentError, match="redirected"):
        manager._setup()


def test_agent_interactive_failure_clears_broken_metadata(synthetic, capsys, monkeypatch):
    monkeypatch.setattr(os, "isatty", lambda fd: True)
    manager = synthetic.manager
    manager.popen = lambda *a, **kw: (_ for _ in ()).throw(OSError("unavailable"))
    env = interactive_entry(
        SimpleNamespace(agent_manager=manager),
        {"SSH_AUTH_SOCK": "broken", "SSH_AGENT_PID": "1", "TERM": "xterm"},
    )
    assert env == {"TERM": "xterm"}
    assert "SSH agent unavailable" in capsys.readouterr().err


@pytest.mark.parametrize("field", ["start", "uid", "argv", "ppid", "association"])
def test_agent_stop_child_identity_validation(synthetic, field):
    managed = seed_managed(synthetic)
    process = synthetic.processes[managed["child"]["pid"]]
    if field == "association":
        process["bad_association"] = True
    else:
        process["identity"] = dict(process["identity"], **{field: "changed"})
    with pytest.raises(AgentError):
        synthetic.manager.stop()
    assert synthetic.processes[managed["supervisor"]["pid"]]["signals"] == []
    assert Path(managed["root"]).is_symlink()


def test_agent_adapter_non_tty_before_profile_access(monkeypatch):
    monkeypatch.setattr(os, "isatty", lambda fd: False)
    env = {"SSH_AUTH_SOCK": "inherited"}
    assert interactive_entry(object(), env) == env


def test_agent_actual_frame_adapter_snapshot_and_env(tmp_path, capsys):
    from frame.core import Frame

    home = tmp_path / "home"
    home.mkdir(mode=0o700)
    frame = Frame(home=home, state_dir=home / "state", environ={"HOME": str(home)})
    frame.paths.mkdir(frame.state)
    frame.paths.mkdir(frame.paths.store / "store" / Path(GEN).name)
    updated = "/nix/store/11111111111111111111111111111111-updated-frame-openssh"
    frame.paths.mkdir(frame.paths.store / "store" / Path(updated).name)
    generation = frame.state / "profile-1-link"
    generation.symlink_to(GEN)
    frame.profile.symlink_to(generation.name)
    manager = manager_for_frame(frame)
    assert manager.store_dir == frame.paths.store
    captured = []
    frame.namespace_argv = lambda argv, **kw: captured.append((argv, kw)) or argv
    env = {"FRAME_AGENT_LAUNCH_ID": "unique", "SSH_AUTH_SOCK": "selected"}
    assert manager._argv(["echo"], env) == ["echo"]
    assert captured[-1][1]["env"] == env
    generation.unlink()
    generation.symlink_to(updated)
    with frame.lock():
        manager._snapshot()
    assert manager.generation == updated
    assert manager.supervisor_python == manager.generation + "/bin/python3"
    assert handle_cli(frame, "status") == 0
    assert '"kind": "stopped"' in capsys.readouterr().out


@pytest.fixture
def real_agent(tmp_path):
    tools = {name: shutil.which(name) for name in ("ssh-agent", "ssh-add", "ssh-keygen")}
    if not all(tools.values()):
        pytest.skip("OpenSSH test tools unavailable")
    try:
        capability = ProcessHandle(os.getpid())
        capability.close()
    except CapabilityError as exc:
        pytest.skip(str(exc))
    home = tmp_path / "home"
    home.mkdir(mode=0o700)
    state = home / "state"
    runtime = tmp_path / "r"
    runtime.mkdir(mode=0o700)
    env = {"HOME": str(home), "PATH": os.defpath, "XDG_RUNTIME_DIR": str(runtime)}
    manager = AgentManager(
        home,
        state,
        store_dir=state / "store",
        generation=GEN,
        namespace_argv=lambda argv: argv,
        supervisor_python=sys.executable,
        agent_executable=tools["ssh-agent"],
        add_executable=tools["ssh-add"],
        timeout=2.0,
    )
    fixture = SimpleNamespace(manager=manager, env=env, home=home, tools=tools)
    try:
        yield fixture
    finally:
        status = manager.status({})
        if status.kind == "managed":
            manager.stop()
        elif status.kind == "conflict":
            manager.stop()
        assert not list((state / "store/var/nix/gcroots").glob("frame-agent-*"))


def test_agent_dependency_symlinks_use_selected_store(synthetic):
    manager = synthetic.manager
    manager._setup()
    package = "/nix/store/22222222222222222222222222222222-tools"
    selected = manager.store_dir / "store" / Path(GEN).name / "bin"
    tools = manager.store_dir / "store" / Path(package).name / "bin"
    selected.mkdir(mode=0o700, parents=True)
    tools.mkdir(mode=0o700, parents=True)
    for name in ("python3", "ssh-agent", "ssh-add"):
        physical = tools / name
        physical.write_text("selected executable fixture")
        physical.chmod(0o700)
        (selected / name).symlink_to(f"{package}/bin/{name}")
    manager.generation_factory = lambda: GEN
    manager.dependency_resolver = manager._dependency_path
    manager._snapshot()
    manager._validate_dependencies()
    assert manager._dependency_path(manager.agent_executable) == tools / "ssh-agent"
    (selected / "ssh-agent").unlink()
    (selected / "ssh-agent").symlink_to(sys.executable)
    with pytest.raises(AgentError, match="ssh-agent"):
        manager._validate_dependencies()


def test_agent_unapproved_intent_reconciles_without_launcher(synthetic):
    managed = seed_managed(synthetic)
    manager = synthetic.manager
    record = _read(manager.control / "intent.json", manager.uid)
    record["spawn_protocol"] = 1
    _write(manager.control / "intent.json", record, manager.uid)
    for name in ("candidate.json", "managed.json", "ack.json"):
        (manager.control / name).unlink()
    assert manager.status({}).kind == "stopped"
    assert not Path(managed["root"]).is_symlink()
    assert not (manager.control / "intent.json").exists()
    assert synthetic.processes[managed["child"]["pid"]]["signals"] == []


@pytest.mark.parametrize("executable", ["python3", "ssh-agent", "ssh-add"])
@pytest.mark.parametrize("failure", ["missing", "nonexec"])
def test_agent_selected_dependencies_before_intent(synthetic, executable, failure):
    manager = synthetic.manager
    manager._setup()
    selected = manager.store_dir / "store" / Path(GEN).name / "bin"
    selected.mkdir(mode=0o700, parents=True)
    for name in ("python3", "ssh-agent", "ssh-add"):
        path = selected / name
        path.write_text("test executable fixture")
        path.chmod(0o700)
    dependency = selected / executable
    if failure == "missing":
        dependency.unlink()
    else:
        dependency.chmod(0o600)
    manager.dependency_resolver = manager._dependency_path
    manager.generation_factory = lambda: GEN
    manager.popen = lambda *args, **kwargs: pytest.fail("Missing dependencies cannot launch")
    with pytest.raises(AgentError, match=f"/bin/{executable}"):
        manager.prepare_environment({})
    assert not (manager.control / "intent.json").exists()
    assert not list(manager.store_dir.glob("var/nix/gcroots/frame-agent-*"))


@pytest.mark.parametrize(
    "failure", ["helper", "supervisor_python", "supervisor_script", "helper_timeout"]
)
def test_agent_early_launcher_failure_is_recoverable(real_agent, monkeypatch, failure):
    manager = real_agent.manager
    original = manager.namespace_argv
    launched = []
    real_popen = manager.popen
    manager.timeout = 0.15

    def argv_factory(argv):
        if "--supervise" not in argv:
            return original(argv)
        if failure == "helper":
            return [
                "/bin/sh",
                "-c",
                'exec "$1"',
                "frame-test",
                str(real_agent.home / "missing-helper"),
            ]
        if failure == "supervisor_python":
            return [
                "/bin/sh",
                "-c",
                'exec "$@"',
                "frame-test",
                str(real_agent.home / "missing-python"),
                *argv[1:],
            ]
        if failure == "supervisor_script":
            return [argv[0], str(real_agent.home / "missing-supervisor.py"), *argv[2:]]
        return [sys.executable, "-c", "import time; time.sleep(30)"]

    def popen(*args, **kwargs):
        child = real_popen(*args, **kwargs)
        launched.append(child)
        return child

    manager.namespace_argv = argv_factory
    manager.popen = popen
    monkeypatch.setattr(os, "kill", lambda *args: pytest.fail("Numeric PID signal is forbidden"))
    monkeypatch.setattr(
        os, "killpg", lambda *args: pytest.fail("Numeric group signal is forbidden")
    )
    started = time.monotonic()
    with pytest.raises(AgentError):
        manager.prepare_environment(real_agent.env)
    assert time.monotonic() - started < 1.5
    assert launched[0].poll() is not None
    assert not (manager.control / "candidate.json").exists()
    assert not (manager.control / "intent.json").exists()
    assert not list(manager.store_dir.glob("var/nix/gcroots/frame-agent-*"))
    assert manager.status({}).kind == "stopped"
    manager.namespace_argv = original
    manager.timeout = 2.0
    assert manager.prepare_environment(real_agent.env)["SSH_AUTH_SOCK"]
    manager.stop()


def test_agent_hard_death_after_spawn_authorization_keeps_root(real_agent, monkeypatch):
    manager = real_agent.manager
    launched = []
    real_popen = manager.popen
    manager.timeout = 0.1
    monkeypatch.setattr(os, "kill", lambda *args: pytest.fail("Numeric PID signal is forbidden"))

    def popen(*args, **kwargs):
        child = real_popen(*args, **kwargs)
        launched.append(child)
        return child

    def interrupt(name):
        if name == "spawn_authorized":
            # Host still holds agent.lock. The test proves death after durable
            # authorization is ambiguous, even before any candidate is visible.
            handle = ProcessHandle(launched[0].pid)
            try:
                handle.send(signal.SIGKILL)
                assert handle.wait(1.0)
            finally:
                handle.close()
            raise InterruptedError("authorized hard death")

    manager.popen = popen
    manager.boundary = interrupt
    with pytest.raises(AgentError, match="unresolved"):
        manager.prepare_environment(real_agent.env)
    record = _read(manager.control / "intent.json", manager.uid)
    assert record is not None
    assert Path(record["root"]).is_symlink()
    assert (manager.control / "spawn.json").exists()
    assert not (manager.control / "candidate.json").exists()
    assert manager.status({}).kind == "conflict"
    # The test injected death while holding the same lock that prevents fork.
    # Only the fixture has this additional no-child proof; production does not.
    with manager.profile_lock(), manager._lock():
        _write(
            manager.control / "exited.json",
            {
                "launch_id": record["launch_id"],
                "confirmed": True,
            },
            manager.uid,
        )
        manager._cleanup(record)


def _seed_supervisor_intent(real_agent, monkeypatch):
    manager = real_agent.manager
    manager._setup()
    socket_path = manager._socket_path(real_agent.env)
    token = "b" * 32
    record = {
        "version": 1,
        "home": str(manager.home),
        "state": str(manager.state_dir),
        "uid": manager.uid,
        "boot": manager.boot_reader(),
        "launch_id": token,
        "generation": manager.generation,
        "socket": str(socket_path),
        "root": str(manager._root_path(token)),
        "agent_exe": manager.agent_executable,
        "add_exe": manager.add_executable,
        "timeout": 1.0,
        "probe_timeout": 0.2,
    }
    manager._root(record)
    _write(manager.control / "intent.json", record, manager.uid)
    _write(manager.control / "spawn.json", {"launch_id": token}, manager.uid)
    monkeypatch.setenv("FRAME_AGENT_LAUNCH_ID", token)
    monkeypatch.setattr(os, "kill", lambda *args: pytest.fail("Numeric PID signal is forbidden"))
    monkeypatch.setattr(
        os, "killpg", lambda *args: pytest.fail("Numeric group signal is forbidden")
    )
    return record


def _run_test_supervisor(manager, **kwargs):
    handled = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
    previous = {sig: signal.getsignal(sig) for sig in handled}
    try:
        return _supervise(manager.control, **kwargs)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def _assert_gated_supervisor_cleanup(real_agent, record, children):
    manager = real_agent.manager
    assert len(children) == 1
    child = children[0]
    assert child.pid is not None and child.confirmed
    if not child.released:
        assert child.returncode == 125
    assert child.stdout.closed
    assert child.gate is None
    with pytest.raises(ChildProcessError):
        os.waitpid(child.pid, os.WNOHANG)
    assert _read(manager.control / "exited.json", manager.uid) == {
        "launch_id": record["launch_id"],
        "confirmed": True,
    }
    assert not Path(record["root"]).is_symlink()
    assert not (manager.control / "candidate.json").exists()
    assert manager.status({}).kind == "stopped"


@pytest.mark.parametrize("failure", ["capability", "emfile", "enfile", "enomem", "association"])
def test_agent_supervisor_actual_child_pidfd_failure(real_agent, monkeypatch, failure):
    record = _seed_supervisor_intent(real_agent, monkeypatch)
    children = []
    original_open = os.pidfd_open
    supervisor_pid = os.getpid()
    resource_errors = {"emfile": errno.EMFILE, "enfile": errno.ENFILE, "enomem": errno.ENOMEM}

    def pidfd_open(pid, flags=0):
        if pid != supervisor_pid and failure in resource_errors:
            raise OSError(resource_errors[failure], "injected actual-child pidfd failure")
        return original_open(pid, flags)

    monkeypatch.setattr(os, "pidfd_open", pidfd_open)

    def handles(pid):
        if pid != supervisor_pid and failure == "capability":
            raise CapabilityError("Actual child pidfd capability unavailable")
        handle = ProcessHandle(pid)
        if pid != supervisor_pid and failure == "association":
            handle.associated = lambda _pid: False
        return handle

    def child_factory(*args, **kwargs):
        child = _GatedChild(*args, **kwargs)
        children.append(child)
        return child

    with pytest.raises(AgentError):
        _run_test_supervisor(
            real_agent.manager, child_factory=child_factory, handle_factory=handles
        )
    assert not children[0].released
    assert not Path(record["socket"]).exists()
    _assert_gated_supervisor_cleanup(real_agent, record, children)


@pytest.mark.parametrize("boundary", ["fork", "pidfd", "before_release", "release"])
def test_agent_supervisor_gated_spawn_interruption(real_agent, monkeypatch, boundary):
    record = _seed_supervisor_intent(real_agent, monkeypatch)
    children = []

    def interrupt(name, child):
        if name == boundary:
            if name != "release":
                assert not child.released
                assert not Path(record["socket"]).exists()
            raise InterruptedError(name)

    def child_factory(*args, **kwargs):
        child = _GatedChild(*args, **kwargs, boundary=interrupt)
        children.append(child)
        return child

    with pytest.raises(InterruptedError, match=boundary):
        _run_test_supervisor(real_agent.manager, child_factory=child_factory)
    _assert_gated_supervisor_cleanup(real_agent, record, children)


@pytest.mark.parametrize("boundary", ["fork", "pidfd", "release"])
def test_agent_supervisor_pending_signal_during_gated_spawn(real_agent, monkeypatch, boundary):
    record = _seed_supervisor_intent(real_agent, monkeypatch)
    children = []

    def interrupt(name, child):
        if name == boundary:
            # Delivery during spawn is deferred until the parent owns the
            # unreaped child and either its gate or its retained pidfd.
            signal.raise_signal(signal.SIGTERM)

    def child_factory(*args, **kwargs):
        child = _GatedChild(*args, **kwargs, boundary=interrupt)
        children.append(child)
        return child

    with pytest.raises(InterruptedError, match="supervisor interrupted"):
        _run_test_supervisor(real_agent.manager, child_factory=child_factory)
    _assert_gated_supervisor_cleanup(real_agent, record, children)


def test_agent_supervisor_cancel_after_fork_before_exec(real_agent, monkeypatch):
    record = _seed_supervisor_intent(real_agent, monkeypatch)
    children = []

    def cancel(name, child):
        if name == "pidfd":
            assert not child.released
            assert not Path(record["socket"]).exists()
            _write(
                real_agent.manager.control / "cancel.json",
                {"launch_id": record["launch_id"]},
                real_agent.manager.uid,
            )

    def child_factory(*args, **kwargs):
        child = _GatedChild(*args, **kwargs, boundary=cancel)
        children.append(child)
        return child

    _run_test_supervisor(real_agent.manager, child_factory=child_factory)
    assert not children[0].released
    assert not Path(record["socket"]).exists()
    _assert_gated_supervisor_cleanup(real_agent, record, children)


def test_agent_real_empty_reuse_and_private_transport(real_agent):
    manager = real_agent.manager
    env = manager.prepare_environment(real_agent.env)
    record = _read(manager.control / "managed.json", manager.uid)
    assert manager.status(real_agent.env).kind == "managed"
    assert manager.status(env).kind == "managed"
    inherited = dict(env, SSH_AGENT_PID="untrusted")
    assert manager.prepare_environment(inherited) == inherited
    assert manager.prepare_environment(real_agent.env)["SSH_AUTH_SOCK"] == env["SSH_AUTH_SOCK"]
    assert "SSH_AGENT_PID" not in env
    path = Path(env["SSH_AUTH_SOCK"])
    assert stat.S_ISSOCK(path.lstat().st_mode) and path.lstat().st_uid == os.getuid()
    assert not path.lstat().st_mode & 0o077
    for fd in (0, 1, 2):
        target = os.readlink(f"/proc/{record['supervisor']['pid']}/fd/{fd}")
        assert "/dev/pts" not in target
    assert os.readlink(f"/proc/{record['supervisor']['pid']}/fd/0") == "/dev/null"
    assert (manager.control / "agent.log").stat().st_size <= 65536
    manager.stop()


def test_agent_concurrent_start_once(real_agent):
    manager = real_agent.manager
    barrier = threading.Barrier(4)

    def start():
        barrier.wait()
        return manager.prepare_environment(real_agent.env)["SSH_AUTH_SOCK"]

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: start(), range(4)))
    assert len(set(results)) == 1
    roots = list((manager.store_dir / "var/nix/gcroots").glob("frame-agent-*"))
    assert len(roots) == 1
    manager.stop()


def test_agent_concurrent_stop_start(real_agent):
    manager = real_agent.manager
    manager.prepare_environment(real_agent.env)
    barrier = threading.Barrier(2)

    def stop():
        barrier.wait()
        return manager.stop()

    def start():
        barrier.wait()
        return manager.prepare_environment(real_agent.env)

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(stop), pool.submit(start)]
        for future in futures:
            future.result()
    assert manager.status({}).kind in ("managed", "stopped")
    roots = list((manager.store_dir / "var/nix/gcroots").glob("frame-agent-*"))
    assert len(roots) <= 1
    manager.stop()


@pytest.mark.parametrize(
    "boundary",
    [
        "before_intent",
        "intent",
        "root",
        "spawn",
        "supervisor_ready",
        "spawn_authorized",
        "candidate",
        "before_publication",
        "publication",
        "before_acknowledgement",
        "acknowledgement",
    ],
)
def test_agent_spawn_publication_interruption(real_agent, boundary):
    manager = real_agent.manager

    def interrupt(name):
        if name == boundary:
            raise InterruptedError(name)

    manager.boundary = interrupt
    with pytest.raises(InterruptedError, match=boundary):
        manager.prepare_environment(real_agent.env)
    if boundary == "acknowledgement":
        assert manager.status({}).kind == "managed"
        manager.stop()
    else:
        assert manager.status({}).kind == "stopped"
    assert not list((manager.store_dir / "var/nix/gcroots").glob("frame-agent-*"))


def test_agent_real_live_missing_socket(real_agent):
    manager = real_agent.manager
    env = manager.prepare_environment(real_agent.env)
    old = _read(manager.control / "managed.json", manager.uid)
    Path(env["SSH_AUTH_SOCK"]).unlink()
    new_env = manager.prepare_environment(real_agent.env)
    new = _read(manager.control / "managed.json", manager.uid)
    assert old["launch_id"] != new["launch_id"]
    assert not Path(old["root"]).is_symlink()
    assert new_env["SSH_AUTH_SOCK"] == new["socket"]
    manager.stop()


def test_frame_ssh_agent_scenario(real_agent):
    manager = real_agent.manager
    env = manager.prepare_environment(real_agent.env)
    key = real_agent.home / "test-key"
    subprocess.run(
        [real_agent.tools["ssh-keygen"], "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
        env=env,
        check=True,
        timeout=5,
    )
    add = subprocess.run(
        [real_agent.tools["ssh-add"], str(key)], env=env, capture_output=True, check=True, timeout=5
    )
    assert add.returncode == 0
    listed = subprocess.run(
        [real_agent.tools["ssh-add"], "-l"], env=env, capture_output=True, check=True, timeout=5
    )
    assert b"ED25519" in listed.stdout
    message = real_agent.home / "message"
    message.write_bytes(b"Frame ephemeral signing test\n")
    subprocess.run(
        [
            real_agent.tools["ssh-keygen"],
            "-Y",
            "sign",
            "-n",
            "frame-test",
            "-f",
            str(key) + ".pub",
            str(message),
        ],
        env=env,
        capture_output=True,
        check=True,
        timeout=5,
    )
    assert Path(str(message) + ".sig").read_bytes().startswith(b"-----BEGIN SSH SIGNATURE-----")
    manager.stop()
