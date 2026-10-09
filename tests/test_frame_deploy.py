"""Combined Frame deployment without system changes or implicit activation consent."""

import json
import os
import shutil
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path

import pytest

from frame.core import Frame
from frame.deploy import deploy
from frame.paths import FrameError, Paths
from tests.test_frame_activation import fake_refresh_fonts, make_profile

PIN = {"rev": "1" * 40, "sha256": "sha256-" + "A" * 43 + "="}
ROOT = Path(__file__).resolve().parents[1]


class DeploymentFrame:
    def __init__(self, home, repo):
        self.home = home
        self.repo = repo
        self.paths = Paths(home)
        self.state = self.paths.state
        self.profile = self.paths.profile
        self.environ = {"HOME": str(home), "PATH": "/usr/bin:/bin"}
        self.events = []
        self.candidate = str(make_profile(home, "candidate"))
        self.fail_build = False

    def activation_config_home(self):
        self.events.append("policy")
        if self.environ.get("XDG_CONFIG_HOME", "") not in ("", str(self.home / ".config")):
            raise FrameError("Activation requires default config location")

    def select_sources(self):
        return PIN, self.repo / "frame/nixpkgs.json", None

    def validate_profile(self):
        return self.candidate

    def readiness(self, *, activation=False):
        assert activation
        self.events.append("readiness")

    def install(self):
        self.events.append("install")
        if self.fail_build:
            raise FrameError("build failed")
        self.state.mkdir(parents=True)
        self.profile.symlink_to(self.candidate)

    def update(self):
        self.events.append("update")
        if self.fail_build:
            raise FrameError("build failed")

    @contextmanager
    def lock(self):
        self.events.append("lock")
        yield


@pytest.fixture
def deployment(tmp_path, monkeypatch):
    home, repo = tmp_path / "home", tmp_path / "repo"
    home.mkdir()
    (repo / "frame/templates").mkdir(parents=True)
    (repo / "common-all/dotfiles").mkdir(parents=True)
    (repo / "common-all/dotfiles/.tool").write_text("shared")
    (repo / "frame/sync.json").write_text(
        json.dumps({"schema_version": 1, "layers": ["common-all"], "exclusions": []})
    )
    (repo / "frame/nixpkgs.json").write_text(json.dumps(PIN))
    for template in (ROOT / "frame/templates").iterdir():
        (repo / "frame/templates" / template.name).write_bytes(template.read_bytes())
    frame = DeploymentFrame(home, repo)
    monkeypatch.setattr("frame.activation.Activation.refresh_fonts", fake_refresh_fonts)
    return frame


def snapshot(home):
    return {
        str(path.relative_to(home)): (
            path.lstat().st_mode,
            path.readlink() if path.is_symlink() else path.read_bytes() if path.is_file() else None,
        )
        for path in home.rglob("*")
    }


@pytest.mark.parametrize("installed", [False, True])
def test_combined_dry_run_is_read_only(deployment, installed):
    frame = deployment
    if installed:
        frame.install()
    frame.events.clear()
    before = snapshot(frame.home)
    messages = []
    assert (
        deploy(
            frame,
            dry_run=True,
            confirm=lambda _: pytest.fail("dry-run prompt"),
            output=messages.append,
        )
        == 0
    )
    assert snapshot(frame.home) == before
    assert (
        "install" not in frame.events
        and "update" not in frame.events
        and "lock" not in frame.events
    )
    assert any("~/.tool [create]" in message for message in messages)
    assert not frame.home.joinpath(".tool").exists()


@pytest.mark.parametrize("installed", [False, True])
def test_profile_stage_precedes_single_confirmed_activation(deployment, installed):
    frame = deployment
    if installed:
        frame.install()
    frame.events.clear()
    prompts = []

    def confirm(description):
        prompts.append(description)
        assert ("update" if installed else "install") in frame.events
        assert not frame.home.joinpath(".tool").exists()
        return True

    assert deploy(frame, confirm=confirm, output=lambda _: None) == 0
    assert len(prompts) == 1 and "Imported layers: common-all" in prompts[0]
    assert "Dotfiles (1):" in prompts[0] and "CLI profile" in prompts[0]
    assert (frame.home / ".tool").is_symlink()
    assert (frame.state / "activation.json").is_file()
    assert (frame.home / ".bash_profile").is_file()
    assert frame.events.index("update" if installed else "install") < frame.events.index("lock")


