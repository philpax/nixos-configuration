"""Activation tests use only synthetic homes and host Bash processes."""

import json
import os
import pty
import select
import shlex
import shutil
import stat
import subprocess
import time
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace

import pytest
import tomllib

from frame.activation import BEGIN, END, Activation, ActivationError, handle_cli

BASH = shutil.which("bash")
REFRESH_FONTS = Activation.refresh_fonts


class FakeFrame:
    def __init__(self, home, repo):
        self.home = home
        self.state = home / "state with spaces"
        self.repo = repo
        self.environ = {"HOME": str(home), "PATH": "/usr/bin:/bin"}
        self.current = None
        self.readiness_calls = 0

    @contextmanager
    def lock(self):
        yield

    def validate_profile(self):
        return self.current

    def readiness(self, *, activation=False):
        assert activation
        self.readiness_calls += 1


@pytest.fixture
def setup(tmp_path, monkeypatch):
    home = tmp_path / "home with 'quotes' and spaces"
    home.mkdir()
    frame = FakeFrame(home, Path(__file__).resolve().parents[1])
    activation = Activation(frame)
    monkeypatch.setattr(Activation, "refresh_fonts", lambda self, path: None)
    frame.current = str(make_profile(home, "one"))
    return frame, activation


def write(path, content, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content if isinstance(content, bytes) else content.encode())
    path.chmod(mode)


def make_profile(home, name):
    profile = home / "sources" / ("profile-" + name)
    fonts = home / "sources" / ("font-" + name)
    ocean = home / "sources" / ("ocean-" + name)
    write(fonts / "share/fonts/truetype/family/font.ttf", ("font-" + name).encode())
    write(fonts / "share/fonts/truetype/family/LICENSE", "family companion")
    (fonts / "share/fonts/truetype/family/alias.ttf").symlink_to("font.ttf")
    write(ocean / "share/sounds/ocean/stereo/bell.oga", ("bell-" + name).encode())
    refs = profile / "share/frame-cli/assets"
    (refs / "fonts").mkdir(parents=True)
    (refs / "fonts" / name).symlink_to(fonts)
    (refs / "bell").symlink_to(ocean)
    write(
        profile / "share/frame-cli/assets.json",
        json.dumps(
            {
                "fonts": [{"path": str(fonts), "reference": "fonts/" + name}],
                "bell": {
                    "reference": "bell",
                    "path": str(ocean),
                    "relativePath": "share/sounds/ocean/stereo/bell.oga",
                },
            }
        ),
    )
    return profile


def install_fake_wrapper(frame, *, ready=True):
    log = frame.home / "handoff.log"
    wrapper = frame.home / ".local/bin/frame-cli"
    script = (
        f"#!{BASH}\n"
        'if [ "$1" = --home ]; then shift 4; fi\n'
        'if [ "$1" = ready ]; then exit ' + ("0" if ready else "1") + "; fi\n"
        'printf \'%s|%s|%s|%s\\n\' "$1" "${PATH-}" "${XDG_CONFIG_HOME-}" '
        '"${SSH_AUTH_SOCK-}" >> ' + shlex.quote(str(log)) + "\n"
        "printf 'FRAME-HANDOFF\\n'\n"
    )
    write(wrapper, script, 0o755)
    return log


def apply(activation):
    return activation.apply(activation.plan(), confirmed=True)


def snapshot(home):
    return {
        str(path.relative_to(home)): (
            stat.S_IMODE(path.lstat().st_mode),
            os.readlink(path)
            if path.is_symlink()
            else path.read_bytes()
            if path.is_file()
            else None,
        )
        for path in home.rglob("*")
    }


def run_pty(command, env):
    master, slave = pty.openpty()
    process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    output = bytearray()
    deadline = time.monotonic() + 8
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                output.extend(data)
            if process.poll() is not None:
                break
        process.wait(timeout=1)
        while select.select([master], [], [], 0)[0]:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            output.extend(data)
        return process.returncode, output.decode(errors="replace")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


def bash(frame, *, login=False, interactive=True, tty=True, extra=None):
    env = {**frame.environ, **(extra or {})}
    if login:
        # Bash --login uses the account home, not HOME, for its own initial lookup.
        # Source the selected login file in an actual login-shell process.
        name = next(
            (
                name
                for name in (".bash_profile", ".bash_login", ".profile")
                if (frame.home / name).exists()
            ),
            ".bash_profile",
        )
        command = [BASH, "--noprofile", "--norc", "-l"]
        if interactive:
            command.append("-i")
        command += ["-c", '. "$HOME/' + name + '"; printf "BASH-RETAINED\\n"']
    else:
        command = [BASH, "--noprofile", "--rcfile", str(frame.home / ".bashrc")]
        if interactive:
            command.append("-i")
        command += [
            "-c",
            '. "$HOME/.bashrc"; printf "BASH-RETAINED\\n"'
            if not interactive
            else 'printf "BASH-RETAINED\\n"',
        ]
    if tty:
        return run_pty(command, env)
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=5)
    return result.returncode, result.stdout + result.stderr


