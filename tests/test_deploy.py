"""Deploy command construction, prompt answering, and failure handling."""

from __future__ import annotations

import shlex

import pytest

import deploy
from deploy import HOSTS, Host, Outcome, PromptResponder, Session

FRAME = next(host for host in HOSTS if host.frame)
REDLINE = Host("redline")


def test_frame_uses_its_user_and_rebuild_script():
    assert FRAME.destination == "steamos@frame"
    assert deploy.step_command(FRAME, "rebuild", action="switch") == "frame/rebuild.sh switch"
    assert deploy.step_command(REDLINE, "rebuild", action="switch") == "sudo nixos-rebuild switch"
    assert deploy.step_command(REDLINE, "rebuild", action="build") == "nixos-rebuild build"
    assert deploy.step_command(REDLINE, "sync", action="switch", force=True) == (
        "./sync.sh redline --force"
    )


def test_remote_command_is_one_quoted_bash_invocation():
    argv = deploy.command_argv(FRAME, "git pull --ff-only", local=False, forward_agent=True)
    assert argv[:3] == ["ssh", "-t", "-A"]
    assert argv[-3:-1] == ["steamos@frame", "--"]
    assert shlex.split(argv[-1]) == ["bash", "-c", "cd ~/nixos-configuration && git pull --ff-only"]


def test_local_command_runs_in_this_checkout():
    argv = deploy.command_argv(REDLINE, "./sync.sh redline", local=True)
    assert argv == ["bash", "-c", f"cd {shlex.quote(str(deploy.REPO_DIR))} && ./sync.sh redline"]


def test_backslashes_are_refused_for_remote_shells():
    with pytest.raises(ValueError):
        deploy.command_argv(REDLINE, r"echo a\b", local=False)


def test_local_host_runs_last_and_unknown_hosts_fail():
    names = [host.name for host in deploy.order_hosts(None, "mindgame")]
    assert names[-1] == "mindgame" and len(names) == len(HOSTS)
    assert [h.name for h in deploy.order_hosts(["redline", "frame"], "x")] == ["redline", "frame"]
    with pytest.raises(ValueError, match="nope"):
        deploy.order_hosts(["nope"], "x")


def test_responder_answers_sudo_prompt_split_across_reads():
    responder = PromptResponder("hunter2", auto_confirm=False)
    assert responder.feed(b"building...\r\n[sudo] pass") == b""
    assert responder.feed(b"word for philpax: ") == b"hunter2\n"
    # The answered prompt does not trigger again on later output.
    assert responder.feed(b"\r\n") == b""


def test_responder_aborts_on_rejected_password():
    responder = PromptResponder("wrong", auto_confirm=False)
    responder.feed(b"[sudo] password for philpax: ")
    assert responder.feed(b"\r\nSorry, try again.\r\n[sudo] password for philpax: ") == b"\x03"
    assert responder.bad_password


def test_responder_confirms_sync_only_when_asked():
    prompt = b"Conflicts: 0\r\nAre these changes OK? (y/n) "
    assert PromptResponder("pw", auto_confirm=True).feed(prompt) == b"y"
    assert PromptResponder("pw", auto_confirm=False).feed(prompt) == b""


def make_session(outcomes, choices, *, local_name="elsewhere", channel=None):
    calls, shells = [], []
    outcomes, choices = iter(outcomes), iter(choices)

    def run_step(session, host, step, command):
        calls.append((host.name, step, command))
        return next(outcomes)

    session = Session(
        action="switch",
        confirm_sync=False,
        local_name=local_name,
        password="old",
        run_step=run_step,
        open_shell=lambda session, host: shells.append(host.name),
        choose=lambda prompt, options: next(choices),
        ask_password=lambda: "new",
        say=lambda text: None,
        channel=channel,
    )
    return session, calls, shells


def test_sync_conflict_can_be_inspected_then_forced():
    ok, fail = Outcome(True), Outcome(False, "exit status 1")
    session, calls, shells = make_session([ok, ok, fail, ok, ok], ["s", "f"])
    deploy.deploy_host(session, FRAME)
    assert shells == ["frame"]
    assert [c[2] for c in calls if c[1] == "sync"] == ["./sync.sh frame", "./sync.sh frame --force"]
    assert session.results["frame"] == {
        "connect": "ok",
        "pull": "ok",
        "sync": "forced",
        "rebuild": "ok",
    }


