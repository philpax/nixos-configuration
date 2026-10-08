"""Local safety/contract tests; no SSH connection or device mutation."""

import io
import json
import os
import shutil
import subprocess
import tarfile

import pytest

from tests.frame_device_scenarios import (
    SOURCE_ALLOWLIST,
    STEEL_SUBMODULES,
    TRIAL_ROOT,
    Command,
    DeviceRunner,
    ScenarioError,
    TrialPaths,
    build_scenario_commands,
    checked_steel_files,
    source_files,
    source_path_allowed,
    stage_source_archive,
)
from tests.ssh_transport import (
    HOST,
    SyntheticTransport,
    find_sftp_server,
    parse_transport_args,
    ssh_file_transfer_startup_scenario,
)


def test_frame_staging_excludes_credentials(tmp_path):
    repo = tmp_path / "source"
    repo.mkdir()
    fixtures = {
        "frame/cli.py": "print('source')\n",
        "frame/state/auth.json": "synthetic-private-state",
        "frame/__pycache__/cli.pyc": "synthetic-cache",
        "frame/.env": "synthetic-token",
        "frame/private.key": "synthetic-key",
        "frame/credentials.json": "synthetic-credential",
        "common-all/dotfiles/.ssh/id_rsa": "synthetic-ssh-secret",
        "common-all/dotfiles/.config/fish/config.fish": "set -gx TEST_SOURCE 1\n",
        "common-all/dotfiles/.config/fish/token.json": "synthetic-token",
        "common-all/dotfiles/.config/polytoken/config.yaml": "synthetic-config-source",
        "common-all/dotfiles/.config/polytoken/auth.json": "synthetic-auth",
        "common-dev/dotfiles/.agents/skills/example/SKILL.md": "source-only-skill",
        "common-dev-desktop/dotfiles/.config/niri/config.kdl": "passive-config-source",
        "common-dev/dotfiles/.local/state/makima/auth/account": "synthetic-auth",
        "common-dev-desktop/dotfiles/.config/wayland-autostart.sh": "not-allowlisted",
    }
    for relative, data in fixtures.items():
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)
    archive = tmp_path / "source.tar.gz"
    manifest = stage_source_archive(repo, archive, include_steel=False)
    expected = [
        "common-all/dotfiles/.config/fish/config.fish",
        "common-all/dotfiles/.config/polytoken/config.yaml",
        "common-dev/dotfiles/.agents/skills/example/SKILL.md",
        "common-dev-desktop/dotfiles/.config/niri/config.kdl",
        "frame/cli.py",
    ]
    assert [item["path"] for item in manifest] == expected
    with tarfile.open(archive) as source:
        assert source.getnames() == expected
        assert all(member.isfile() for member in source.getmembers())
        assert all(
            not any(
                secret in source.extractfile(member).read()
                for secret in (
                    b"synthetic-auth",
                    b"synthetic-token",
                    b"synthetic-key",
                    b"synthetic-private",
                )
            )
            for member in source.getmembers()
        )
    with pytest.raises(FileExistsError):
        stage_source_archive(repo, archive, include_steel=False)


@pytest.mark.parametrize(
    "relative",
    [
        "/frame/cli.py",
        "frame/../frame/cli.py",
        "frame/auth/private",
        "frame/.cache/item",
        "frame/token.json",
        "frame/.git/config",
        "frame/.env",
        "frame/id.key",
        "common-all/dotfiles/.ssh/id_rsa",
        "steel-cogs/forest/.git/config",
        "common-dev/dotfiles/.config/makima/auth.json",
    ],
)
def test_source_path_rejects_private_or_unapproved_paths(relative):
    assert not source_path_allowed(relative)


def test_source_allowlist_does_not_copy_whole_dotfiles_or_checkout():
    assert "common-all/dotfiles" not in SOURCE_ALLOWLIST
    assert "." not in SOURCE_ALLOWLIST
    assert source_path_allowed("common-all/dotfiles/.config/helix/init.scm")
    assert source_path_allowed("steel-cogs/forest/forest.scm")


def test_frame_staging_rejects_symlink_sources(tmp_path):
    (tmp_path / "frame").mkdir()
    external = tmp_path / "outside"
    external.write_text("do-not-copy")
    (tmp_path / "frame/cli.py").symlink_to(external)
    with pytest.raises(ScenarioError, match="regular source"):
        source_files(tmp_path, include_steel=False)


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        env={**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull},
    )


