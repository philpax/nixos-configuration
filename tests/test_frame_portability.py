"""Exercise shared portability changes with real tools and synthetic HOME."""

import os
import shlex
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
GIT_CONFIG = ROOT / "common-all/dotfiles/.gitconfig"
AICMD = ROOT / "common-all/dotfiles/.config/fish/functions/aicmd.fish"


def isolated_environment(home):
    return {
        "HOME": str(home),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local/share"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"),
        "LC_ALL": "C",
    }


def test_git_home_relative_paths(tmp_path):
    git = shutil.which("git")
    if not git:
        pytest.skip("actual Git required")
    home = tmp_path / "synthetic home with spaces"
    home.mkdir()
    (home / ".gitconfig").write_bytes(GIT_CONFIG.read_bytes())
    env = isolated_environment(home)
    for key, name in (
        ("user.signingkey", "id_rsa.pub"),
        ("gpg.ssh.allowedSignersFile", "allowed_signers"),
    ):
        raw = (
            subprocess.run(
                [git, "config", "--get", key], env=env, capture_output=True, check=True, timeout=10
            )
            .stdout.decode()
            .strip()
        )
        assert raw == "~/.ssh/" + name
        actual = (
            subprocess.run(
                [git, "config", "--path", "--get", key],
                env=env,
                capture_output=True,
                check=True,
                timeout=10,
            )
            .stdout.decode()
            .strip()
        )
        assert actual == str(home / ".ssh" / name)
        assert "/home/philpax" not in actual
    # Path interpolation is exercised without generating or reading any key.
    assert not (home / ".ssh").exists()


def host_os_description():
    values = {}
    for line in Path("/etc/os-release").read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            name, value = line.split("=", 1)
            words = shlex.split(value)
            values[name] = " ".join(words)
    return values.get("PRETTY_NAME", "Linux")


def test_aicmd_uses_host_os_release(tmp_path):
    fish = shutil.which("fish")
    if not fish:
        pytest.skip("actual fish required")
    home = tmp_path / "synthetic-home"
    home.mkdir()
    capture = home / "request.txt"
    # Source only aicmd, never _ai_request's implementation or normal startup.
    # The stub captures the actual system prompt and returns no command, so no
    # generated shell command, assistant executable, curl, or network runs.
    script = (
        "function _ai_request; printf '%s\\n' $argv[1] $argv[3] $argv[5] > "
        + shlex.quote(str(capture))
        + "; return 0; end; source "
        + shlex.quote(str(AICMD))
        + "; aicmd 'synthetic portability request'"
    )
    result = subprocess.run(
        [fish, "--no-config", "-c", script],
        env=isolated_environment(home),
        capture_output=True,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr.decode()
    assert result.stdout == b""
    mode, system_prompt, request = capture.read_text().splitlines()
    assert mode == "aicmd"
    assert request == "synthetic portability request"
    assert "OS: " + host_os_description() + ", Shell: fish." in system_prompt
    assert not list(home.glob(".ssh/*"))
    assert not (home / ".config/polytoken").exists()
    assert not (home / ".config/makima").exists()
    assert not (home / ".claude").exists()