def test_activation_dry_run_no_mutation(setup):
    frame, activation = setup
    before = snapshot(frame.home)
    selected = SimpleNamespace(describe=lambda: "sync link plan")
    plan = activation.plan(sync_plan=selected)
    assert "sync link plan" in plan.describe()
    assert len(plan.operations) == 7
    assert snapshot(frame.home) == before
    with pytest.raises(ActivationError, match="confirmation"):
        activation.apply(plan)
    assert snapshot(frame.home) == before


def test_activation_single_confirmation(setup, monkeypatch):
    import home_sync

    frame, _ = setup
    prompts, output, calls = [], [], []
    apply_sync = home_sync.apply_home_sync

    def applied(plan, **kwargs):
        calls.append(plan)
        return apply_sync(plan, **kwargs)

    monkeypatch.setattr(home_sync, "apply_home_sync", applied)
    assert (
        handle_cli(
            frame,
            confirm=lambda text: prompts.append(text) or True,
            output=output.append,
        )
        == 0
    )
    assert prompts == [output[0]]
    assert "Imported layers: common-all" in prompts[0]
    assert "Shell startup" in prompts[0]
    assert len(calls) == 1
    assert Activation(frame).status()["complete"]


@pytest.mark.parametrize("config", ["relative", "/tmp/config", "outside", "traversal"])
def test_activation_xdg_config_policy(setup, config):
    frame, activation = setup
    bad = {
        "relative": ".config",
        "outside": str(frame.home / "other"),
        "traversal": str(frame.home / "a/../.config"),
        " /tmp/config": "/tmp/config",
    }.get(config, config)
    activation.env["XDG_CONFIG_HOME"] = bad
    before = snapshot(frame.home)
    with pytest.raises(ActivationError, match="XDG_CONFIG_HOME"):
        activation.plan()
    assert snapshot(frame.home) == before


def test_activation_font_xdg_confines_and_records(setup):
    frame, activation = setup
    activation.env["XDG_DATA_HOME"] = str(frame.home / "custom data")
    apply(activation)
    assert activation.read_manifest()["font_dir"] == str(frame.home / "custom data/fonts/frame-cli")
    activation.env["XDG_DATA_HOME"] = str(frame.home / "different")
    with pytest.raises(ActivationError, match="changed"):
        activation.prepare(frame.current)
    activation.env["XDG_DATA_HOME"] = "/tmp"
    with pytest.raises(ActivationError, match="outside home"):
        activation.plan()


def test_activation_generated_file_conflicts(setup):
    frame, activation = setup
    machine = frame.home / ".config/ghostty/machine"
    write(machine, "user config")
    result = apply(activation)
    assert not result["complete"]
    assert machine.read_text() == "user config"
    terminal = frame.home / ".config/alacritty/machine.toml"
    terminal.write_text("changed by user")
    result = apply(activation)
    assert not result["complete"] and terminal.read_text() == "changed by user"
    assert str(terminal) in activation.status()["changed"]


def test_generated_partial_failure_records_progress(setup, monkeypatch):
    _, activation = setup
    original = activation._atomic
    fail_at = activation.home / ".config/ghostty/machine"

    def fail(path, *args):
        if path == fail_at:
            raise OSError("injected write failure")
        return original(path, *args)

    monkeypatch.setattr(activation, "_atomic", fail)
    with pytest.raises(OSError, match="injected"):
        apply(activation)
    manifest = activation.read_manifest()
    assert str(activation.state / "auto-enter.bash") in manifest["owned"]
    monkeypatch.setattr(activation, "_atomic", original)
    apply(activation)
    assert activation.status()["complete"]


def test_bash_hook_preserves_and_backs_up_files(setup):
    frame, activation = setup
    originals = {".bashrc": b"# bytes\xff\r\nexport TEST=1", ".profile": b"export PROFILE=1\n"}
    for name, original in originals.items():
        write(frame.home / name, original, 0o640)
    apply(activation)
    manifest = activation.read_manifest()
    for name, original in originals.items():
        path = frame.home / name
        assert path.read_bytes().startswith(original)
        assert path.read_bytes().count(BEGIN) == path.read_bytes().count(END) == 1
        assert stat.S_IMODE(path.stat().st_mode) == 0o640
        backup = Path(manifest["backups"][str(path)])
        assert backup.read_bytes() == original
        assert stat.S_IMODE(backup.stat().st_mode) == 0o640