def test_steel_staging_requires_checked_clean_recorded_submodules(tmp_path):
    git(tmp_path, "init", "-q")
    for relative in STEEL_SUBMODULES:
        module = tmp_path / relative
        module.mkdir(parents=True)
        git(module, "init", "-q")
        (module / "plugin.scm").write_text("(define test-source 1)\n")
        git(module, "add", "plugin.scm")
        git(
            module,
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "fixture",
        )
        oid = git(module, "rev-parse", "HEAD").stdout.decode().strip()
        git(tmp_path, "update-index", "--add", "--cacheinfo", f"160000,{oid},{relative}")
    assert len(checked_steel_files(tmp_path)) == 3
    archive = tmp_path / "steel.tar.gz"
    manifest = stage_source_archive(tmp_path, archive)
    assert {item["path"] for item in manifest} == {
        relative + "/plugin.scm" for relative in STEEL_SUBMODULES
    }
    (tmp_path / STEEL_SUBMODULES[0] / "untracked-secret").write_text("synthetic")
    with pytest.raises(ScenarioError, match="dirty"):
        checked_steel_files(tmp_path)


@pytest.mark.parametrize(
    "trial,name",
    [
        ("/home/steamos", "test"),
        (str(TRIAL_ROOT) + "/child", "test"),
        (str(TRIAL_ROOT), "../home"),
        (str(TRIAL_ROOT), "/absolute"),
        (str(TRIAL_ROOT), ""),
        (str(TRIAL_ROOT), "space name"),
    ],
)
def test_device_runner_requires_explicit_trial_and_safe_name(trial, name):
    with pytest.raises(ScenarioError):
        TrialPaths.create(trial, name)


def test_device_runner_plan_is_confined_read_only_and_has_no_assistant_execution(tmp_path):
    paths = TrialPaths.create(TRIAL_ROOT, "contract")
    runner = DeviceRunner(paths)
    build_scenario_commands(runner)
    assert str(paths.home).startswith(str(TRIAL_ROOT) + "/scenario-contract/")
    assert paths.state.is_relative_to(paths.home)
    assert paths.checkout.is_relative_to(paths.root)
    assert "SSH_AUTH_SOCK" not in runner.env
    assert "NIX_CONFIG" not in runner.env
    forbidden = ("polytoken", "makima", "claude", "sudo", "ssh ", "nix-collect-garbage")
    commands = runner.exact_commands()
    assert commands
    assert all(not any(word in command.lower() for word in forbidden) for command in commands)
    assert all(
        command.argv[1] == str(paths.checkout / "frame/cli.py") for command in runner.commands
    )
    assert any("pkg-config --cflags --libs openssl" in command for command in commands)
    assert any("direnv export fish" in command for command in commands)
    assert any("rollback" in command for command in commands)
    assert any("hx " in command and "forest-test.rs" in command for command in commands)
    helix = [command.argv for command in runner.commands if "exec hx $argv" in command.argv]
    assert len(helix) == 2
    assert all(
        argv[argv.index("exec hx $argv") - 3 : argv.index("exec hx $argv")] == ("fish", "-l", "-c")
        for argv in helix
    )
    assert not paths.root.exists()
    assert not list(tmp_path.iterdir())


def synthetic_paths(tmp_path):
    root = tmp_path / "scenario-test"
    home = root / "home"
    checkout = root / "checkout"
    work = root / "work"
    for path in (home, checkout, work):
        path.mkdir(parents=True, exist_ok=True)
    return TrialPaths(tmp_path, root, home, home / ".local/share/frame-cli", checkout, work)


def test_archive_unpack_rejects_links_and_traversal_before_writing(tmp_path):
    paths = synthetic_paths(tmp_path)
    archive = tmp_path / "unsafe.tar"
    with tarfile.open(archive, "w") as output:
        safe = tarfile.TarInfo("frame/cli.py")
        safe.size = 4
        output.addfile(safe, io.BytesIO(b"safe"))
        bad = tarfile.TarInfo("frame/../../outside")
        bad.size = 6
        output.addfile(bad, io.BytesIO(b"unsafe"))
    with pytest.raises(ScenarioError, match="Unapproved"):
        paths.unpack(archive)
    assert not list(paths.checkout.iterdir())


def test_device_runner_real_stdin_output_exit_status_and_timeout(tmp_path):
    import sys

    paths = synthetic_paths(tmp_path)
    runner = DeviceRunner(paths, execute=True)
    payload = b"literal ; $HOME\x00\xff\n"
    command = Command(
        (
            sys.executable,
            "-c",
            "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read()); sys.exit(17)",
        ),
        input=payload,
    )
    result = runner.run(command, expected=17)
    assert result.stdout == payload
    assert result.returncode == 17
    assert str(paths.home) == runner.env["HOME"]
    with pytest.raises(ScenarioError, match="timed out"):
        runner.run(Command((sys.executable, "-c", "import time; time.sleep(10)"), timeout=1))


def test_device_runner_real_pty_has_controlling_terminal_and_accepts_stdin(tmp_path):
    import sys

    runner = DeviceRunner(synthetic_paths(tmp_path), execute=True)
    command = Command(
        (
            sys.executable,
            "-c",
            "import os,sys; "
            "assert os.isatty(0); assert os.tcgetpgrp(0) == os.getpgrp(); "
            "assert sys.stdin.readline() == 'synthetic input\\n'; print('PTY-STDIN-OK')",
        ),
        input=b"synthetic input\n",
    )
    assert b"PTY-STDIN-OK" in runner.pty(command, [])


