"""Isolated tests for the host Frame deployment interface."""

import hashlib
import json
import os
import subprocess
import tarfile
from pathlib import Path
from types import SimpleNamespace

import pytest

from frame import cli, core
from frame.core import NIX_CONFIG, Frame
from frame.paths import FrameError, Paths

PIN = {"rev": "1" * 40, "sha256": "sha256-" + "A" * 43 + "="}
STORE_ONE = "/nix/store/" + "a" * 32 + "-environment-one"
STORE_TWO = "/nix/store/" + "b" * 32 + "-environment-two"
KEY = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
CERT_ARCHIVE_PATH = (
    "nix-2.28.5-aarch64-linux/store/"
    "ilzq4acy4cpa9gx63sf35wxrz30ry7kj-nss-cacert-3.113.1/"
    "etc/ssl/certs/ca-bundle.crt"
)
CERT_BYTES = b"-----BEGIN CERTIFICATE-----\nverified archive bytes\n-----END CERTIFICATE-----\n"
CONFIG = {
    "build-users-group": {"value": ""},
    "sandbox": {"value": True},
    "require-sigs": {"value": True},
    "substituters": {"value": ["https://cache.nixos.org"]},
    "trusted-public-keys": {"value": [KEY]},
    "experimental-features": {"value": ["flakes", "nix-command"]},
}