def test_bash_hook_idempotent_and_conflict_safe(setup):
    frame, activation = setup
    write(frame.home / ".bashrc", "# preexisting\n", 0o600)
    apply(activation)
    before = {
        path: path.read_bytes() for path in (frame.home / ".bashrc", frame.home / ".bash_profile")
    }
    backups = activation.read_manifest()["backups"].copy()
    apply(activation)
    assert all(path.read_bytes() == content for path, content in before.items())
    assert activation.read_manifest()["backups"] == backups
    write(frame.home / ".bashrc", BEGIN + b"\n" + BEGIN + b"\n" + END + b"\n")
    plan = activation.plan()
    assert any(op.path.name == ".bashrc" and "markers" in op.conflict for op in plan.conflicts)
    link = frame.home / ".bash_profile"
    link.unlink()
    link.symlink_to(frame.home / ".bashrc")
    assert any(op.path == link and op.conflict for op in activation.plan().conflicts)


@pytest.mark.parametrize("active", [".bash_profile", ".bash_login", ".profile"])
def test_bash_login_file_precedence(setup, active):
    frame, activation = setup
    names = [".bash_profile", ".bash_login", ".profile"]
    for name in names[names.index(active) :]:
        write(frame.home / name, "# " + name + "\n")
    apply(activation)
    for name in names[names.index(active) :]:
        assert (BEGIN in (frame.home / name).read_bytes()) == (name == active)


@pytest.mark.parametrize("profile", [".bash_profile", ".profile"])
def test_bash_login_rc_defers_until_profile_end(setup, profile):
    frame, activation = setup
    log = install_fake_wrapper(frame)
    write(
        frame.home / profile,
        '. "$HOME/.bashrc"\n'
        'export PATH="/sentinel:$PATH"\n'
        'export XDG_CONFIG_HOME="$HOME/.config"\n'
        'export SSH_AUTH_SOCK="$HOME/sentinel.sock"\n',
    )
    apply(activation)
    code, output = bash(frame, login=True)
    assert code == 0 and "FRAME-HANDOFF" in output and "BASH-RETAINED" not in output
    lines = log.read_text().splitlines()
    assert len(lines) == 1
    assert lines[0].startswith("enter|/sentinel:")
    assert str(frame.home / ".config") in lines[0]
    assert str(frame.home / "sentinel.sock") in lines[0]


@pytest.mark.parametrize("login", [False, True])
@pytest.mark.parametrize(
    "interactive,tty,extra,enters",
    [
        (True, True, {}, True),
        (False, True, {}, False),
        (False, False, {}, False),
        (True, False, {}, False),
        (True, True, {"FRAME_CLI_NO_AUTO": "1"}, False),
        (True, True, {"FRAME_CLI_ACTIVE": "1"}, False),
        (True, True, {"FRAME_CLI_ACTIVE": ""}, False),
    ],
)
def test_bash_auto_entry_matrix(setup, login, interactive, tty, extra, enters):
    frame, activation = setup
    log = install_fake_wrapper(frame)
    apply(activation)
    code, output = bash(frame, login=login, interactive=interactive, tty=tty, extra=extra)
    assert code == 0
    assert ("FRAME-HANDOFF" in output) == enters
    assert log.exists() == enters
    if not enters:
        assert "BASH-RETAINED" in output
    if not interactive:
        assert "frame-cli:" not in output


def test_bash_hook_missing_profile_fallback(setup):
    frame, activation = setup
    log = install_fake_wrapper(frame, ready=False)
    apply(activation)
    _, output = bash(frame)
    assert "BASH-RETAINED" in output and output.count("frame-cli:") == 1
    assert not log.exists()
    (frame.home / ".local/bin/frame-cli").unlink()
    _, output = bash(frame)
    assert "BASH-RETAINED" in output and output.count("frame-cli:") == 1


def test_profile_is_posix_safe(setup):
    frame, activation = setup
    write(frame.home / ".profile", 'printf "PROFILE-OK\\n"\n')
    apply(activation)
    result = subprocess.run(
        ["/bin/sh", "-c", '. "$HOME/.profile"'],
        env=frame.environ,
        capture_output=True,
        text=True,
        timeout=5,
    )
    assert result.returncode == 0 and result.stdout == "PROFILE-OK\n" and result.stderr == ""


