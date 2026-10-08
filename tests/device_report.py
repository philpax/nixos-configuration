#!/usr/bin/python3
"""Retain bounded results for an explicitly approved isolated Frame device trial."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import tempfile
import time
from dataclasses import replace
from pathlib import Path
from xml.sax.saxutils import escape

import frame_device_scenarios as scenarios
import host_fontconfig

LOG_LIMIT = 2 * 1024 * 1024
BASELINE = {
    ".profile": "787ab203279ada7ab10fd7c252f9b414ef4185d632ca2a9d2d38307cd8cca606",
    ".bash_profile": "cc5377a96dec32f6dbfce27d29d6019ca563a50366a1f91d659a1229ad0bc3f9",
    ".bashrc": "3f7b58fbafb37544dbecb996cd72618898c9ca4f78b25c1ea8a8bd2c901fb384",
}


def host_baseline():
    home = Path("/home/steamos")
    hashes = {name: hashlib.sha256((home / name).read_bytes()).hexdigest() for name in BASELINE}
    return {
        "hashes": hashes,
        "hashes_match": hashes == BASELINE,
        "host_nix": os.path.lexists("/nix"),
    }


class ReportRunner(scenarios.DeviceRunner):
    def __init__(self, paths, label):
        super().__init__(paths, execute=True)
        self.log_dir = paths.check(paths.root / ("logs-" + label))
        self.log_dir.mkdir(mode=0o700)
        self.results = []

    def retain(self, command, started, *, output=b"", error=None, returncode=None):
        index = len(self.results) + 1
        log = self.log_dir / f"{index:03d}.log"
        log.write_bytes(output[-LOG_LIMIT:])
        result = {
            "argv": list(command.argv),
            "seconds": round(time.monotonic() - started, 3),
            "returncode": returncode,
            "log": str(log),
            "truncated": len(output) > LOG_LIMIT,
        }
        if error is not None:
            result["error"] = str(error)[-8000:]
        self.results.append(result)
        (self.log_dir / "commands.json").write_text(json.dumps(self.results, indent=2))

    def run(self, command, *, expected=0):
        started = time.monotonic()
        print("COMMAND " + json.dumps(list(command.argv)), flush=True)
        try:
            result = super().run(command, expected=expected)
        except BaseException as exc:
            self.retain(command, started, output=str(exc).encode(), error=exc)
            raise
        self.retain(
            command,
            started,
            output=result.stdout + b"\n--- stderr ---\n" + result.stderr,
            returncode=result.returncode,
        )
        return result

    def pty(self, command, exchanges, *, timeout=45):
        started = time.monotonic()
        try:
            transcript = super().pty(command, exchanges, timeout=timeout)
        except BaseException as exc:
            self.retain(command, started, output=str(exc).encode(), error=exc)
            raise
        self.retain(command, started, output=transcript, returncode=0)
        return transcript


def provenance(runner):
    status = json.loads(runner.run(runner.cli("status")).stdout)
    assert status["ready"], status
    info = status["build_info"]
    assert len(info["cliPackages"]) == 86, len(info["cliPackages"])
    assert len(info["fontPackages"]) == 12, len(info["fontPackages"])
    assert info["system"] == "aarch64-linux", info["system"]
    assert any(
        item["name"].startswith("helix-") and "-steel-8d189f4" in item["name"]
        for item in info["cliPackages"]
    ), "installed profile does not contain the custom Steel Helix"
    return status


def host_fonts(runner):
    host_fontconfig.require_no_nix()
    artifact = (runner.paths.state / "host-assets/current").resolve(strict=True)
    assert artifact.is_relative_to(runner.paths.root)
    files = []
    pending = [artifact]
    while pending:
        directory = pending.pop()
        for item in directory.iterdir():
            mode = item.lstat().st_mode
            assert not stat.S_ISLNK(mode), item
            if stat.S_ISDIR(mode):
                pending.append(item)
            else:
                assert stat.S_ISREG(mode), item
                files.append(item)
    assert (artifact / "bell-window-system.oga") in files
    temporary = runner.paths.check(runner.paths.root / "tmp")
    temporary.mkdir(mode=0o700, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="host-fontconfig-", dir=temporary) as cache:
        cache = Path(cache)
        config = cache / "fonts.conf"
        template = (runner.paths.checkout / "frame/templates/fontconfig.conf").read_text()
        config.write_text(
            template.replace("@FONT_DIR@", escape(str(artifact / "fonts"))).replace(
                "</fontconfig>", f"<cachedir>{escape(str(cache / 'cache'))}</cachedir></fontconfig>"
            )
        )
        env = dict(runner.env)
        env.update(FONTCONFIG_FILE=str(config), FONTCONFIG_PATH=str(cache))
        host_fontconfig.fc_run(["/usr/bin/fc-cache", "-f", str(artifact / "fonts")], env)
        records = host_fontconfig.parse_font_records(
            host_fontconfig.fc_run(["/usr/bin/fc-list", "--format", "%{family}\\t%{file}\\n"], env)
        )
        for _, filename in records:
            assert filename.is_file() and filename.resolve().is_relative_to(artifact)
        matches = {}
        for family in host_fontconfig.EXPECTED_FAMILIES:
            assert any(family in families for families, _ in records), family
            matched = host_fontconfig.parse_font_records(
                host_fontconfig.fc_run(
                    ["/usr/bin/fc-match", "--format", "%{family}\\t%{file}\\n", family], env
                )
            )
            assert len(matched) == 1 and family in matched[0][0], (family, matched)
            filename = matched[0][1]
            assert filename.is_file() and filename.resolve().is_relative_to(artifact)
            matches[family] = str(filename.relative_to(artifact))
    return {"files": len(files), "matches": matches, "source_artifact": str(artifact)}


def agent_roots(runner):
    runner.run(runner.cli("agent", "stop"))
    assert not list((runner.paths.state / "store/var/nix/gcroots").glob("frame-agent-*"))
    initial = runner.run(runner.cli("status"))
    assert any(
        p["name"].startswith("fastfetch-")
        for p in json.loads(initial.stdout)["build_info"]["cliPackages"]
    )
    startup = {
        name: (runner.paths.home / name).read_bytes() for name in (".bashrc", ".bash_profile")
    }
    key = runner.paths.work / "retention-key"
    message = runner.fixture("retention-message", "synthetic retention signing message\n")
    try:
        runner.pty(
            runner.cli("enter"),
            [(rb"> ", b"printf 'ROOT-AGENT-READY\\n'\r"), (rb"ROOT-AGENT-READY", b"exit\r")],
        )
        status = json.loads(runner.run(runner.cli("agent", "status")).stdout)
        assert status["kind"] == "managed", status
        control = runner.paths.state / "agent"
        record = json.loads((control / "managed.json").read_text())
        root = Path(record["root"])
        assert root.is_relative_to(runner.paths.state / "store/var/nix/gcroots")
        assert root.is_symlink() and os.readlink(root) == status["generation"]
        socket = "SSH_AUTH_SOCK=" + record["socket"]
        runner.run(runner.enter("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key))
        runner.run(runner.enter("env", socket, "ssh-add", key))
        keys = runner.run(runner.enter("env", socket, "ssh-add", "-l")).stdout

        def retained():
            current = json.loads(runner.run(runner.cli("agent", "status")).stdout)
            assert current == status, (status, current)
            assert json.loads((control / "managed.json").read_text()) == record
            assert root.is_symlink() and os.readlink(root) == status["generation"]
            roots = runner.run(
                runner.enter("nix-store", "--query", "--roots", status["generation"])
            ).stdout.decode()
            logical_root = Path("/nix") / root.relative_to(runner.paths.state / "store")
            assert str(root) in roots or str(logical_root) in roots, roots
            closure = (
                runner.run(
                    runner.enter("nix-store", "--query", "--requisites", status["generation"])
                )
                .stdout.decode()
                .splitlines()
            )
            assert status["generation"] in closure
            assert any("openssh" in path for path in closure)
            assert any("python3" in path for path in closure)
            assert runner.run(runner.enter("env", socket, "ssh-add", "-l")).stdout == keys
            signature = Path(str(message) + ".sig")
            signature.unlink(missing_ok=True)
            runner.run(
                runner.enter(
                    "env",
                    socket,
                    "ssh-keygen",
                    "-Y",
                    "sign",
                    "-f",
                    str(key) + ".pub",
                    "-n",
                    "frame-retention",
                    message,
                )
            )
            verify = runner.enter(
                "ssh-keygen",
                "-Y",
                "check-novalidate",
                "-n",
                "frame-retention",
                "-s",
                signature,
            )
            runner.pty(
                scenarios.Command(verify.argv, input=b"synthetic retention signing message\n"),
                [],
            )
            return len(closure)

        closure_count = retained()
        invalid = runner.fixture(
            "retention-invalid.nix",
            '{ pkgs, cliPackages, fontPackages }: throw "intentional-retention-update-failure"\n',
        )
        failed = runner.run(
            runner.cli("update", "--overrides", invalid, timeout=3600), expected=None
        )
        assert failed.returncode != 0
        assert scenarios.active_profile_identity(initial) == scenarios.active_profile_identity(
            runner.run(runner.cli("status"))
        )
        retained()
        override = runner.fixture(
            "retention-overrides.nix",
            "{ pkgs, cliPackages, fontPackages }: {\n"
            '  cliPackages = builtins.filter (p: (pkgs.lib.getName p) != "fastfetch") '
            "cliPackages ++ [ pkgs.hello ]; inherit fontPackages;\n}\n",
        )
        runner.run(
            runner.cli(
                "update",
                "--nixpkgs-pin",
                runner.paths.checkout / "frame/nixpkgs.json",
                "--overrides",
                override,
                timeout=7200,
            )
        )
        updated = runner.run(runner.cli("status"))
        updated_info = json.loads(updated.stdout)["build_info"]
        assert any(p["name"].startswith("hello-") for p in updated_info["cliPackages"])
        assert not any(p["name"].startswith("fastfetch-") for p in updated_info["cliPackages"])
        assert b"Hello" in runner.run(runner.enter("hello")).stdout
        retained()
        runner.run(runner.cli("rollback", timeout=1800))
        restored = runner.run(runner.cli("status"))
        assert scenarios.active_profile_identity(initial) == scenarios.active_profile_identity(
            restored
        )
        assert scenarios.active_profile_identity(updated) != scenarios.active_profile_identity(
            restored
        )
        retained()
        assert all(
            (runner.paths.home / name).read_bytes() == data for name, data in startup.items()
        )
    finally:
        runner.run(runner.cli("agent", "stop"))
        for path in (key, Path(str(key) + ".pub"), Path(str(message) + ".sig")):
            runner.paths.check(path).unlink(missing_ok=True)
    stopped = json.loads(runner.run(runner.cli("agent", "status")).stdout)
    assert stopped["kind"] == "stopped", stopped
    assert not os.path.lexists(root) and not os.path.lexists(record["socket"])
    return {
        "generation": status["generation"],
        "root": str(root),
        "released": True,
        "requisites": closure_count,
        "keys_retained_across_update_rollback": True,
    }


def shell_auto_entry(runner):
    home = runner.paths.home
    wrapper = home / ".local/bin/frame-cli"
    profile = runner.paths.state / "profile"
    login = ".bash_profile"
    details = {}
    for name, command in (
        (
            "nonlogin",
            scenarios.Command(
                ("/bin/bash", "--noprofile", "--rcfile", str(home / ".bashrc"), "-i")
            ),
        ),
        (
            "login",
            scenarios.Command(
                (
                    "/bin/bash",
                    "--noprofile",
                    "--norc",
                    "-li",
                    "-c",
                    '. "$HOME/' + login + '"; printf "BASH-WAS-RETAINED\\n"',
                )
            ),
        ),
    ):
        transcript = runner.pty(
            command,
            [
                (rb"> ", b"printf 'AUTO-FISH-OK:%s\\n' $FRAME_CLI_ACTIVE\r"),
                (rb"AUTO-FISH-OK:1", b"exit\r"),
            ],
        )
        assert b"BASH-WAS-RETAINED" not in transcript
        details[name] = "fish"

    script = '. "$HOME/.bashrc"; printf "BASH-RETAINED:%s\\n" "$BASH_VERSION"'
    optout = scenarios.Command(
        (
            "/usr/bin/env",
            "FRAME_CLI_NO_AUTO=1",
            "/bin/bash",
            "--noprofile",
            "--norc",
            "-i",
            "-c",
            script,
        )
    )
    transcript = runner.pty(optout, [])
    assert b"BASH-RETAINED:" in transcript and b"automatic entry unavailable" not in transcript
    details["optout"] = "bash"
    nested = runner.enter(
        "bash",
        "--noprofile",
        "--rcfile",
        str(home / ".bashrc"),
        "-i",
        "-c",
        'printf "NESTED-BASH:%s:%s\\n" "$FRAME_CLI_ACTIVE" "$BASH_VERSION"',
    )
    transcript = runner.pty(nested, [])
    assert b"NESTED-BASH:1:" in transcript
    details["nested"] = "bash"
    for name, target in (("missing-wrapper", wrapper), ("broken-profile", profile)):
        moved = target.with_name(target.name + ".device-check")
        assert not os.path.lexists(moved)
        target.rename(moved)
        try:
            broken = scenarios.Command(("/bin/bash", "--noprofile", "--norc", "-i", "-c", script))
            transcript = runner.pty(broken, [])
            assert b"BASH-RETAINED:" in transcript
            assert transcript.count(b"automatic entry unavailable") == 1, transcript
            details[name] = "bash-retained-one-diagnostic"
        finally:
            moved.rename(target)
    quiet = runner.run(
        scenarios.Command(("/bin/bash", "--noprofile", "--norc", "-c", '. "$HOME/.bashrc"'))
    )
    assert quiet.stdout == b"" and quiet.stderr == b""
    details["noninteractive"] = "quiet"
    return details


def transfer_startup(runner):
    script = (
        "import json,sys; from pathlib import Path; "
        "sys.path.insert(0,sys.argv[1]); "
        "from ssh_transport import ssh_file_transfer_startup_scenario; "
        "print(json.dumps(ssh_file_transfer_startup_scenario("
        "Path(sys.argv[2]),rc=Path(sys.argv[3]).read_bytes())))"
    )
    result = runner.run(
        runner.enter(
            "python3",
            "-c",
            script,
            runner.paths.checkout / "tests",
            runner.paths.work / "transport-workflow",
            runner.paths.home / ".bashrc",
        )
    )
    return json.loads(result.stdout)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trial-root", required=True, type=Path)
    parser.add_argument("--name", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--phase", choices=("install", "workflows"), required=True)
    args = parser.parse_args(argv)
    if not args.label.isalnum() or len(args.label) > 16:
        parser.error("label must contain 1-16 ASCII letters or digits")
    paths = scenarios.TrialPaths.create(args.trial_root, args.name)
    for path in (paths.root, paths.home, paths.checkout, paths.work):
        paths.check(path)
        assert stat.S_ISDIR(path.stat().st_mode) and path.stat().st_uid == os.getuid()
    report_path = paths.check(paths.root / ("report-" + args.label + ".json"))
    if report_path.exists():
        parser.error("report label already exists")
    if args.phase == "workflows":
        work = paths.check(paths.root / ("work-" + args.label))
        work.mkdir(mode=0o700)
        paths = replace(paths, work=work)
    report = {
        "phase": args.phase,
        "root": str(paths.root),
        "baseline_before": host_baseline(),
        "scenarios": [],
    }
    assert report["baseline_before"]["hashes_match"] and not report["baseline_before"]["host_nix"]
    runner = ReportRunner(paths, args.label)

    def check(name, action):
        started = time.monotonic()
        result = {"name": name}
        print("START " + name, flush=True)
        try:
            value = action()
            result["passed"] = True
            if value is not None:
                result["details"] = value
        except Exception as exc:
            result.update(passed=False, error=f"{type(exc).__name__}: {exc}"[-8000:])
        result["seconds"] = round(time.monotonic() - started, 3)
        report["scenarios"].append(result)
        report_path.write_text(json.dumps(report, indent=2))
        print(json.dumps(result), flush=True)
        return result["passed"]

    try:
        if args.phase == "install":
            check("full-install", lambda: runner.run(runner.cli("install", timeout=14400)) and None)
            check("full-profile-provenance", lambda: provenance(runner))
        elif check("full-profile-provenance", lambda: provenance(runner)):
            if check(
                "activation-dry-run",
                lambda: runner.run(runner.cli("activate", "--dry-run")) and None,
            ):
                activated = check(
                    "synthetic-home-activation",
                    lambda: (
                        runner.pty(runner.cli("activate", input=b"y\n"), [], timeout=600) and None
                    ),
                )
            else:
                activated = False
            if activated:
                check("host-fontconfig-without-nix", lambda: host_fonts(runner))
                check("bash-automatic-entry-matrix", lambda: shell_auto_entry(runner))
                check("quiet-real-transfer-subprocesses", lambda: transfer_startup(runner))
                check(
                    "shared-fish-subprocess",
                    lambda: scenarios.frame_fish_and_subprocess_scenario(runner),
                )
                check(
                    "compiler-direnv-git-workflow",
                    lambda: scenarios.frame_terminal_workflow_scenario(runner),
                )
                check(
                    "helix-steel-forest-pty",
                    lambda: scenarios.frame_helix_forest_scenario(runner),
                )
                check("ephemeral-agent-signing", lambda: scenarios.frame_ssh_agent_scenario(runner))
                check("agent-root-signing-update-rollback", lambda: agent_roots(runner))
                check("host-fontconfig-after-rollback", lambda: host_fonts(runner))
    finally:
        check("final-owned-agent-stop", lambda: runner.run(runner.cli("agent", "stop")) and None)
        report["baseline_after"] = host_baseline()
        report["commands"] = runner.results
        report["passed"] = (
            all(item["passed"] for item in report["scenarios"])
            and report["baseline_after"]["hashes_match"]
            and not report["baseline_after"]["host_nix"]
        )
        report_path.write_text(json.dumps(report, indent=2))
        print("REPORT " + str(report_path), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