@pytest.mark.parametrize("conflict", [False, True])
def test_repeated_combined_sync_reuses_assets(deployment, monkeypatch, conflict):
    from frame.activation import Activation

    frame = deployment
    if conflict:
        (frame.home / ".tool").write_text("preserved")
    expected = 1 if conflict else 0
    assert deploy(frame, confirm=lambda _: True, output=lambda _: None) == expected
    pointer = os.readlink(frame.state / "host-assets/current")
    before = snapshot(frame.home)

    def update():
        frame.events.append("update")
        manager = Activation(frame)
        prepared = manager.prepare(frame.validate_profile())
        manager.publish(prepared)

    monkeypatch.setattr(frame, "update", update)
    monkeypatch.setattr(
        Activation, "export", lambda *args: pytest.fail("repeat sync must not export assets")
    )
    monkeypatch.setattr(
        Activation,
        "refresh_fonts",
        lambda *args: pytest.fail("repeat sync must not refresh Fontconfig"),
    )
    assert deploy(frame, confirm=lambda _: True, output=lambda _: None) == expected
    assert os.readlink(frame.state / "host-assets/current") == pointer
    after = snapshot(frame.home)
    manifest = ".local/state/nixos-configuration/sync-home.json"
    before_state = json.loads(before.pop(manifest)[1])
    after_state = json.loads(after.pop(manifest)[1])
    before_state.pop("timestamp")
    after_state.pop("timestamp")
    assert before_state == after_state
    assert after == before


def test_declined_activation_keeps_profile_but_not_home_integration(deployment):
    frame = deployment
    assert deploy(frame, confirm=lambda _: False, output=lambda _: None) == 1
    assert frame.profile.is_symlink()
    assert not (frame.state / "activation.json").exists()
    assert not (frame.home / ".tool").exists()
    assert not (frame.home / ".bash_profile").exists()


def test_failed_update_never_reaches_activation(deployment):
    frame = deployment
    frame.install()
    frame.fail_build = True
    before = snapshot(frame.home)
    with pytest.raises(FrameError, match="build failed"):
        deploy(
            frame, confirm=lambda _: pytest.fail("failed build activation"), output=lambda _: None
        )
    assert snapshot(frame.home) == before


def test_conflict_is_preserved_and_returns_partial_integration(deployment):
    frame = deployment
    (frame.home / ".tool").write_text("user content")
    assert deploy(frame, confirm=lambda _: True, output=lambda _: None) == 1
    assert (frame.home / ".tool").read_text() == "user content"
    assert not (frame.home / ".bash_profile").exists()


def test_combined_update_conflict_preserves_existing_startup_hooks(deployment):
    frame = deployment
    assert deploy(frame, confirm=lambda _: True, output=lambda _: None) == 0
    manifest_path = frame.state / "activation.json"
    assert json.loads(manifest_path.read_text())["complete"] is True
    startup_paths = [
        frame.home / ".bashrc",
        frame.home / ".bash_profile",
        frame.state / "auto-enter.bash",
    ]
    before = {path: path.read_bytes() for path in startup_paths}
    (frame.repo / "common-all/dotfiles/.new-tool").write_text("shared addition")
    (frame.home / ".new-tool").write_text("user content")
    frame.events.clear()

    assert deploy(frame, confirm=lambda _: True, output=lambda _: None) == 1
    assert "update" in frame.events
    assert {path: path.read_bytes() for path in startup_paths} == before
    assert (frame.home / ".new-tool").read_text() == "user content"
    manifest = json.loads(manifest_path.read_text())
    assert manifest["complete"] is False
    assert all(str(path) in manifest["owned"] for path in startup_paths)


