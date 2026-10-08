"""Current-host checks use the host source and never activate their build."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

_spec = importlib.util.spec_from_file_location(
    "current_nixos", Path(__file__).resolve().parent / "check-current-nixos.py"
)
current_nixos = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(current_nixos)


@pytest.fixture
def host_fixture(tmp_path):
    checkout = tmp_path / "checkout with spaces"
    target = checkout / "mindgame/configuration.nix"
    target.parent.mkdir(parents=True)
    target.write_text('{ networking.hostName = "mindgame"; }')
    common = checkout / "common-all/configuration.nix"
    common.parent.mkdir()
    common.write_text("{ imports = [ /etc/nixos/hardware-configuration.nix ]; }")
    hardware = tmp_path / "hardware-configuration.nix"
    hardware.write_text('{ nixpkgs.hostPlatform = "x86_64-linux"; }')
    hostname = tmp_path / "hostname"
    hostname.write_text("mindgame\n")
    installed = tmp_path / "configuration.nix"
    installed.symlink_to(target)
    source = tmp_path / "host source"
    (source / "nixos").mkdir(parents=True)
    (source / "nixos/default.nix").write_text("{}")
    (source / ".git-revision").write_text("host-source-revision\n")
    (source / ".version").write_text("26.05\n")
    summary = {
        "hostname": "mindgame",
        "assertionsPassed": True,
        "drvPath": "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-mindgame.drv",
        "affectedPackages": {"system": [{"outputName": "out", "path": "/nix/store/package"}]},
        "settings": {"fish": True},
    }
    state = {
        "currentSystem": "/nix/store/running-system",
        "systemProfileGeneration": "system-262-link",
        "systemProfileTarget": "/nix/store/running-system",
    }
    calls = []

    def runner(argv, **kwargs):
        calls.append((argv, kwargs))
        if "--find-file" in argv:
            stdout = str(source)
        elif argv[0] == "nix-build":
            stdout = "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-mindgame\n"
        else:
            stdout = json.dumps(summary)
        return subprocess.CompletedProcess(argv, 0, stdout=stdout, stderr="")

    env = {
        "NIXOS_CONFIG": str(tmp_path / "conflicting.nix"),
        "NIX_PATH": "nixpkgs=/host/channel:nixos-config=/wrong/config.nix",
        "NIX_REMOTE": "daemon",
        "NIX_CONFIG": "sandbox = true\nsubstituters = https://host-cache.invalid",
        "NIX_USER_CONF_FILES": "/host/user/nix.conf",
        "HOME": "/home/host-user",
        "PATH": os.environ["PATH"],
    }

    def make_check(**overrides):
        arguments = {
            "env": env,
            "runner": runner,
            "state_reader": lambda: dict(state),
            "hostname_file": hostname,
            "installed_config": installed,
            "hardware": hardware,
        }
        arguments.update(overrides)
        return current_nixos.HostCheck(checkout, **arguments)

    return {
        "checkout": checkout,
        "target": target,
        "source": source,
        "hardware": hardware,
        "hostname": hostname,
        "installed": installed,
        "summary": summary,
        "state": state,
        "env": env,
        "calls": calls,
        "check": make_check,
    }


def capture(host_fixture, tmp_path):
    path = tmp_path / "baseline.json"
    report = current_nixos.execute("baseline", host_fixture["check"](), path)
    assert report["status"] == "passed", report.get("error")
    return path, report


def test_current_host_check_command_contract(host_fixture, tmp_path, monkeypatch):
    fixture = host_fixture
    baseline, report = capture(fixture, tmp_path)
    env_before = dict(fixture["env"])
    verified = []
    monkeypatch.setattr(current_nixos, "verify_realized_system", verified.append)
    for action in ("evaluate", "build"):
        result = current_nixos.execute(
            action, fixture["check"](), tmp_path / f"{action}.json", baseline
        )
        assert result["status"] == "passed", result.get("error")
        assert result["summary"] == report["summary"]
        assert result["stateBefore"] == result["stateAfter"]
    assert fixture["env"] == env_before
    assert len(verified) == 1
    assert verified[0] == Path("/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-mindgame")
    assert len(fixture["calls"]) == 7
    for argv, kwargs in fixture["calls"]:
        env = kwargs["env"]
        assert env["NIXOS_CONFIG"] == str(fixture["target"].resolve())
        assert all(env[key] == value for key, value in env_before.items() if key != "NIXOS_CONFIG")
        assert kwargs["cwd"] == str(fixture["checkout"].resolve())
        assert kwargs["check"] is False
        assert ["-I", f"nixos-config={fixture['target'].resolve()}"] == argv[-2:] or (
            ["-I", f"nixos-config={fixture['target'].resolve()}"] == argv[-4:-2]
        )
        if "--find-file" not in argv:
            assert argv[-2:] == ["-I", f"nixpkgs={fixture['source'].resolve()}"]
        assert argv[0] in {"nix-instantiate", "nix-build"}
        assert not any("frame" in arg for arg in argv)
        assert not set(argv) & {"sudo", "switch", "test", "boot", "sync.sh", "sync.py"}
        assert not any("switch-to-configuration" in arg for arg in argv)
    build = [argv for argv, _ in fixture["calls"] if argv[0] == "nix-build"]
    assert build == [
        [
            "nix-build",
            "--no-out-link",
            str(fixture["source"] / "nixos"),
            "-A",
            "system",
            "-I",
            f"nixos-config={fixture['target']}",
            "-I",
            f"nixpkgs={fixture['source']}",
        ]
    ]
    assert report["inputs"]["revision"] == "host-source-revision"
    assert "NIX_CONFIG" not in baseline.read_text()
    assert "host-cache.invalid" not in baseline.read_text()


@pytest.mark.parametrize("change", ["source", "revision", "hardware", "environment", "target"])
def test_current_host_changed_inputs_refuse_comparison(host_fixture, tmp_path, change):
    fixture = host_fixture
    baseline, _ = capture(fixture, tmp_path)
    if change == "revision":
        (fixture["source"] / ".git-revision").write_text("different revision")
    elif change == "hardware":
        fixture["hardware"].write_text("# different hardware")
    elif change == "environment":
        fixture["env"]["NIX_REMOTE"] = "local"
    elif change == "target":
        fixture["installed"].unlink()
        fixture["installed"].symlink_to(fixture["hardware"])
    else:
        data = json.loads(baseline.read_text())
        data["inputs"]["source"] = "/another/source"
        baseline.write_text(json.dumps(data))
    fixture["calls"].clear()
    result = current_nixos.execute(
        "evaluate", fixture["check"](), tmp_path / "after.json", baseline
    )
    assert result["status"] == "failed"
    assert "changed" in result["error"] or "does not select" in result["error"]
    assert not any("--eval" in argv for argv, _ in fixture["calls"])


def test_current_host_failed_baseline_is_not_a_comparison(host_fixture, tmp_path):
    def broken(argv, **kwargs):
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr="pre-existing failure")

    baseline = tmp_path / "failed.json"
    result = current_nixos.execute("baseline", host_fixture["check"](runner=broken), baseline)
    assert result["status"] == "failed"
    assert "pre-existing failure" in result["error"]
    assert result["stateBefore"] == result["stateAfter"]
    result = current_nixos.execute(
        "evaluate", host_fixture["check"](), tmp_path / "after.json", baseline
    )
    assert result["status"] == "failed"
    assert "Baseline capture failed" in result["error"]
    assert host_fixture["calls"] == []


@pytest.mark.parametrize("key", ["drvPath", "affectedPackages", "settings"])
def test_current_host_summary_change_blocks_build(host_fixture, tmp_path, key):
    baseline, _ = capture(host_fixture, tmp_path)
    host_fixture["summary"][key] = "changed"
    result = current_nixos.execute(
        "build", host_fixture["check"](), tmp_path / "after.json", baseline
    )
    assert result["status"] == "failed"
    assert not any(argv[0] == "nix-build" for argv, _ in host_fixture["calls"])


def test_current_host_no_activation(host_fixture, tmp_path):
    baseline, _ = capture(host_fixture, tmp_path)
    states = iter(
        [
            dict(host_fixture["state"]),
            {**host_fixture["state"], "systemProfileGeneration": "system-263-link"},
        ]
    )
    result = current_nixos.execute(
        "evaluate",
        host_fixture["check"](state_reader=lambda: next(states)),
        tmp_path / "after.json",
        baseline,
    )
    assert result["status"] == "failed"
    assert "system-profile generation changed" in result["error"]


def test_current_host_activation_since_baseline_refused(host_fixture, tmp_path):
    baseline, _ = capture(host_fixture, tmp_path)
    host_fixture["state"]["currentSystem"] = "/nix/store/different-running-system"
    host_fixture["calls"].clear()
    result = current_nixos.execute(
        "evaluate", host_fixture["check"](), tmp_path / "after.json", baseline
    )
    assert result["status"] == "failed"
    assert "Running system" in result["error"]
    assert host_fixture["calls"] == []


def test_current_host_realized_executable_checked_not_run(tmp_path):
    output = tmp_path / "realized"
    (output / "bin").mkdir(parents=True)
    executable = output / "bin/switch-to-configuration"
    marker = tmp_path / "activated"
    executable.write_text(f"#!/bin/sh\ntouch '{marker}'\n")
    executable.chmod(0o755)
    current_nixos.verify_realized_system(output)
    assert not marker.exists()
    executable.chmod(0o644)
    with pytest.raises(current_nixos.CheckError, match="executable"):
        current_nixos.verify_realized_system(output)


def test_current_host_artifacts_private_and_not_overwritten(host_fixture, tmp_path):
    with pytest.raises(current_nixos.CheckError, match="not the checkout"):
        current_nixos.private_artifact(
            host_fixture["checkout"] / "baseline.json", host_fixture["checkout"], "baseline"
        )
    path, _ = capture(host_fixture, tmp_path)
    assert path.stat().st_mode & 0o777 == 0o600
    with pytest.raises(FileExistsError):
        current_nixos.write_artifact(path, {"status": "passed"})


def test_current_host_real_hardware_required(host_fixture, tmp_path):
    host_fixture["hostname"].write_text("another-host")
    result = current_nixos.execute("baseline", host_fixture["check"](), tmp_path / "result.json")
    assert result["status"] == "failed"
    assert "real mindgame host" in result["error"]
    assert host_fixture["calls"] == []


def test_current_host_config_selection_sentinel(tmp_path):
    """Exercise the real NixOS entry point's env precedence, not just recorded argv."""
    if shutil.which("nix-instantiate") is None:
        pytest.skip("Actual NixOS config-selection fixture requires nix-instantiate")
    resolved = subprocess.run(
        ["nix-instantiate", "--find-file", "nixpkgs"],
        text=True,
        capture_output=True,
        check=False,
        timeout=60,
    )
    if resolved.returncode:
        pytest.fail(f"Cannot resolve nixpkgs for actual sentinel fixture: {resolved.stderr}")
    source = Path(resolved.stdout.strip()).resolve(strict=True)
    checkout = tmp_path / "sentinel checkout with spaces"
    target = checkout / "mindgame/configuration.nix"
    target.parent.mkdir(parents=True)
    target.write_text(
        '{ networking.hostName = "checkout-sentinel"; system.stateVersion = "25.11"; }'
    )
    conflicting = tmp_path / "inherited.nix"
    conflicting.write_text(
        '{ networking.hostName = "inherited-sentinel"; system.stateVersion = "25.11"; }'
    )
    hardware = tmp_path / "hardware.nix"
    hardware.write_text("{}")
    inherited = {**os.environ, "NIXOS_CONFIG": str(conflicting)}
    check = current_nixos.HostCheck(checkout, env=inherited, hardware=hardware)
    check.source = source
    expression = (
        f'(import (builtins.toPath {json.dumps(str(source))} + "/nixos") {{}})'
        ".config.networking.hostName"
    )
    argv = [
        "nix-instantiate",
        "--eval",
        "--strict",
        "--json",
        "--expr",
        expression,
        *check.bindings(),
    ]
    assert json.loads(check.run(argv)) == "checkout-sentinel"
    wrong = subprocess.run(
        argv, env=inherited, text=True, capture_output=True, check=True, timeout=120
    )
    assert json.loads(wrong.stdout) == "inherited-sentinel"
    assert inherited["NIXOS_CONFIG"] == str(conflicting)
