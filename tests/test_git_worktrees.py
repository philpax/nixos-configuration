"""Exercise the Fish worktree helpers against temporary Git repositories."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

FISH = shutil.which("fish")
CONFIG = Path(__file__).resolve().parents[1] / "common-all/dotfiles/.config/fish/config.fish"
pytestmark = pytest.mark.skipif(FISH is None, reason="fish is not installed")


def git(repo, *args, check=True):
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=check,
        capture_output=True,
        text=True,
    )


@pytest.fixture
def repo(tmp_path, monkeypatch):
    for key in os.environ:
        if key.startswith("GIT_"):
            monkeypatch.delenv(key)
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    repo = tmp_path / "repo with spaces"
    repo.mkdir()
    git(repo, "init", "--initial-branch=A")
    git(repo, "config", "user.name", "Worktree Test")
    git(repo, "config", "user.email", "worktree@example.invalid")
    git(repo, "config", "commit.gpgsign", "false")
    git(repo, "commit", "--allow-empty", "-m", "A")
    git(repo, "switch", "-c", "B")
    git(repo, "commit", "--allow-empty", "-m", "B")
    return repo


@pytest.fixture
def gwta(tmp_path, repo):
    # Load the real helper definitions without running unrelated shell initialization.
    config = CONFIG.read_text()
    start = config.index("function _gwt_root ")
    end = config.index("\nfunction dlretry ", start)
    helpers = tmp_path / "worktree-helpers.fish"
    helpers.write_text(config[start:end])

    def run(*args, cwd=None, setup=""):
        script = (
            "source $argv[1]\n"
            + setup
            + "\ngwta $argv[2..]\n"
            + "set -l result $status\n"
            + "printf 'Final directory: %s\\n' $PWD\n"
            + "exit $result\n"
        )
        return subprocess.run(
            [FISH, "--no-config", "--command", script, str(helpers), *args],
            cwd=cwd or repo,
            capture_output=True,
            text=True,
        )

    return run


def assert_location(result, path, branch):
    commit = git(path, "rev-parse", "--short", "HEAD").stdout.strip()
    assert result.returncode == 0, result.stderr
    assert f"Directory: {path}\n" in result.stdout
    assert f"Branch: {branch} ({commit})\n" in result.stdout
    assert f"Final directory: {path}\n" in result.stdout


def test_creates_branch_from_explicit_ref(gwta, repo):
    result = gwta("C", "A")
    start = git(repo, "rev-parse", "A").stdout.strip()
    assert f"Created branch 'C' from 'A' ({start}) and created worktree." in result.stdout
    assert git(repo, "rev-parse", "C").stdout.strip() == start
    assert git(repo, "branch", "--show-current").stdout.strip() == "B"
    assert_location(result, repo / ".worktrees/C", "C")


@pytest.mark.parametrize("ref", ["missing-ref", "--help"])
def test_invalid_explicit_ref_fails_without_changes(gwta, repo, ref):
    result = gwta("C", ref)
    assert result.returncode != 0
    assert f"Error: starting ref '{ref}' does not resolve to a commit" in result.stderr
    assert "no branch or worktree created" in result.stderr
    assert "Created " not in result.stdout
    assert "Directory:" not in result.stdout
    assert f"Final directory: {repo}\n" in result.stdout
    assert not (repo / ".worktrees").exists()
    assert git(repo, "show-ref", "--verify", "refs/heads/C", check=False).returncode != 0


def test_missing_name_prints_usage(gwta, repo):
    result = gwta()
    assert result.returncode != 0
    assert "Usage: gwta <name> [ref]" in result.stderr
    assert not (repo / ".worktrees").exists()


def test_default_head_is_reported(gwta, repo):
    result = gwta("C")
    start = git(repo, "rev-parse", "B").stdout.strip()
    assert "No starting ref supplied" in result.stdout
    assert "using HEAD" in result.stdout
    assert f"Created branch 'C' from 'HEAD' ({start})" in result.stdout
    assert git(repo, "rev-parse", "C").stdout.strip() == start
    assert_location(result, repo / ".worktrees/C", "C")


def test_implicit_same_name_ref_is_preserved(gwta, repo):
    git(repo, "tag", "C", "A")
    result = gwta("C")
    start = git(repo, "rev-parse", "A").stdout.strip()
    assert f"Created branch 'C' from 'C' ({start})" in result.stdout
    assert "using HEAD" not in result.stdout
    assert git(repo, "rev-parse", "refs/heads/C").stdout.strip() == start
    assert_location(result, repo / ".worktrees/C", "C")


def test_remote_starting_ref_preserves_tracking(gwta, repo):
    git(repo, "remote", "add", "origin", str(repo))
    git(repo, "fetch", "origin", "A:refs/remotes/origin/A")
    result = gwta("C", "origin/A")
    assert git(repo, "rev-parse", "C").stdout == git(repo, "rev-parse", "A").stdout
    assert git(repo, "rev-parse", "--abbrev-ref", "C@{upstream}").stdout.strip() == "origin/A"
    assert "from 'origin/A'" in result.stdout
    assert_location(result, repo / ".worktrees/C", "C")


@pytest.mark.parametrize("ref", ["A", "missing-ref"])
def test_existing_branch_warns_that_ref_is_ignored(gwta, repo, ref):
    git(repo, "branch", "C", "B")
    result = gwta("C", ref)
    assert f"Warning: branch 'C' already exists; ignoring starting ref '{ref}'." in result.stderr
    assert "Created worktree for existing branch 'C'; no branch created." in result.stdout
    assert git(repo, "rev-parse", "C").stdout == git(repo, "rev-parse", "B").stdout
    assert_location(result, repo / ".worktrees/C", "C")


def test_existing_branch_without_ref_is_reported(gwta, repo):
    git(repo, "branch", "C", "A")
    result = gwta("C")
    assert "Warning:" not in result.stderr
    assert "Created worktree for existing branch 'C'; no branch created." in result.stdout
    assert_location(result, repo / ".worktrees/C", "C")


@pytest.mark.parametrize("ref", [None, "missing-ref"])
def test_existing_worktree_reports_actual_branch(gwta, repo, ref):
    path = repo / ".worktrees/C"
    git(repo, "worktree", "add", "-b", "D", str(path), "A")
    before = git(repo, "worktree", "list", "--porcelain").stdout
    result = gwta("C", *([ref] if ref else []))
    if ref:
        assert (
            f"Warning: worktree 'C' already exists; ignoring starting ref '{ref}'." in result.stderr
        )
    else:
        assert "Warning:" not in result.stderr
    assert "no branch or worktree created" in result.stdout
    assert git(repo, "worktree", "list", "--porcelain").stdout == before
    assert_location(result, path, "D")


def test_existing_detached_worktree_is_reported(gwta, repo):
    path = repo / ".worktrees/C"
    git(repo, "worktree", "add", "--detach", str(path), "A")
    result = gwta("C")
    assert "no branch or worktree created" in result.stdout
    assert_location(result, path, "(detached HEAD)")


def test_creation_from_another_worktree_uses_main_repo_root(gwta, repo):
    path = repo / ".worktrees/D"
    git(repo, "worktree", "add", "-b", "D", str(path), "B")
    result = gwta("C", "A", cwd=path)
    assert_location(result, repo / ".worktrees/C", "C")


def test_git_failure_does_not_report_success(gwta, repo):
    result = gwta("B")
    assert result.returncode != 0
    assert "Created " not in result.stdout
    assert "Directory:" not in result.stdout
    assert "Branch:" not in result.stdout
    assert f"Final directory: {repo}\n" in result.stdout


def test_cd_failure_after_creation_reports_only_completed_actions(gwta, repo):
    result = gwta("C", "A", setup="function _gwt_cd; return 1; end")
    assert result.returncode != 0
    assert "Created branch 'C' from 'A'" in result.stdout
    assert (repo / ".worktrees/C").is_dir()
    assert git(repo, "rev-parse", "C").stdout == git(repo, "rev-parse", "A").stdout
    assert "Directory:" not in result.stdout
    assert "Branch:" not in result.stdout
    assert f"Final directory: {repo}\n" in result.stdout


def test_cd_failure_is_not_hidden_for_existing_worktree(gwta, repo):
    path = repo / ".worktrees/C"
    git(repo, "worktree", "add", "-b", "C", str(path), "A")
    result = gwta("C", setup="function _gwt_cd; return 1; end")
    assert result.returncode != 0
    assert "Entered " not in result.stdout
    assert "Directory:" not in result.stdout
    assert "Branch:" not in result.stdout
    assert f"Final directory: {repo}\n" in result.stdout


@pytest.mark.parametrize("status", [0, 1])
def test_direnv_status_is_preserved(gwta, repo, status):
    path = repo / ".worktrees/C"
    git(repo, "worktree", "add", "-b", "C", str(path), "A")
    (path / ".envrc").write_text("# test\n")
    result = gwta("C", setup=f"function direnv; echo direnv:$argv; return {status}; end")
    assert "direnv:allow" in result.stdout
    if status == 0:
        assert_location(result, path, "C")
    else:
        assert result.returncode != 0
        assert "Directory:" not in result.stdout
        assert "Branch:" not in result.stdout
        assert f"Final directory: {path}\n" in result.stdout