@pytest.mark.parametrize("installed", [False, True])
def test_confirmation_uses_post_deployment_profile_and_home_selection(
    deployment, monkeypatch, installed
):
    frame = deployment
    if installed:
        frame.install()
    action = "update" if installed else "install"
    original = getattr(frame, action)

    def changed_deployment():
        original()
        frame.candidate = str(make_profile(frame.home, "new-selection"))
        frame.profile.unlink()
        frame.profile.symlink_to(frame.candidate)
        (frame.repo / "common-all/dotfiles/.after-deployment").write_text("new selection")

    monkeypatch.setattr(frame, action, changed_deployment)
    prompts = []

    def confirm(description):
        prompts.append(description)
        assert "~/sources/profile-new-selection" in description
        assert "~/.after-deployment" in description
        assert not (frame.home / ".after-deployment").exists()
        return True

    assert deploy(frame, confirm=confirm, output=lambda _: None) == 0
    assert len(prompts) == 1
    assert (frame.home / ".after-deployment").is_symlink()
    assert json.loads((frame.state / "activation.json").read_text())["profile"] == frame.candidate


def test_unsupported_config_home_fails_before_profile_mutation(deployment):
    frame = deployment
    frame.environ["XDG_CONFIG_HOME"] = str(frame.home / "custom")
    before = snapshot(frame.home)
    with pytest.raises(FrameError, match="default config"):
        deploy(frame, confirm=lambda _: pytest.fail("unsupported activation"))
    assert snapshot(frame.home) == before
    assert frame.events == ["policy"]


def test_actual_sync_shell_fresh_home_dry_run_is_read_only(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "host-data"))
    bash = shutil.which("bash")
    if bash is None:
        pytest.skip("Bash is required for the sync.sh entry point")
    home, tools = tmp_path / "home", tmp_path / "tools"
    home.mkdir()
    tools.mkdir()
    interpreter = tools / "python3"
    interpreter.write_text(
        f"#!{sys.executable}\n"
        "import pwd,runpy,sys\n"
        "from pathlib import Path\n"
        "from types import SimpleNamespace\n"
        "pwd.getpwuid=lambda uid: SimpleNamespace(pw_shell='/bin/bash')\n"
        "path=sys.argv[1]\n"
        "sys.path.insert(0,str(Path(path).parent))\n"
        "sys.argv=sys.argv[1:]\n"
        "runpy.run_path(path,run_name='__main__')\n"
    )
    interpreter.chmod(0o755)
    result = subprocess.run(
        [bash, str(ROOT / "sync.sh"), "frame", "--dry-run"],
        env={
            **os.environ,
            "HOME": str(home),
            "XDG_CONFIG_HOME": "",
            "XDG_DATA_HOME": "",
            "PATH": str(tools) + os.pathsep + os.environ["PATH"],
        },
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert not list(home.iterdir())
    assert "Frame profile action: install" in result.stdout
    assert "Imported layers: common-all" in result.stdout
    assert "Dotfiles" in result.stdout and "CLI profile" in result.stdout
    assert "  keep:" not in result.stdout


@pytest.mark.parametrize("dry_run", [False, True])
def test_invalid_pin_fails_before_profile_stage(tmp_path, monkeypatch, dry_run):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "host-config"))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "host-data"))
    home, repo = tmp_path / "home", tmp_path / "repo"
    home.mkdir()
    (repo / "frame").mkdir(parents=True)
    (repo / "frame/sync.json").write_text(
        json.dumps({"schema_version": 1, "layers": [], "exclusions": []})
    )
    (repo / "frame/nixpkgs.json").write_text("invalid")
    frame = Frame(home, repo=repo, environ={"HOME": str(home), "PATH": os.environ["PATH"]})
    monkeypatch.setattr(frame, "activation_config_home", lambda: None)
    monkeypatch.setattr(frame, "install", lambda: pytest.fail("invalid selection installed"))
    with pytest.raises(FrameError, match="selected nixpkgs pin"):
        deploy(frame, dry_run=dry_run)
    assert list(home.iterdir()) == []