def test_font_export_dereferences_and_confines(setup):
    frame, activation = setup
    name = activation.export(frame.current)
    directory = activation.assets / "generations" / name
    assert not any(path.is_symlink() for path in directory.rglob("*"))
    assert (directory / "fonts/one/truetype/family/alias.ttf").read_bytes() == b"font-one"
    assert (directory / "fonts/one/truetype/family/LICENSE").read_text() == "family companion"
    assert (directory / "bell-window-system.oga").read_bytes() == b"bell-one"
    source = frame.home / "sources/font-one/share/fonts/truetype/family/alias.ttf"
    source.unlink()
    source.symlink_to(frame.home / "sources/ocean-one/share/sounds/ocean/stereo/bell.oga")
    with pytest.raises(ActivationError, match="escapes declared"):
        activation.export(frame.current)
    assert (directory / "fonts/one/truetype/family/alias.ttf").read_bytes() == b"font-one"


def test_asset_publication_failure_keeps_old_generation(setup, monkeypatch):
    frame, activation = setup
    apply(activation)
    original = os.readlink(activation.assets / "current")
    old_profile = frame.current
    candidate = make_profile(frame.home, "two")
    prepared = activation.prepare(candidate)
    assert frame.current == old_profile
    assert os.readlink(activation.assets / "current") == original
    frame.current = str(candidate)
    old_pointer = activation._pointer
    monkeypatch.setattr(activation, "_pointer", lambda _: (_ for _ in ()).throw(OSError("publish")))
    with pytest.raises(OSError, match="publish"):
        activation.publish(prepared)
    assert os.readlink(activation.assets / "current") == original
    assert activation.status()["mismatch"]
    monkeypatch.setattr(activation, "_pointer", old_pointer)
    activation.reconcile()
    assert not activation.status()["mismatch"]
    assert (activation.assets / "current/bell-window-system.oga").read_bytes() == b"bell-two"


def test_activation_update_rollback_reconciliation(setup):
    frame, activation = setup
    apply(activation)
    startup = (frame.home / ".bashrc").read_bytes()
    first = frame.current
    second = str(make_profile(frame.home, "two"))
    activation.prepare(second)
    activation.reconcile()  # Interrupted before the profile switch.
    assert not activation.journal_path.exists()
    assert (activation.assets / "current/bell-window-system.oga").read_bytes() == b"bell-one"
    activation.prepare(second)
    frame.current = second
    activation.reconcile()  # Interrupted after the profile switch.
    assert not activation.status()["mismatch"]
    prepared = activation.prepare(first)
    frame.current = first
    activation.publish(prepared)
    assert (activation.assets / "current/bell-window-system.oga").read_bytes() == b"bell-one"
    assert (frame.home / ".bashrc").read_bytes() == startup


def test_prepare_changed_generated_files_stops_before_switch(setup):
    frame, activation = setup
    apply(activation)
    machine = frame.home / ".config/ghostty/machine"
    machine.write_text("user modification")
    with pytest.raises(ActivationError, match="changed"):
        activation.prepare(make_profile(frame.home, "two"))
    assert not activation.journal_path.exists()
    assert (activation.assets / "current/bell-window-system.oga").read_bytes() == b"bell-one"


def test_terminal_generated_paths_and_commands(setup):
    frame, activation = setup
    log = install_fake_wrapper(frame)
    apply(activation)
    alacritty = tomllib.loads((frame.home / ".config/alacritty/machine.toml").read_text())
    assert alacritty["terminal"]["shell"] == {
        "program": str(frame.home / ".local/bin/frame-cli"),
        "args": ["--home", str(frame.home), "--state-dir", str(frame.state), "enter"],
    }
    ghostty = (frame.home / ".config/ghostty/machine").read_text()
    command = ghostty.splitlines()[0].removeprefix("command = ")
    assert "initial-command" not in ghostty
    code, output = run_pty(shlex.split(command), frame.environ)
    assert code == 0 and "FRAME-HANDOFF" in output and log.exists()
    bell = Path(ghostty.splitlines()[1].removeprefix("bell-audio-path = "))
    assert bell.read_bytes() == b"bell-one"
    assert "/nix/" not in ghostty


def test_parent_symlink_escape_prevents_mutation(setup, tmp_path):
    frame, activation = setup
    outside = tmp_path / "outside"
    outside.mkdir()
    (frame.home / ".config").symlink_to(outside)
    before = snapshot(frame.home)
    with pytest.raises(ActivationError, match="unsafe activation parent"):
        activation.plan()
    assert snapshot(frame.home) == before
    assert list(outside.iterdir()) == []


def test_startup_user_bytes_retained_and_changed_block_protected(setup):
    frame, activation = setup
    apply(activation)
    startup = frame.home / ".bashrc"
    with startup.open("ab") as stream:
        stream.write(b"export USER_ADDITION=yes\n")
    apply(activation)
    content = startup.read_bytes()
    assert content.index(b"export USER_ADDITION=yes") < content.index(BEGIN)
    startup.write_bytes(content.replace(b"case $- in", b"case user_edit in"))
    plan = activation.plan()
    assert any(op.path == startup and op.conflict for op in plan.conflicts)
    apply(activation)
    assert b"case user_edit in" in startup.read_bytes()