class Runner:
    def __init__(self):
        self.calls = []
        self.build = STORE_TWO
        self.fail_build = False
        self.nested = False
        self.namespace = True
        self.command_status = 0
        self.config = CONFIG
        self.store_info = {"trusted": 1, "url": "local", "version": "2.28.5"}
        self.store_dir = "/nix/store"
        self.frame = None

    def __call__(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        output, error, code = "", "", 0
        if core.IDENTITY_SCRIPT in argv:
            in_helper = argv[0] == str(self.frame.paths.helper)
            code = 0 if (self.namespace if in_helper else self.nested) else 1
        elif "nix-build" in argv:
            output = self.build + "\n"
            if self.fail_build:
                code, error = 1, "synthetic bad override"
        elif "nix-env" in argv:
            profile = self.frame.profile
            if "--set" in argv:
                generations = [
                    int(item.name.split("-")[1])
                    for item in profile.parent.iterdir()
                    if core.GENERATION.fullmatch(item.name)
                ]
                number = max(generations, default=0) + 1
                generation = profile.parent / f"profile-{number}-link"
                generation.symlink_to(argv[-1])
            else:
                number = int(argv[-1])
            profile.unlink(missing_ok=True)
            profile.symlink_to(f"profile-{number}-link")
        elif "config" in argv and "show" in argv:
            output = json.dumps(self.config)
        elif "store" in argv and "info" in argv:
            output = json.dumps(self.store_info)
        elif "builtins.storeDir" in argv:
            output = self.store_dir
        elif "--version" in argv:
            output = "nix (Nix) 2.28.5\n"
        elif kwargs.get("capture_output") is False:
            code = self.command_status
        return subprocess.CompletedProcess(argv, code, output, error)


@pytest.fixture
def installed(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    repo = tmp_path / "repo"
    (repo / "frame").mkdir(parents=True)
    (repo / "frame/nixpkgs.json").write_text(json.dumps(PIN))
    (repo / "frame/cli.py").write_text("# stable checkout\n")
    runner = Runner()
    frame = Frame(home, runner=runner, repo=repo, environ={"HOME": str(home), "PATH": "/usr/bin"})
    runner.frame = frame
    frame.paths.mkdir(frame.paths.helper.parent)
    frame.paths.helper.write_bytes(b"verified synthetic helper")
    frame.paths.helper.chmod(0o700)
    monkeypatch.setattr(
        core, "HELPER_SHA256", hashlib.sha256(frame.paths.helper.read_bytes()).hexdigest()
    )
    frame.paths.mkdir(frame.paths.tmp)
    for number, logical in enumerate((STORE_ONE, STORE_TWO), start=1):
        physical = frame.paths.store / "store" / Path(logical).name
        (physical / "share/frame-cli").mkdir(parents=True)
        (physical / "share/frame-cli/build-info.json").write_text(
            json.dumps({"generation": number})
        )
        (frame.state / f"profile-{number}-link").symlink_to(logical)
    frame.profile.symlink_to("profile-1-link")
    frame.paths.mkdir(frame.paths.bootstrap_home)
    bootstrap_profile = frame.paths.bootstrap_home / ".local/state/nix/profiles/profile"
    frame.paths.mkdir(bootstrap_profile.parent)
    frame.paths.bootstrap_home.joinpath(".nix-profile").symlink_to(bootstrap_profile)
    bootstrap_profile.symlink_to("profile-1-link")
    bootstrap_profile.with_name("profile-1-link").symlink_to(STORE_ONE)
    for relative in ("etc/profile.d/nix.sh",):
        dependency = frame.physical_target(STORE_ONE) / relative
        dependency.parent.mkdir(parents=True, exist_ok=True)
        dependency.write_text("# verified dependency\n")
    frame.paths.atomic_bytes(frame.certificate_path, CERT_BYTES)
    frame.paths.write_json(
        frame.paths.metadata,
        {
            "schema": 1,
            "home": str(home),
            "state": str(frame.state),
            "uid": os.getuid(),
            "helper_version": core.HELPER_VERSION,
            "nix_version": core.NIX_VERSION,
            "helper_sha256": core.HELPER_SHA256,
            "installer_sha256": core.NIX_SHA256,
            "certificate": {
                "path": str(frame.certificate_path),
                "sha256": hashlib.sha256(CERT_BYTES).hexdigest(),
                "archive_path": CERT_ARCHIVE_PATH,
            },
        },
    )
    return frame, runner


def test_bootstrap_rejects_state_symlink_escape(tmp_path):
    home, outside = tmp_path / "home", tmp_path / "outside"
    home.mkdir()
    outside.mkdir()
    (home / "escape").symlink_to(outside)
    with pytest.raises(FrameError, match="symlink"):
        Paths(home, home / "escape/state")
    with pytest.raises(FrameError, match="beneath"):
        Paths(home, outside)


def test_profile_symlink_chain_validation(installed):
    frame, _ = installed
    assert frame.validate_profile() == STORE_ONE
    frame.profile.unlink()
    frame.profile.symlink_to("../foreign")
    with pytest.raises(FrameError, match="generation"):
        frame.validate_profile()
    frame.profile.unlink()
    frame.profile.symlink_to("profile-1-link")
    generation = frame.state / "profile-1-link"
    generation.unlink()
    generation.symlink_to("/nix/store/" + "c" * 32 + "-foreign")
    with pytest.raises(FrameError, match="absent"):
        frame.validate_profile()


def test_profile_mutation_lock(installed):
    frame, _ = installed
    with frame.lock(), pytest.raises(FrameError, match="lock"):
        with frame.lock():
            pytest.fail("second lock must not enter")


def test_source_override_precedence(installed):
    frame, _ = installed
    local = frame.home / ".config/frame-cli"
    local.mkdir(parents=True)
    local_pin = dict(PIN, rev="2" * 40)
    (local / "nixpkgs.json").write_text(json.dumps(local_pin))
    (local / "overrides.nix").write_text("args: args")
    explicit = frame.home / "explicit.json"
    explicit.write_text(json.dumps(dict(PIN, rev="3" * 40)))
    assert frame.select_sources()[0] == local_pin
    assert frame.select_sources(explicit)[0]["rev"] == "3" * 40
    assert frame.select_sources()[2] == local / "overrides.nix"
    (local / "nixpkgs.json").write_text("{}")
    with pytest.raises(FrameError, match="complete"):
        frame.select_sources()


@pytest.mark.parametrize("name", ["nixpkgs.json", "overrides.nix"])
def test_dangling_user_sources_rejected(installed, name):
    frame, _ = installed
    local = frame.home / ".config/frame-cli"
    local.mkdir(parents=True)
    (local / name).symlink_to("missing")
    with pytest.raises(FrameError):
        frame.select_sources()


def test_enter_argv_and_exit_status(installed):
    frame, runner = installed
    runner.command_status = 17
    args = ["printf", "%s", "space argument", "$(touch never)", "single'quote"]
    assert frame.enter(args) == 17
    assert runner.calls[-1][0][-len(args) :] == args
    assert runner.calls[-1][1]["capture_output"] is False


def test_enter_preserves_user_environment(installed):
    frame, runner = installed
    frame.environ.update(
        XDG_CONFIG_HOME=str(frame.home / "custom"),
        SSH_AUTH_SOCK="/tmp/socket",
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/bus",
        TERM="xterm-256color",
        NIX_CONFIG="sandbox = false",
        NIX_REMOTE="daemon",
        NIX_STORE="foreign",
        BASH_ENV="/tmp/hostile",
        SSL_CERT_FILE="/tmp/hostile.crt",
    )
    frame.enter(["true"])
    argv, options = runner.calls[-1]
    env = options["env"]
    assert env["HOME"] == str(frame.home)
    assert env["XDG_CONFIG_HOME"] == str(frame.home / "custom")
    assert env["SSH_AUTH_SOCK"] == "/tmp/socket"
    assert env["TERM"] == "xterm-256color"
    assert env["NIX_REMOTE"] == "local"
    assert env["NIX_USER_CONF_FILES"] == ""
    assert not {"NIX_CONFIG", "NIX_STORE", "BASH_ENV", "SSL_CERT_FILE"}.intersection(env)
    script = argv[argv.index("-c") + 1]
    assert script.index(". ") < script.index("unset NIX_CONFIG")
    assert "NIX_CONF_DIR=/nix/etc/nix" in script
    assert 'exec "$@"' in script
    assert options["cwd"] is None


@pytest.mark.parametrize("valid", [False, True])
def test_nested_entry_validates_namespace(installed, valid):
    frame, runner = installed
    frame.environ["FRAME_CLI_ACTIVE"] = "1"
    runner.nested = valid
    frame.enter(["true"])
    final = runner.calls[-1][0]
    assert (final[0] == str(frame.paths.helper)) is (not valid)


def test_readiness_actual_namespace_no_writes(installed):
    frame, runner = installed
    before = sorted(str(item) for item in frame.home.rglob("*"))
    assert frame.readiness()
    assert sorted(str(item) for item in frame.home.rglob("*")) == before
    assert any(core.IDENTITY_SCRIPT in argv for argv, _ in runner.calls)
    assert any('"$1/bin/fish" --version' in item for argv, _ in runner.calls for item in argv)
    assert not any("nix-build" in argv for argv, _ in runner.calls)
    runner.namespace = False
    with pytest.raises(FrameError, match="namespace"):
        frame.readiness()


def test_nix_effective_configuration(installed):
    frame, runner = installed
    frame.effective_configuration()
    runner.config = {**CONFIG, "sandbox": {"value": False}}
    with pytest.raises(FrameError, match="sandbox"):
        frame.effective_configuration()


@pytest.mark.parametrize("info", [{}, None, [], {"url": "daemon"}, {"storeDir": "/nix/store"}])
def test_nix_store_info_must_confirm_local_url(installed, info):
    frame, runner = installed
    runner.store_info = info
    with pytest.raises(FrameError, match="Nix store|local store"):
        frame.effective_configuration()


def test_nix_logical_store_directory_is_checked_separately(installed):
    frame, runner = installed
    frame.effective_configuration()
    assert "storeDir" not in runner.store_info
    assert any("builtins.storeDir" in argv for argv, _ in runner.calls)
    runner.store_dir = "/foreign/store"
    with pytest.raises(FrameError, match="logical /nix/store"):
        frame.effective_configuration()


@pytest.mark.parametrize("missing", ["fish", "bash", "python3", "ssh-agent", "ssh-add"])
def test_missing_candidate_executable_blocks_publication(installed, missing):
    import shutil

    frame, runner = installed
    candidate = frame.physical_target(STORE_TWO)
    binaries = candidate / "bin"
    binaries.mkdir()
    for name in ("fish", "bash", "python3", "ssh-agent", "ssh-add"):
        path = binaries / name
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
    (binaries / missing).chmod(0o644)
    previous = os.readlink(frame.profile)
    bash = shutil.which("bash")
    assert bash, "The executable validation test requires host Bash"
    original = frame.runner

    def check_tools(argv, **kwargs):
        if "frame-entry-tools" in argv:
            marker = argv.index("frame-entry-tools")
            return subprocess.run(
                [bash, "-c", argv[marker - 1], "frame-entry-tools", str(candidate)], **kwargs
            )
        return original(argv, **kwargs)

    frame.runner = check_tools
    with pytest.raises(FrameError, match="Missing required Frame executable: " + missing):
        frame._publish(STORE_TWO)
    assert os.readlink(frame.profile) == previous
    assert not any("nix-env" in argv for argv, _ in runner.calls)


def test_activation_xdg_rule_does_not_affect_pure_enter(installed):
    frame, _ = installed
    frame.environ["XDG_CONFIG_HOME"] = str(frame.home / "custom")
    frame.enter(["true"])
    with pytest.raises(FrameError, match="XDG_CONFIG_HOME"):
        frame.readiness(activation=True)


def test_update_failure_keeps_profile(installed):
    frame, runner = installed
    runner.fail_build = True
    before = os.readlink(frame.profile)
    with pytest.raises(FrameError, match="bad override"):
        frame.update()
    assert os.readlink(frame.profile) == before


def test_invalid_override_keeps_profile(installed):
    frame, _ = installed
    before = os.readlink(frame.profile)
    with pytest.raises(FrameError, match="override"):
        frame.update(overrides=frame.home / "missing.nix")
    assert os.readlink(frame.profile) == before


def test_status_build_info_after_rollback(installed):
    frame, _ = installed
    frame.profile.unlink()
    frame.profile.symlink_to("profile-2-link")
    assert frame.status()["build_info"] == {"generation": 2}
    frame.rollback()
    assert frame.status()["build_info"] == {"generation": 1}


def test_install_idempotent(installed):
    frame, runner = installed
    frame.install()
    before = frame.paths.wrapper.read_bytes()
    frame.install()
    assert frame.paths.wrapper.read_bytes() == before
    assert not any("nix-build" in argv for argv, _ in runner.calls)


def test_wrapper_conflict_not_overwritten(installed):
    frame, _ = installed
    frame.paths.mkdir(frame.paths.wrapper.parent)
    frame.paths.wrapper.write_text("user wrapper")
    with pytest.raises(FrameError, match="conflict"):
        frame.install_wrapper()
    assert frame.paths.wrapper.read_text() == "user wrapper"


def test_bootstrap_hash_failure_stops_before_execution(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    calls = []
    frame = Frame(
        home,
        runner=lambda argv, **kwargs: calls.append(argv),
        downloader=lambda url, destination: destination.write_bytes(b"wrong bytes"),
    )
    monkeypatch.setattr(frame, "prerequisites", lambda: None)
    with frame.lock(), pytest.raises(FrameError, match="checksum"):
        frame._bootstrap()
    assert calls == []
    assert not frame.paths.helper.exists()


def test_tar_traversal_rejected(tmp_path):
    archive = tmp_path / "bad.tar.xz"
    with tarfile.open(archive, "w:xz") as bundle:
        info = tarfile.TarInfo("nix-2.28.5-aarch64-linux/../../escape")
        bundle.addfile(info)
    with pytest.raises(FrameError, match="Unsafe"):
        core.extract_installer(archive, tmp_path / "extract")
    assert not (tmp_path / "escape").exists()


def test_resolve_store_path_maps_namespace_links(installed):
    frame, _ = installed
    source = frame.physical_target(STORE_ONE)
    (source / "share/link").symlink_to(STORE_TWO + "/share/frame-cli")
    assert frame.resolve_store_path(STORE_ONE + "/share/link/build-info.json") == (
        frame.physical_target(STORE_TWO) / "share/frame-cli/build-info.json"
    )
    (source / "share/escape").symlink_to("/etc")
    with pytest.raises(FrameError, match="escapes"):
        frame.resolve_store_path(STORE_ONE + "/share/escape/passwd")


def test_cli_preserves_explicit_command_status(installed, monkeypatch):
    frame, runner = installed
    runner.command_status = 42
    monkeypatch.setattr(cli, "Frame", lambda *args, **kwargs: frame)
    assert cli.main(["enter", "--", "printf", "two words"]) == 42
    assert runner.calls[-1][0][-2:] == ["printf", "two words"]


def test_activation_prepared_before_profile_switch(installed, monkeypatch):
    frame, runner = installed
    events = []
    plugin = SimpleNamespace(
        reconcile=lambda f: events.append("reconcile"),
        prepare=lambda f, c: events.append("prepare") or c,
        publish=lambda f, p: events.append("publish"),
    )
    monkeypatch.setattr(frame, "_activation", lambda: plugin)
    original = runner.__call__

    def recording(argv, **kwargs):
        if "nix-env" in argv:
            events.append("profile")
        return original(argv, **kwargs)

    frame.runner = recording
    frame.update()
    assert events == ["reconcile", "reconcile", "prepare", "profile", "publish"]


def test_bootstrap_home_only_command_contract(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    archive = tmp_path / "release.tar.xz"
    root = tmp_path / "nix-2.28.5-aarch64-linux"
    root.mkdir()
    (root / "install").write_text("# synthetic installer\n")
    certificate = tmp_path / CERT_ARCHIVE_PATH
    certificate.parent.mkdir(parents=True)
    certificate.write_bytes(CERT_BYTES)
    with tarfile.open(archive, "w:xz") as bundle:
        bundle.add(root, arcname=root.name)
    helper_bytes = b"synthetic verified executable"
    monkeypatch.setattr(core, "HELPER_SHA256", hashlib.sha256(helper_bytes).hexdigest())
    monkeypatch.setattr(core, "NIX_SHA256", core.digest(archive))
    runner = Runner()

    def fetched(url, destination):
        destination.write_bytes(helper_bytes if url == core.HELPER_URL else archive.read_bytes())

    frame = Frame(
        home,
        runner=runner,
        downloader=fetched,
        environ={"HOME": str(home), "PATH": "/usr/bin", "NIX_CONFIG": "sandbox = false"},
    )
    runner.frame = frame
    monkeypatch.setattr(frame, "prerequisites", lambda: None)
    monkeypatch.setattr(frame, "bootstrap_profile", lambda: None)
    with frame.lock():
        frame._bootstrap()
    installer_calls = [(argv, options) for argv, options in runner.calls if "--no-daemon" in argv]
    assert len(installer_calls) == 1
    argv, options = installer_calls[0]
    assert argv[0:2] == [str(frame.paths.helper), str(frame.paths.store)]
    assert argv[-3:] == ["--no-daemon", "--no-channel-add", "--no-modify-profile"]
    assert options["env"]["HOME"] == str(frame.paths.bootstrap_home)
    assert options["env"]["NIX_BECOME"] == "/usr/bin/false"
    assert options["env"]["TMPDIR"] == str(frame.paths.tmp)
    assert (frame.paths.store / "etc/nix/nix.conf").read_text() == NIX_CONFIG
    script = argv[argv.index("-c") + 1]
    assert "SSL_CERT_FILE=" + str(frame.certificate_path) in script
    assert frame.certificate_path.read_bytes() == CERT_BYTES
    assert not frame.certificate_path.is_symlink()
    metadata = frame.paths.read_json(frame.paths.metadata)
    assert metadata["certificate"] == {
        "path": str(frame.certificate_path),
        "sha256": hashlib.sha256(CERT_BYTES).hexdigest(),
        "archive_path": CERT_ARCHIVE_PATH,
    }
    assert not any((home / name).exists() for name in (".profile", ".bash_profile", ".bashrc"))


def test_cli_activation_delegates_lazily(installed, monkeypatch):
    frame, _ = installed
    monkeypatch.setattr(frame, "activation_config_home", lambda: None)
    calls = []

    def handler(selected, *, dry_run, confirm):
        calls.append((selected, dry_run))
        if not dry_run:
            assert confirm("displayed combined plan") is True
        return 0

    monkeypatch.setattr(cli, "Frame", lambda *args, **kwargs: frame)
    monkeypatch.setattr(
        cli.importlib, "import_module", lambda name: SimpleNamespace(handle_cli=handler)
    )
    before = sorted(str(item) for item in frame.home.rglob("*"))
    assert cli.main(["activate", "--dry-run"]) == 0
    assert sorted(str(item) for item in frame.home.rglob("*")) == before
    confirmations = []
    assert cli.main(["activate"], confirm=lambda text: confirmations.append(text) or True) == 0
    assert confirmations == ["displayed combined plan"]
    assert calls == [(frame, True), (frame, False)]


def test_wrapper_binds_isolated_home_and_state(installed):
    frame, _ = installed
    frame.install_wrapper()
    content = frame.paths.wrapper.read_text()
    assert "--home " + str(frame.home) in content
    assert "--state-dir " + str(frame.state) in content
    assert "/usr/bin/python3" in content


def test_default_noninteractive_enter_does_not_start_agent(installed, monkeypatch):
    frame, runner = installed
    monkeypatch.setattr(os, "isatty", lambda fd: False)
    monkeypatch.setattr(
        core.importlib,
        "import_module",
        lambda name: pytest.fail("noninteractive entry must not import agent"),
    )
    assert frame.enter() == 0
    assert runner.calls[-1][0][-2:] == [str(frame.profile / "bin/fish"), "-l"]


def test_tar_rejects_forward_hardlink_and_symlink_parent(tmp_path):
    root = "nix-2.28.5-aarch64-linux"
    for name, linktype, target, child in (
        (root + "/link", tarfile.LNKTYPE, root + "/future", None),
        (root + "/link", tarfile.SYMTYPE, "directory", root + "/link/file"),
    ):
        archive = tmp_path / "bad.tar.xz"
        with tarfile.open(archive, "w:xz") as bundle:
            info = tarfile.TarInfo(name)
            info.type, info.linkname = linktype, target
            bundle.addfile(info)
            if child:
                bundle.addfile(tarfile.TarInfo(child))
        with pytest.raises(FrameError):
            core.extract_installer(archive, tmp_path / "extract")


def test_tar_removes_special_permissions(tmp_path):
    import io

    archive = tmp_path / "release.tar.xz"
    root = "nix-2.28.5-aarch64-linux"
    with tarfile.open(archive, "w:xz") as bundle:
        info = tarfile.TarInfo(root + "/install")
        info.mode, info.size = 0o6755, 4
        bundle.addfile(info, io.BytesIO(b"true"))
    installer = core.extract_installer(archive, tmp_path / "extract")
    assert installer.stat().st_mode & 0o6000 == 0


def test_cli_agent_status_serializes_manager_result(installed, monkeypatch, capsys):
    frame, _ = installed
    manager = SimpleNamespace(status=lambda env: SimpleNamespace(as_dict=lambda: {"kind": "none"}))
    monkeypatch.setattr(frame, "make_agent_manager", lambda: manager)
    monkeypatch.setattr(cli, "Frame", lambda *args, **kwargs: frame)
    assert cli.main(["agent", "status"]) == 0
    assert json.loads(capsys.readouterr().out) == {"kind": "none"}


def test_namespace_overlay_cannot_override_nix_policy(installed):
    frame, _ = installed
    argv = frame.namespace_argv(
        ["true"],
        env={
            **frame.environment(),
            "NIX_CONFIG": "unsafe",
            "NIX_REMOTE": "daemon",
            "FRAME_AGENT_LAUNCH_ID": "token",
        },
    )
    script = argv[argv.index("-c") + 1]
    assert "NIX_REMOTE=local" in script
    assert "NIX_CONFIG=unsafe" not in script
    assert "FRAME_AGENT_LAUNCH_ID" not in script


def test_home_symlink_loop_is_actionable(tmp_path):
    home = tmp_path / "loop"
    home.symlink_to(home)
    with pytest.raises(FrameError, match="resolve selected home"):
        Paths(home)


@pytest.mark.parametrize("launch", ["argv", "runner-overlay"])
def test_nix_policy_reapplied_after_sourcing_script(installed, launch):
    import shutil
    import sys

    frame, _ = installed
    startup = frame.physical_target(STORE_ONE) / "etc/profile.d/nix.sh"
    startup.write_text(
        "export HOME=/hostile XDG_CONFIG_HOME=/hostile NIX_CONFIG=unsafe\n"
        "export NIX_REMOTE=daemon NIX_USER_CONF_FILES=/hostile SSL_CERT_FILE=/hostile\n"
    )
    # A physical test link supplies the fixture script without mounting /nix.
    profile = frame.paths.bootstrap_home / ".nix-profile"
    profile.unlink()
    profile.symlink_to(frame.physical_target(STORE_ONE))
    frame.environ["XDG_CONFIG_HOME"] = str(frame.home / "custom")
    hostile_functions = {
        "BASH_FUNC_export%%": "() { return 0; }",
        "BASH_FUNC_unset%%": "() { return 0; }",
    }
    frame.environ.update(hostile_functions)
    frame.environ.update(NIX_REMOTE="daemon", NIX_CONFIG="unsafe")
    command = [sys.executable, "-c", "import os,json; print(json.dumps(dict(os.environ)))"]
    bash = shutil.which("bash")
    assert bash, "The environment execution test requires host Bash"
    if launch == "argv":
        argv = frame.namespace_argv(command, reuse=True)
        argv[0] = bash
        result = subprocess.run(
            argv, env=frame.environment(), capture_output=True, text=True, check=True
        )
    else:

        def real_runner(argv, **kwargs):
            argv[0] = bash
            return subprocess.run(argv, **kwargs)

        frame.runner = real_runner
        overlay = dict(frame.environment(), **hostile_functions)
        overlay.update(NIX_REMOTE="daemon", NIX_CONFIG="unsafe")
        result = frame.namespace_run(command, env=overlay, reuse=True)
    effective = json.loads(result.stdout)
    assert not any(key.startswith("BASH_FUNC_") for key in effective)
    assert effective["HOME"] == str(frame.home)
    assert effective["XDG_CONFIG_HOME"] == str(frame.home / "custom")
    assert effective["NIX_REMOTE"] == "local"
    assert effective["NIX_USER_CONF_FILES"] == ""
    assert "NIX_CONFIG" not in effective
    assert effective["SSL_CERT_FILE"] == str(frame.certificate_path)
    assert effective["NIX_SSL_CERT_FILE"] == str(frame.certificate_path)


def test_tar_accepts_only_existing_logical_store_references(tmp_path):
    import io

    root = "nix-2.28.5-aarch64-linux"
    output = "a" * 32 + "-library"
    logical = "/nix/store/" + output + "/lib/real.so"
    for existing in (True, False):
        archive = tmp_path / "release.tar.xz"
        with tarfile.open(archive, "w:xz") as bundle:
            installer = tarfile.TarInfo(root + "/install")
            installer.size = 4
            bundle.addfile(installer, io.BytesIO(b"true"))
            if existing:
                target = tarfile.TarInfo(root + "/store/" + output + "/lib/real.so")
                target.size = 4
                bundle.addfile(target, io.BytesIO(b"data"))
            link = tarfile.TarInfo(root + "/store/" + output + "/lib/link.so")
            link.type, link.linkname = tarfile.SYMTYPE, logical
            bundle.addfile(link)
        staging = tmp_path / str(existing)
        if existing:
            core.extract_installer(archive, staging)
            assert os.readlink(staging / root / "store" / output / "lib/link.so") == logical
        else:
            with pytest.raises(FrameError, match="absent"):
                core.extract_installer(archive, staging)


@pytest.mark.parametrize(
    "hop,target",
    [
        ("entry", "/tmp/foreign/profile"),
        ("entry", "foreign-profile"),
        ("entry", "/nix/var/nix/profiles/foreign/profile"),
        ("profile", "../profile-1-link"),
        ("profile", "profile-0-link"),
        ("profile", "/tmp/profile-1-link"),
        ("generation", "/tmp/foreign-environment"),
        ("generation", "/nix/store/" + "c" * 32 + "-missing"),
    ],
)
def test_bootstrap_xdg_chain_rejects_foreign_hops(installed, hop, target):
    frame, _ = installed
    profile = frame.paths.bootstrap_home / ".local/state/nix/profiles/profile"
    path = {
        "entry": frame.paths.bootstrap_home / ".nix-profile",
        "profile": profile,
        "generation": profile.with_name("profile-1-link"),
    }[hop]
    path.unlink()
    path.symlink_to(target)
    with pytest.raises(FrameError):
        frame.bootstrap_profile()


def test_bootstrap_xdg_chain_rejects_redirected_parent(installed):
    frame, _ = installed
    profiles = frame.paths.bootstrap_home / ".local/state/nix/profiles"
    moved = profiles.with_name("foreign-profiles")
    profiles.rename(moved)
    profiles.symlink_to(moved)
    with pytest.raises(FrameError, match="symlink"):
        frame.bootstrap_profile()


def test_enter_signal_status_is_conventional_128_plus_signal(installed, monkeypatch):
    import signal

    frame, runner = installed
    runner.command_status = -signal.SIGTERM
    monkeypatch.setattr(cli, "Frame", lambda *args, **kwargs: frame)
    assert cli.main(["enter", "--", "true"]) == 128 + signal.SIGTERM


@pytest.mark.parametrize("change", ["bytes", "symlink", "hardlink", "path", "hash", "archive"])
def test_bootstrap_certificate_tampering_rejected(installed, change):
    frame, _ = installed
    metadata = frame.paths.read_json(frame.paths.metadata)
    if change == "bytes":
        frame.certificate_path.write_bytes(b"unverified")
    elif change == "symlink":
        frame.certificate_path.unlink()
        frame.certificate_path.symlink_to(frame.home / "foreign")
    elif change == "hardlink":
        os.link(frame.certificate_path, frame.home / "unowned-second-reference")
    else:
        key = {"path": "path", "hash": "sha256", "archive": "archive_path"}[change]
        metadata["certificate"][key] = "/tmp/foreign" if change != "hash" else "0" * 64
        frame.paths.write_json(frame.paths.metadata, metadata)
    with pytest.raises(FrameError):
        frame._bootstrap_metadata()


@pytest.mark.parametrize("layout", ["missing", "duplicate", "wrong-output", "symlink"])
def test_installer_cacert_selection_rejects_unexpected_layout(tmp_path, layout):
    import io

    archive = tmp_path / "release.tar.xz"
    root = "nix-2.28.5-aarch64-linux"
    with tarfile.open(archive, "w:xz") as bundle:
        install = tarfile.TarInfo(root + "/install")
        install.size = 4
        bundle.addfile(install, io.BytesIO(b"true"))
        if layout != "missing":
            name = (
                CERT_ARCHIVE_PATH
                if layout != "wrong-output"
                else (root + "/store/" + "a" * 32 + "-not-cacert/etc/ssl/certs/ca-bundle.crt")
            )
            member = tarfile.TarInfo(name)
            if layout == "symlink":
                member.type, member.linkname = tarfile.SYMTYPE, "bundle.pem"
                bundle.addfile(member)
            else:
                member.size = len(CERT_BYTES)
                bundle.addfile(member, io.BytesIO(CERT_BYTES))
            if layout == "duplicate":
                other = tarfile.TarInfo(CERT_ARCHIVE_PATH.replace("ilzq4", "aaaaa"))
                other.size = len(CERT_BYTES)
                bundle.addfile(other, io.BytesIO(CERT_BYTES))
    installer = core.extract_installer(archive, tmp_path / "extract")
    with pytest.raises(FrameError, match="exactly one regular cacert"):
        core.installer_certificate(archive, installer)


def test_bash_exported_functions_are_not_inherited(installed):
    frame, runner = installed
    frame.environ["BASH_FUNC_export%%"] = "() { echo unsafe; }"
    assert "BASH_FUNC_export%%" not in frame.environment()
    frame.namespace_run(
        ["true"], env={**frame.environment(), "BASH_FUNC_unset%%": "() { echo unsafe; }"}
    )
    assert not any(key.startswith("BASH_FUNC_") for key in runner.calls[-1][1]["env"])


def test_nix_source_paths_evaluate_literal_strings(installed, monkeypatch):
    import shutil

    original, _ = installed
    nix = shutil.which("nix-instantiate")
    if not nix:
        pytest.skip("Nix is required for actual source argument evaluation")
    frame = Frame(
        original.home,
        original.home / "state with spaces and ${literal}",
        repo=original.repo,
        environ=original.environ,
    )
    overrides = frame.home / "override with ${literal}.nix"
    overrides.write_text('args: { marker = "literal override"; }')
    calls = []

    def record_build(argv):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, STORE_ONE + "\n", "")

    monkeypatch.setattr(frame, "namespace_run", record_build)
    monkeypatch.setattr(frame, "physical_target", lambda target: original.physical_target(target))
    assert frame._build(overrides=overrides) == STORE_ONE
    argv = calls[0]
    result = subprocess.run(
        [
            nix,
            "--eval",
            "--strict",
            "--json",
            "--expr",
            "{ system, nixpkgsPin, overrides }: {"
            " pinType = builtins.typeOf nixpkgsPin;"
            " pin = builtins.fromJSON (builtins.readFile nixpkgsPin);"
            " overrideType = builtins.typeOf overrides;"
            " override = import overrides {};"
            "}",
            *argv[argv.index("--no-out-link") + 1 :],
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    assert json.loads(result.stdout) == {
        "pinType": "string",
        "pin": PIN,
        "overrideType": "string",
        "override": {"marker": "literal override"},
    }


@pytest.mark.parametrize("change", ["missing", "changed", "symlink", "not-executable"])
def test_activation_readiness_rejects_wrapper_without_mutation(installed, monkeypatch, change):
    frame, _ = installed
    monkeypatch.setattr(frame, "activation_config_home", lambda: None)
    original = os.access
    monkeypatch.setattr(
        os,
        "access",
        lambda path, mode: True if str(path) == "/usr/bin/python3" else original(path, mode),
    )
    frame.install_wrapper()
    if change == "missing":
        frame.paths.wrapper.unlink()
    elif change == "changed":
        frame.paths.wrapper.write_text("user replacement")
    elif change == "symlink":
        frame.paths.wrapper.unlink()
        frame.paths.wrapper.symlink_to(frame.repo / "frame/cli.py")
    else:
        frame.paths.wrapper.chmod(0o600)
    before = sorted(str(path) for path in frame.home.rglob("*"))
    with pytest.raises((FrameError, OSError)):
        frame.readiness(activation=True)
    assert sorted(str(path) for path in frame.home.rglob("*")) == before
