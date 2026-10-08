#!/usr/bin/env python3
"""Check the current mindgame checkout without syncing or activating it.

Capture before refactoring:
    uv run tests/check-current-nixos.py baseline
Then use the printed private artifact path:
    uv run tests/check-current-nixos.py evaluate --baseline /tmp/.../baseline.json
    uv run tests/check-current-nixos.py build --baseline /tmp/.../baseline.json

The build command realizes the full system closure; it never runs its activation
executable. Host Nix environment/settings are retained except NIXOS_CONFIG,
which is deliberately bound to the checkout for every Nix subprocess.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


class CheckError(RuntimeError):
    """A failed host check, not evidence of a successful regression comparison."""


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def host_state(
    current_system: Path = Path("/run/current-system"),
    system_profile: Path = Path("/nix/var/nix/profiles/system"),
) -> dict:
    """Record the running system and profile generation without following activation."""
    return {
        "currentSystem": os.readlink(current_system),
        "systemProfileGeneration": os.readlink(system_profile),
        "systemProfileTarget": str(system_profile.resolve(strict=True)),
    }


def current_host_no_activation(before: dict, after: dict) -> None:
    if before != after:
        raise CheckError("Running system or system-profile generation changed during the check")


def verify_realized_system(output: Path) -> None:
    executable = output / "bin/switch-to-configuration"
    if not output.is_dir() or not executable.is_file() or not os.access(executable, os.X_OK):
        raise CheckError("Realized system lacks an executable bin/switch-to-configuration")


class HostCheck:
    def __init__(
        self,
        checkout: Path,
        *,
        env: dict | None = None,
        runner=subprocess.run,
        state_reader=host_state,
        hostname_file: Path = Path("/etc/hostname"),
        installed_config: Path = Path("/etc/nixos/configuration.nix"),
        hardware: Path = Path("/etc/nixos/hardware-configuration.nix"),
        timeout: int = 1800,
    ):
        self.checkout = checkout.resolve(strict=True)
        self.target = (self.checkout / "mindgame/configuration.nix").resolve(strict=True)
        self.hardware = hardware.resolve(strict=True)
        self.hostname_file = hostname_file
        self.installed_config = installed_config
        self.env = dict(os.environ if env is None else env)
        self.env["NIXOS_CONFIG"] = str(self.target)
        self.runner = runner
        self.state_reader = state_reader
        self.timeout = timeout
        self.commands: list[dict] = []
        self.source: Path | None = None

    def run(self, argv: list[str]) -> str:
        record = {"argv": argv, "NIXOS_CONFIG": str(self.target)}
        self.commands.append(record)
        try:
            result = self.runner(
                argv,
                env=dict(self.env),
                cwd=str(self.checkout),
                text=True,
                capture_output=True,
                timeout=self.timeout,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            record["error"] = str(error)
            raise CheckError(f"Host command failed: {argv[0]}: {error}") from error
        record["returncode"] = result.returncode
        if result.stderr:
            record["stderr"] = result.stderr[-8000:]
        if result.returncode:
            raise CheckError(
                f"Host command failed ({result.returncode}): {' '.join(argv)}\n"
                f"{result.stderr[-8000:]}"
            )
        return result.stdout.strip()

    def bindings(self) -> list[str]:
        arguments = ["-I", f"nixos-config={self.target}"]
        if self.source is not None:
            arguments += ["-I", f"nixpkgs={self.source}"]
        return arguments

    def discover(self) -> dict:
        if self.hostname_file.read_text().strip() != "mindgame":
            raise CheckError("Current-host check requires the real mindgame host")
        if self.installed_config.resolve(strict=True) != self.target:
            raise CheckError("Installed NixOS configuration does not select this mindgame checkout")
        common = self.checkout / "common-all/configuration.nix"
        if "/etc/nixos/hardware-configuration.nix" not in common.read_text():
            raise CheckError("The checkout no longer imports the real host hardware configuration")
        self.source = Path(
            self.run(["nix-instantiate", "--find-file", "nixpkgs", *self.bindings()])
        ).resolve(strict=True)
        if not (self.source / "nixos/default.nix").is_file():
            raise CheckError("Resolved host nixpkgs has no NixOS entry point")
        revision_file = self.source / ".git-revision"
        if revision_file.is_file():
            revision = revision_file.read_text().strip()
        elif (self.source / ".git").exists():
            revision = self.run(["git", "-C", str(self.source), "rev-parse", "HEAD"])
        else:
            raise CheckError("Cannot identify the resolved host nixpkgs revision")
        version = self.source / ".version"
        # Retain the settings themselves in subprocess env, but never serialize them.
        selection = {
            key: value
            for key, value in self.env.items()
            if key.startswith("NIX") or key in {"HOME", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS"}
        }
        return {
            "hostname": "mindgame",
            "checkout": str(self.checkout),
            "target": str(self.target),
            "source": str(self.source),
            "revision": revision,
            "version": version.read_text().strip() if version.is_file() else None,
            "hardware": str(self.hardware),
            "hardwareSha256": digest(self.hardware),
            "hostSelectionSha256": hashlib.sha256(
                json.dumps(selection, sort_keys=True).encode()
            ).hexdigest(),
        }

    def evaluate(self) -> dict:
        if self.source is None:
            raise CheckError("Host source must be resolved before evaluation")
        summary = json.loads(
            self.run(
                [
                    "nix-instantiate",
                    "--eval",
                    "--strict",
                    "--json",
                    str(self.checkout / "tests/nix/current-host-summary.nix"),
                    "--argstr",
                    "nixpkgs",
                    str(self.source),
                    "--argstr",
                    "checkout",
                    str(self.checkout),
                    *self.bindings(),
                ]
            )
        )
        if summary.get("hostname") != "mindgame" or summary.get("assertionsPassed") is not True:
            raise CheckError(
                "Evaluation did not validate the mindgame configuration and assertions"
            )
        drv = summary.get("drvPath", "")
        if not drv.startswith("/nix/store/") or not drv.endswith(".drv"):
            raise CheckError("Evaluation did not return a system toplevel derivation")
        return summary

    def build(self) -> Path:
        if self.source is None:
            raise CheckError("Host source must be resolved before building")
        result = self.run(
            [
                "nix-build",
                "--no-out-link",
                str(self.source / "nixos"),
                "-A",
                "system",
                *self.bindings(),
            ]
        )
        lines = result.splitlines()
        if len(lines) != 1 or not lines[0].startswith("/nix/store/"):
            raise CheckError("System build did not return one realized store path")
        output = Path(lines[0])
        verify_realized_system(output)
        return output


def compare_inputs(baseline: dict, inputs: dict) -> None:
    changed = [key for key in baseline["inputs"] if baseline["inputs"][key] != inputs.get(key)]
    if changed:
        raise CheckError(
            f"Host baseline inputs changed: {', '.join(changed)}; do not refresh silently"
        )


def current_host_nixos_evaluation(check: HostCheck, baseline: dict) -> dict:
    summary = check.evaluate()
    changed = [key for key in baseline["summary"] if baseline["summary"][key] != summary.get(key)]
    if changed or summary.keys() != baseline["summary"].keys():
        raise CheckError(f"Current-host summary differs from baseline: {', '.join(changed)}")
    return summary


def current_host_nixos_build(check: HostCheck, baseline: dict) -> Path:
    current_host_nixos_evaluation(check, baseline)
    return check.build()


def read_baseline(path: Path) -> dict:
    baseline = json.loads(path.read_text())
    if baseline.get("status") != "passed" or baseline.get("action") != "baseline":
        raise CheckError(
            "Baseline capture failed or is invalid; no regression comparison is possible"
        )
    if baseline.get("schemaVersion") != 1 or "summary" not in baseline or "inputs" not in baseline:
        raise CheckError("Baseline artifact is incomplete")
    return baseline


def private_artifact(path: Path | None, checkout: Path, action: str) -> Path:
    path = path or Path(tempfile.mkdtemp(prefix="current-nixos-")) / f"{action}.json"
    path = path.resolve()
    if path.is_relative_to(checkout.resolve()):
        raise CheckError(
            "Host expectations must remain in private temporary artifacts, not the checkout"
        )
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def write_artifact(path: Path, report: dict) -> None:
    # Exclusive creation prevents overwriting a baseline merely to accept a new result.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")


def execute(
    action: str, check: HostCheck, artifact: Path, baseline_path: Path | None = None
) -> dict:
    report = {"schemaVersion": 1, "action": action, "status": "failed", "commands": check.commands}
    try:
        baseline = read_baseline(baseline_path) if action != "baseline" else None
        before = check.state_reader()
        report["stateBefore"] = before
        try:
            if baseline is not None:
                current_host_no_activation(baseline["stateBefore"], before)
            inputs = check.discover()
            report["inputs"] = inputs
            if baseline is not None:
                compare_inputs(baseline, inputs)
            if action == "baseline":
                report["summary"] = check.evaluate()
            elif action == "evaluate":
                report["summary"] = current_host_nixos_evaluation(check, baseline)
            elif action == "build":
                report["systemPath"] = str(current_host_nixos_build(check, baseline))
                report["summary"] = baseline["summary"]
            else:
                raise CheckError(f"Unknown check action: {action}")
        finally:
            after = check.state_reader()
            report["stateAfter"] = after
            current_host_no_activation(before, after)
        report["status"] = "passed"
    except (CheckError, OSError, ValueError, KeyError, TypeError) as error:
        report["error"] = str(error)
    write_artifact(artifact, report)
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("action", choices=("baseline", "evaluate", "build"))
    parser.add_argument("--checkout", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--baseline", type=Path, help="Successful pre-refactor baseline artifact")
    parser.add_argument(
        "--artifact", type=Path, help="New private JSON result path (default: /tmp)"
    )
    parser.add_argument("--timeout", type=int, default=1800, help="Per-command timeout in seconds")
    args = parser.parse_args(argv)
    if args.action != "baseline" and args.baseline is None:
        parser.error("evaluate and build require --baseline")
    try:
        artifact = private_artifact(args.artifact, args.checkout, args.action)
        check = HostCheck(args.checkout, timeout=args.timeout)
        report = execute(args.action, check, artifact, args.baseline)
    except (CheckError, OSError) as error:
        print(f"Current-host check failed before capture: {error}", file=sys.stderr)
        return 1
    print(f"Artifact: {artifact}")
    print(f"Status: {report['status']}")
    inputs = report.get("inputs", {})
    print(f"Bound target: {inputs.get('target', check.target)}")
    print(f"Host source: {inputs.get('source')}; revision: {inputs.get('revision')}")
    print(f"System derivation: {report.get('summary', {}).get('drvPath')}")
    for command in report["commands"]:
        print(f"Command (NIXOS_CONFIG={command['NIXOS_CONFIG']}): {command['argv']!r}")
    if "systemPath" in report:
        print(f"Realized system: {report['systemPath']} (activation executable checked, not run)")
    if "error" in report:
        print(report["error"], file=sys.stderr)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