def test_asset_destination_symlink_rejected(setup):
    frame, activation = setup
    outside = frame.home / "other-assets"
    outside.mkdir()
    activation.assets.mkdir(parents=True)
    (activation.assets / "generations").symlink_to(outside)
    with pytest.raises(ActivationError, match="redirected|unsafe activation parent"):
        activation.export(frame.current)
    assert list(outside.iterdir()) == []


@pytest.mark.parametrize("companion_link", [None, "absolute", "relative"])
def test_selected_store_absolute_symlink_export(setup, companion_link):
    frame, _ = setup
    from frame.core import Frame

    real = Frame(frame.home, frame.state, repo=frame.repo, environ=frame.environ)
    store = frame.state / "store/store"
    names = {
        "profile": "a" * 32 + "-profile",
        "fonts": "b" * 32 + "-fonts",
        "bell": "c" * 32 + "-bell",
        "metadata": "d" * 32 + "-metadata",
        "companion": "e" * 32 + "-minimal",
    }
    logical = {key: Path("/nix/store") / name for key, name in names.items()}
    physical = {key: store / name for key, name in names.items()}
    write(physical["fonts"] / "share/fonts/family/font.ttf", "store-font")
    write(physical["companion"] / "share/fonts/family/font.ttf", "companion-store-font")
    target_output = "companion" if companion_link else "fonts"
    target = logical[target_output] / "share/fonts/family/font.ttf"
    if companion_link == "relative":
        target = Path(os.path.relpath(target, logical["fonts"] / "share/fonts/family"))
    (physical["fonts"] / "share/fonts/family/alias.ttf").symlink_to(target)
    font_record = {"path": str(logical["fonts"]), "reference": "fonts/selected"}
    if companion_link:
        font_record["companions"] = [
            {
                "reference": "font-companions/selected-0-minimal-out",
                "path": str(logical["companion"]),
            }
        ]
    write(physical["bell"] / "share/sounds/ocean/stereo/bell.oga", "store-bell")
    assets = physical["metadata"] / "share/frame-cli/assets"
    (assets / "fonts").mkdir(parents=True)
    (assets / "fonts/selected").symlink_to(logical["fonts"])
    (assets / "bell").symlink_to(logical["bell"])
    if companion_link:
        (assets / "font-companions").mkdir()
        (assets / "font-companions/selected-0-minimal-out").symlink_to(logical["companion"])
    write(
        physical["metadata"] / "share/frame-cli/assets.json",
        json.dumps(
            {
                "fonts": [font_record],
                "bell": {
                    "path": str(logical["bell"]),
                    "reference": "bell",
                    "relativePath": "share/sounds/ocean/stereo/bell.oga",
                },
            }
        ),
    )
    (physical["profile"] / "share").mkdir(parents=True)
    (physical["profile"] / "share/frame-cli").symlink_to(logical["metadata"] / "share/frame-cli")
    activation = Activation(real)
    generation = activation.export(str(logical["profile"]))
    font = activation.assets / "generations" / generation / "fonts/selected/family/alias.ttf"
    expected = b"companion-store-font" if companion_link else b"store-font"
    assert not font.is_symlink() and font.read_bytes() == expected


def test_cli_combines_real_sync_dryrun_and_declined_confirmation(setup):
    frame, _ = setup
    before = snapshot(frame.home)
    lines = []
    assert handle_cli(frame, dry_run=True, output=lines.append) == 0
    assert "Imported layers: common-all" in lines[0]
    assert "Agent skills (personal)" in lines[0]
    assert ".config/fish/config.fish" in lines[0]
    assert snapshot(frame.home) == before
    prompts = []
    assert (
        handle_cli(frame, input_fn=lambda text: prompts.append(text) or "n", output=lines.append)
        == 1
    )
    assert len(prompts) == 1
    assert snapshot(frame.home) == before


def test_initial_activation_publication_interruption_retry(setup, monkeypatch):
    _, activation = setup
    pointer = activation._pointer
    monkeypatch.setattr(activation, "_pointer", lambda _: (_ for _ in ()).throw(OSError("publish")))
    with pytest.raises(OSError, match="publish"):
        apply(activation)
    assert activation.read_manifest() is not None
    assert activation.status()["mismatch"]
    monkeypatch.setattr(activation, "_pointer", pointer)
    apply(activation)
    assert activation.status()["complete"] and not activation.status()["mismatch"]