def test_local_host_skips_connect_and_failed_host_can_be_skipped():
    session, calls, _ = make_session([Outcome(False, "not ff")], ["n"], local_name="redline")
    deploy.deploy_host(session, REDLINE)
    assert [c[1] for c in calls] == ["pull"]
    assert session.results["redline"] == {
        "pull": "failed (not ff)",
        "sync": "skipped",
        "rebuild": "skipped",
    }


def test_rejected_password_is_reentered_and_step_retried():
    ok = Outcome(True)
    session, calls, _ = make_session([ok, ok, ok, Outcome(False, "bad", bad_password=True), ok], [])
    deploy.deploy_host(session, REDLINE)
    assert session.password == "new"
    assert [c[1] for c in calls] == ["connect", "pull", "sync", "rebuild", "rebuild"]


def test_quit_stops_the_run():
    session, _, _ = make_session([Outcome(True), Outcome(False, "not ff")], ["q"])
    with pytest.raises(deploy.Quit):
        deploy.deploy_host(session, REDLINE)
    assert session.results["redline"] == {"connect": "ok", "pull": "failed (not ff)"}


def test_offline_host_is_skipped_without_asking():
    session, calls, _ = make_session([Outcome(False, "unreachable")], [])
    deploy.deploy_host(session, REDLINE)
    assert [c[1] for c in calls] == ["connect"]
    assert session.results["redline"] == {"connect": deploy.OFFLINE}
    lines = []
    deploy.print_summary(session, lines.append)
    assert "offline" in lines[-1] and "connect" not in lines[-1]


def test_channel_step_switches_and_updates_root_nixos_channel():
    command = deploy.step_command(REDLINE, "channel", action="switch", channel="nixos-26.11")
    assert command == (
        "sudo nix-channel --add https://nixos.org/channels/nixos-26.11 nixos"
        " && sudo nix-channel --update nixos"
    )
    for bad in ("26.11", "nixos-26.11; rm -rf ~", "https://example.com/nixos"):
        with pytest.raises(ValueError):
            deploy.channel_url(bad)


def test_channel_runs_before_rebuild_only_when_requested():
    ok = Outcome(True)
    session, calls, _ = make_session([ok] * 5, [], channel="nixos-26.11")
    deploy.deploy_host(session, REDLINE)
    assert [c[1] for c in calls] == ["connect", "pull", "sync", "channel", "rebuild"]
    session, calls, _ = make_session([ok] * 4, [])
    deploy.deploy_host(session, REDLINE)
    assert "channel" not in [c[1] for c in calls]


def test_frame_channel_step_sets_matching_system_manager_branch():
    command = deploy.step_command(FRAME, "channel", action="switch", channel="nixos-26.05")
    nix_channel = f"sudo {deploy.FRAME_NIX_CHANNEL}"
    assert command == (
        f"{nix_channel} --add https://nixos.org/channels/nixos-26.05 nixos"
        f" && {nix_channel} --add"
        " https://github.com/numtide/system-manager/archive/release-26.05.tar.gz system-manager"
        f" && {nix_channel} --update nixos system-manager"
    )
    session, calls, _ = make_session([Outcome(True)] * 5, [], channel="nixos-26.05")
    deploy.deploy_host(session, FRAME)
    assert [c[1] for c in calls] == ["connect", "pull", "sync", "channel", "rebuild"]


@pytest.mark.parametrize(
    ("channel", "branch"),
    [
        ("nixos-26.05", "release-26.05"),
        ("nixos-26.05-small", "release-26.05"),
        ("nixos-unstable", "main"),
        ("nixos-unstable-small", "main"),
    ],
)
def test_system_manager_branch_follows_nixos_release(channel, branch):
    assert deploy.system_manager_url(channel).endswith(f"/{branch}.tar.gz")


def test_channels_without_a_system_manager_branch_are_refused():
    with pytest.raises(ValueError):
        deploy.system_manager_url("nixos-weird")


def test_channel_cannot_be_combined_with_build():
    with pytest.raises(SystemExit):
        deploy.main(["--build", "--channel", "nixos-26.11"])