def test_agent_scenario_plan_uses_only_temporary_keys_and_stops_owned_agent():
    from tests.frame_device_scenarios import frame_ssh_agent_scenario

    runner = DeviceRunner(TrialPaths.create(TRIAL_ROOT, "agent"))
    frame_ssh_agent_scenario(runner)
    commands = runner.exact_commands()
    assert commands[-1].endswith("agent stop")
    assert any("ssh-keygen -Y sign" in command for command in commands)
    assert any("check-novalidate" in command for command in commands)
    assert all(".ssh/" not in command for command in commands)
    assert not runner.paths.root.exists()
    assert len(str(runner.paths.state / "agent/run/agent.sock").encode()) <= 107


def test_scenario_controls_reject_parent_symlink_escape(tmp_path):
    paths = synthetic_paths(tmp_path)
    (paths.work / "escape").symlink_to(tmp_path, target_is_directory=True)
    runner = DeviceRunner(paths, execute=True)
    with pytest.raises(ScenarioError, match="symlink"):
        runner.fixture("escape/secret", "synthetic")
    assert not (tmp_path / "secret").exists()


@pytest.fixture
def real_transport_tools():
    if not all(shutil.which(tool) for tool in ("bash", "scp", "sftp")):
        pytest.skip("actual bash/scp/sftp tools unavailable")
    try:
        return find_sftp_server()
    except FileNotFoundError as error:
        pytest.skip(str(error))


def test_ssh_file_transfer_startup_scenario(tmp_path, real_transport_tools):
    assert ssh_file_transfer_startup_scenario(tmp_path / "clean") == {
        "command": "passed",
        "scp_legacy": "passed",
        "sftp": "passed",
    }


def test_noisy_startup_fixture_fails_exact_command_assertion(tmp_path, real_transport_tools):
    with pytest.raises(AssertionError, match="contaminated"):
        ssh_file_transfer_startup_scenario(tmp_path / "noisy", noisy=True)


@pytest.mark.parametrize("method", ["scp_roundtrip", "sftp_roundtrip"])
def test_noisy_startup_fixture_breaks_real_protocol(tmp_path, real_transport_tools, method):
    transport = SyntheticTransport(tmp_path / method, noisy=True)
    with pytest.raises(AssertionError):
        getattr(transport, method)(b"synthetic-data\x00\xff\n")


def test_transport_rejects_external_host_and_arbitrary_commands(tmp_path):
    config = {"root": str(tmp_path), "scp": "/actual/scp", "sftp_server": "/actual/sftp-server"}
    for args in (
        ["external.example", "scp -t /tmp/file"],
        [HOST, "sh -c rm -rf /"],
        [HOST, "scp -t /etc/file"],
        ["-o", "ProxyCommand=ssh external.example", HOST, "scp -t /tmp/file"],
        ["-s", HOST, "arbitrary-subsystem"],
    ):
        with pytest.raises(ValueError):
            parse_transport_args(args, config)
    assert parse_transport_args(["-x", "-o", "BatchMode=yes", "-s", HOST, "sftp"], config) == [
        "/actual/sftp-server",
        "-d",
        str(tmp_path),
    ]


def test_generated_hook_is_quiet_for_real_transfer_startup(tmp_path, real_transport_tools):
    from pathlib import Path

    template = Path("frame/templates/auto-enter.bash").read_text()
    marker = tmp_path / "wrapper-was-invoked"
    wrapper = tmp_path / "synthetic-wrapper"
    wrapper.write_text("#!/bin/sh\nprintf invoked > " + str(marker) + "\nexit 1\n")
    wrapper.chmod(0o700)
    hook = template.replace("@WRAPPER_PATH@", str(wrapper)).replace("$wrapper", str(wrapper))
    rc = ("source " + str(tmp_path / "hook.bash") + "\n").encode()
    (tmp_path / "hook.bash").write_text(hook)
    ssh_file_transfer_startup_scenario(tmp_path / "generated-hook", rc=rc)
    assert not marker.exists(), "noninteractive shell invoked the Frame wrapper"


def test_synthetic_transport_forwards_binary_stdin_and_exit_status(tmp_path, real_transport_tools):
    transport = SyntheticTransport(tmp_path / "command")
    payload = b"\x00\xff\n" + bytes(range(256)) * 10
    result = transport.command(payload)
    assert result.returncode == 23
    assert result.stdout == payload
    assert result.stderr == b"command-stderr\n"
    assert b"source" in (transport.home / "startup.bash").read_bytes()
    assert json.loads(transport.config.read_text())["home"] == str(transport.home)