def test_sync_conflicts_defer_startup_handoff(setup):
    frame, activation = setup
    selected = SimpleNamespace(
        conflicts=(
            SimpleNamespace(
                destination=frame.home / ".config/fish/config.fish", conflict="user file"
            ),
        )
    )
    plan = activation.plan(sync_plan=SimpleNamespace(plan=selected))
    result = activation.apply(plan, confirmed=True)
    assert not result["complete"]
    assert not (frame.home / ".bashrc").exists()
    assert not (frame.home / ".bash_profile").exists()


def test_cli_confirmation_change_rejected(setup):
    frame, _ = setup

    def confirm(_):
        write(frame.home / ".bashrc", "user added this after review\n")
        return True

    messages = []
    assert handle_cli(frame, confirm=confirm, output=messages.append) == 1
    assert any("changed after confirmation" in message for message in messages)
    assert (frame.home / ".bashrc").read_text() == "user added this after review\n"
    assert not (frame.state / "activation.json").exists()


def test_font_validation_records_host_query_without_claiming_required_families(setup, monkeypatch):
    frame, activation = setup
    apply(activation)
    calls = []
    font_dir = Path(activation.read_manifest()["font_dir"])

    def run(argv, **kwargs):
        calls.append((argv, kwargs))
        output = str(font_dir / "family/font.ttf") + "\tCozette\n"
        return SimpleNamespace(returncode=0, stdout=output, stderr="")

    monkeypatch.setattr(shutil, "which", lambda name, **kwargs: "/usr/bin/" + name)
    monkeypatch.setattr(subprocess, "run", run)
    REFRESH_FONTS(activation, font_dir)
    report = activation.status()["font_validation"]
    assert report["context"] == "host"
    assert report["families"] == ["Cozette"]
    assert report["owned_fonts_discovered"]
    assert not report["required_families_verified"]
    assert calls[0][0] == ["/usr/bin/fc-cache", "-f", str(font_dir)]
    assert all("/nix/" not in str(argv) for argv, _ in calls)


def test_generated_failure_retains_unvisited_ownership(setup, monkeypatch):
    _, activation = setup
    apply(activation)
    previous = activation.read_manifest()["owned"].copy()
    original = activation._atomic
    fail_at = activation.home / ".config/ghostty/machine"
    # Force a changed template while retaining unchanged owned on-disk content.
    operations = activation.generated(Path(activation.read_manifest()["font_dir"]))
    operations[1].content += b"# changed template\n"

    def fail(path, *args):
        if path == fail_at:
            raise OSError("second generated write")
        return original(path, *args)

    monkeypatch.setattr(activation, "_atomic", fail)
    manifest = activation.read_manifest()
    with pytest.raises(OSError, match="second"):
        activation._apply_operations(operations, manifest)
    assert activation.read_manifest()["owned"] == previous


def declare_companion(frame, *, font="one", companion_name="minimal"):
    profile = Path(frame.current)
    manifest_path = profile / "share/frame-cli/assets.json"
    manifest = json.loads(manifest_path.read_text())
    companion = frame.home / "sources" / companion_name
    write(companion / "share/fonts/truetype/Companion.ttf", "companion-font")
    reference = f"font-companions/{font}-0-{companion_name}-out"
    asset = profile / "share/frame-cli/assets" / reference
    asset.parent.mkdir(parents=True, exist_ok=True)
    asset.symlink_to(companion)
    record = next(record for record in manifest["fonts"] if record["reference"] == "fonts/" + font)
    record["companions"] = [{"reference": reference, "path": str(companion)}]
    manifest_path.write_text(json.dumps(manifest))
    return companion, manifest_path


def test_font_declared_external_companion_export(setup):
    frame, activation = setup
    companion, _ = declare_companion(frame)
    source = frame.home / "sources/font-one/share/fonts/truetype/family/alias.ttf"
    source.unlink()
    target = companion / "share/fonts/truetype/Companion.ttf"
    source.symlink_to(os.path.relpath(target, source.parent))
    generation = activation.export(frame.current)
    exported = (
        activation.assets / "generations" / generation / "fonts/one/truetype/family/alias.ttf"
    )
    assert exported.read_bytes() == b"companion-font"
    assert not exported.is_symlink()


def test_font_unlisted_external_companion_rejected(setup):
    frame, activation = setup
    companion, manifest_path = declare_companion(frame)
    manifest = json.loads(manifest_path.read_text())
    del manifest["fonts"][0]["companions"]
    manifest_path.write_text(json.dumps(manifest))
    source = frame.home / "sources/font-one/share/fonts/truetype/family/alias.ttf"
    source.unlink()
    source.symlink_to(companion / "share/fonts/truetype/Companion.ttf")
    with pytest.raises(ActivationError, match="escapes declared output"):
        activation.export(frame.current)


def test_font_companion_reference_path_mismatch_rejected(setup):
    frame, activation = setup
    _, manifest_path = declare_companion(frame)
    manifest = json.loads(manifest_path.read_text())
    manifest["fonts"][0]["companions"][0]["path"] = str(frame.home / "sources/font-one")
    manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(ActivationError, match="companion reference does not match"):
        activation.export(frame.current)


def test_font_companions_do_not_authorize_other_selected_fonts(setup):
    frame, activation = setup
    companion, manifest_path = declare_companion(frame)
    manifest = json.loads(manifest_path.read_text())
    second = frame.home / "sources/font-two"
    write(second / "share/fonts/Regular.ttf", "second font")
    (second / "share/fonts/External.ttf").symlink_to(
        companion / "share/fonts/truetype/Companion.ttf"
    )
    (Path(frame.current) / "share/frame-cli/assets/fonts/two").symlink_to(second)
    manifest["fonts"].append({"reference": "fonts/two", "path": str(second)})
    manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(ActivationError, match="escapes declared output"):
        activation.export(frame.current)


@pytest.fixture
def checkout_home(setup):
    frame, activation = setup
    checkout = frame.home / "checkout"
    write(
        checkout / "frame/sync.json",
        json.dumps(
            {
                "schema_version": 1,
                "layers": ["common-dev-desktop"],
                "exclusions": [
                    ".config/ghostty/machine",
                    ".config/alacritty/machine.toml",
                    ".config/fontconfig/conf.d/99-frame-cli.conf",
                ],
            }
        ),
    )
    dotfiles = checkout / "common-dev-desktop/dotfiles"
    write(dotfiles / ".config/ghostty/config", "config-file = ?machine\n")
    write(dotfiles / ".config/alacritty/alacritty.toml", "[font]\n")
    write(dotfiles / ".config/fontconfig/conf.d/shared.conf", "<fontconfig/>\n")
    frame.repo = checkout
    return frame, activation, checkout, dotfiles


@pytest.mark.parametrize(
    "relative",
    [
        ".config/ghostty/machine",
        ".config/alacritty/machine.toml",
        ".config/fontconfig/conf.d/99-frame-cli.conf",
    ],
)
@pytest.mark.parametrize("target_kind", ["checkout", "unrelated"])
@pytest.mark.parametrize("exists", [False, True])
def test_activation_symlinked_parent_preserves_home_and_checkout(
    checkout_home, relative, target_kind, exists
):
    from home_sync import plan_home_sync

    frame, activation, checkout, dotfiles = checkout_home
    destination = frame.home / relative
    target = (
        dotfiles / Path(relative).parent
        if target_kind == "checkout"
        else frame.home / "unrelated" / Path(relative).parent
    )
    target.mkdir(parents=True, exist_ok=True)
    if exists:
        write(target / destination.name, b"user bytes\xff\n", 0o640)
    destination.parent.parent.mkdir(parents=True, exist_ok=True)
    destination.parent.symlink_to(target, target_is_directory=True)
    home_before = snapshot(frame.home)
    target_before = snapshot(target)
    checkout_before = snapshot(checkout)
    selected = plan_home_sync(target="frame", home=frame.home, repo=checkout)
    assert selected.conflicts
    plan = activation.plan(sync_plan=selected)
    assert any(
        op.path == destination and "unsafe activation parent" in op.conflict
        for op in plan.conflicts
    )
    output = []
    assert handle_cli(frame, dry_run=True, output=output.append) == 0
    assert "unsafe activation parent" in output[0]
    assert snapshot(frame.home) == home_before
    assert handle_cli(frame, confirm=lambda _: True, output=output.append) == 1
    assert snapshot(target) == target_before
    assert snapshot(checkout) == checkout_before
    assert destination.parent.is_symlink()
    assert not (frame.home / ".bashrc").exists()
    assert not (frame.home / ".bash_profile").exists()


def test_owned_generated_parent_replacement_is_preserved_conflict(setup):
    frame, activation = setup
    apply(activation)
    destination = frame.home / ".config/ghostty/machine"
    original_parent = destination.parent
    parked = frame.home / "previous-ghostty"
    original_parent.rename(parked)
    target = frame.home / "unrelated-ghostty"
    write(target / "machine", "unrelated user bytes", 0o600)
    original_parent.symlink_to(target)
    before = snapshot(target)
    plan = activation.plan()
    assert any(op.path == destination and op.conflict for op in plan.conflicts)
    assert str(destination) in activation.status()["changed"]
    result = activation.apply(plan, confirmed=True)
    assert not result["complete"]
    assert snapshot(target) == before
    assert original_parent.is_symlink()


@pytest.mark.parametrize("nested", [False, True])
def test_symlinked_control_parent_rejected_without_writes(setup, nested):
    frame, activation = setup
    target = frame.home / "unrelated-control"
    target.mkdir()
    if nested:
        parent = frame.home / "redirected"
        parent.symlink_to(target)
        frame.state = parent / "state"
    else:
        frame.state.symlink_to(target)
    before = snapshot(frame.home)
    messages = []
    assert handle_cli(frame, dry_run=True, output=messages.append) == 1
    assert any("unsafe activation parent" in message for message in messages)
    assert snapshot(frame.home) == before
    assert list(target.iterdir()) == []


def test_atomic_no_follow_parent_swap_after_validation(setup, monkeypatch):
    frame, activation = setup
    parent = frame.home / ".config/ghostty"
    parent.mkdir(parents=True)
    destination = parent / "machine"
    target = frame.home / "unrelated-race-target"
    target.mkdir()
    parked = frame.home / "parked-parent"
    safe = activation._safe
    swapped = False

    def swap(path):
        nonlocal swapped
        result = safe(path)
        if path == destination and not swapped:
            swapped = True
            parent.rename(parked)
            parent.symlink_to(target)
        return result

    monkeypatch.setattr(activation, "_safe", swap)
    with pytest.raises((ActivationError, OSError)):
        activation._atomic(destination, b"must not reach target")
    assert list(target.iterdir()) == []
    assert list(parked.iterdir()) == []


def test_atomic_rechecks_parent_before_directory_relative_replace(setup, monkeypatch):
    frame, activation = setup
    parent = frame.home / ".config/ghostty"
    parent.mkdir(parents=True)
    destination = parent / "machine"
    target = frame.home / "unrelated-race-target"
    target.mkdir()
    parked = frame.home / "parked-parent"
    original = activation._parent_fd

    @contextmanager
    def swapped_fd(path, *, create=False):
        with original(path, create=create) as fd:
            parent.rename(parked)
            parent.symlink_to(target)
            yield fd

    monkeypatch.setattr(activation, "_parent_fd", swapped_fd)
    with pytest.raises(ActivationError, match="unsafe activation parent"):
        activation._atomic(destination, b"must not reach target")
    assert list(target.iterdir()) == []
    assert list(parked.iterdir()) == []


def test_generated_parent_changed_after_plan_is_skipped(setup):
    frame, activation = setup
    parent = frame.home / ".config/ghostty"
    parent.mkdir(parents=True)
    plan = activation.plan()
    target = frame.home / "late-redirect"
    target.mkdir()
    parent.rmdir()
    parent.symlink_to(target)
    result = activation.apply(plan, confirmed=True)
    assert not result["complete"]
    assert list(target.iterdir()) == []
    assert not (frame.home / ".bashrc").exists()
    assert not (frame.home / ".bash_profile").exists()


@pytest.mark.parametrize("kind", ["file", "link"])
def test_directory_fd_replace_never_follows_last_moment_parent_link(setup, monkeypatch, kind):
    frame, activation = setup
    parent = frame.home / ".config/ghostty"
    parent.mkdir(parents=True)
    destination = parent / "machine"
    target = frame.home / "last-moment-target"
    target.mkdir()
    parked = frame.home / "parked-parent"
    replace = os.replace

    def redirect(source, final, *, src_dir_fd=None, dst_dir_fd=None):
        assert src_dir_fd is not None and src_dir_fd == dst_dir_fd
        parent.rename(parked)
        parent.symlink_to(target)
        return replace(source, final, src_dir_fd=src_dir_fd, dst_dir_fd=dst_dir_fd)

    monkeypatch.setattr(os, "replace", redirect)
    if kind == "file":
        activation._atomic(destination, b"directory handle bytes")
        assert (parked / "machine").read_bytes() == b"directory handle bytes"
    else:
        activation._symlink(destination, "managed target")
        assert os.readlink(parked / "machine") == "managed target"
    assert list(target.iterdir()) == []


@pytest.mark.parametrize("through_unlisted", [False, True])
def test_font_companion_cycle_or_unlisted_intermediate_rejected(setup, through_unlisted):
    frame, activation = setup
    companion, _ = declare_companion(frame)
    source = frame.home / "sources/font-one/share/fonts/truetype/family/alias.ttf"
    source.unlink()
    target = companion / "share/fonts/truetype/Companion.ttf"
    if through_unlisted:
        intermediary = frame.home / "sources/unlisted/link.ttf"
        intermediary.parent.mkdir()
        intermediary.symlink_to(target)
        source.symlink_to(intermediary)
        message = "escapes declared output"
    else:
        source.symlink_to(target)
        target.unlink()
        target.symlink_to(source)
        message = "symlink cycle"
    with pytest.raises(ActivationError, match=message):
        activation.export(frame.current)
