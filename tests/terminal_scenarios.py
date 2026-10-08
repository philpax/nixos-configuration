"""Bounded real-terminal loader and copied-asset scenarios; no GUI is launched."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pty
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace

import tomllib

# Direct script execution must also find the repository's activation module.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from frame.activation import Activation  # noqa: E402, I001


class TerminalScenarioError(RuntimeError):
    pass


@dataclass
class Fixture:
    root: Path
    home: Path
    state: Path
    checkout: Path
    wrapper: Path
    ghostty: Path
    alacritty: Path
    bell: Path

    @property
    def args(self) -> list[str]:
        return ["--home", str(self.home), "--state-dir", str(self.state), "enter"]

    @property
    def env(self) -> dict[str, str]:
        env = dict(os.environ)
        for name in ("BASH_ENV", "ENV", "LD_PRELOAD", "LD_LIBRARY_PATH"):
            env.pop(name, None)
        env.update(
            HOME=str(self.home),
            XDG_CONFIG_HOME=str(self.home / ".config"),
            XDG_DATA_HOME=str(self.home / ".local/share"),
            XDG_CACHE_HOME=str(self.home / ".cache"),
            XDG_CONFIG_DIRS=str(self.home / "empty config dirs"),
            SHELL="/bin/sh",
        )
        return env

    def activation(self) -> Activation:
        return Activation(
            SimpleNamespace(home=self.home, state=self.state, repo=self.checkout, environ=self.env),
            source_resolver=lambda path: path.resolve(strict=True),
        )


def prepare_fixture(root: Path, repo: Path, bell_source: Path | None = None) -> Fixture:
    root = root.absolute()
    home = root / "home with spaces"
    checkout = root / "checkout with spaces"
    state = home / ".local/share/frame state with spaces"
    home.mkdir(parents=True)
    state.mkdir(parents=True)
    paths = {}
    for name, filename in (("ghostty", "config"), ("alacritty", "alacritty.toml")):
        relative = Path(f"common-dev-desktop/dotfiles/.config/{name}/{filename}")
        source = checkout / relative
        source.parent.mkdir(parents=True)
        shutil.copyfile(repo / relative, source)
        deployed = home / ".config" / name / filename
        deployed.parent.mkdir(parents=True)
        deployed.symlink_to(source)
        paths[name] = deployed
    wrapper = home / ".local/bin/frame-cli"
    wrapper.parent.mkdir(parents=True)
    bell = state / "host-assets/current/bell-window-system.oga"
    bell.parent.mkdir(parents=True)
    if bell_source is None:
        bell.write_bytes(b"OggS synthetic unit fixture; real loader jobs use Ocean bytes")
    else:
        shutil.copyfile(bell_source, bell)
    fixture = Fixture(
        root, home, state, checkout, wrapper, paths["ghostty"], paths["alacritty"], bell
    )
    for operation in fixture.activation().generated(home / ".local/share/fonts/frame-cli"):
        if operation.kind == "file" and operation.path.name in {
            "machine",
            "machine.toml",
            "99-frame-cli.conf",
        }:
            operation.path.parent.mkdir(parents=True, exist_ok=True)
            operation.path.write_bytes(operation.content)
    shell = tomllib.loads((fixture.alacritty.parent / "machine.toml").read_text())["terminal"][
        "shell"
    ]
    if shell != {"program": str(wrapper), "args": fixture.args}:
        raise TerminalScenarioError(f"generated shell does not preserve argv: {shell}")
    manifest = {
        "home": str(home),
        "main": str(fixture.alacritty),
        "import": str(fixture.alacritty.parent / "machine.toml"),
        "wrapper": str(wrapper),
        "args": fixture.args,
        "bell": str(bell),
    }
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2))
    return fixture


def run(argv: list[str], fixture: Fixture) -> subprocess.CompletedProcess:
    try:
        result = subprocess.run(
            argv, env=fixture.env, cwd=fixture.home, capture_output=True, text=True, timeout=120
        )
    except FileNotFoundError as exc:
        raise TerminalScenarioError(f"required loader executable absent: {argv[0]}") from exc
    if result.returncode:
        raise TerminalScenarioError(
            f"{argv!r}: exit {result.returncode}\n{result.stdout}\n{result.stderr}"
        )
    # Ghostty emits informational startup logs; warnings/errors still fail the scenario.
    if any(marker in result.stderr.lower() for marker in ("warning", "error", "warn(")):
        raise TerminalScenarioError(f"loader diagnostic: {result.stderr}")
    return result


def effective_values(output: str) -> dict[str, list[str]]:
    values = {}
    for line in output.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator:
            raise TerminalScenarioError(f"invalid effective config line: {line!r}")
        values.setdefault(key.strip(), []).append(value.strip())
    return values


def ghostty_deployed_config_validation(ghostty: str, fixture: Fixture) -> dict:
    machine = fixture.ghostty.parent / "machine"
    content = machine.read_bytes()
    expected_command = next(
        line.partition("=")[2].strip()
        for line in content.decode().splitlines()
        if line.startswith("command =")
    )
    outputs = {}
    for present in (False, True):
        if present:
            machine.write_bytes(content)
        else:
            machine.unlink()
        # Explicit validation canonicalizes the symlink. Default loading retains the
        # deployed pathname and proves that its relative machine include is loaded.
        explicit = run([ghostty, "+validate-config", f"--config-file={fixture.ghostty}"], fixture)
        normal = run([ghostty, "+validate-config"], fixture)
        if explicit.stdout.strip() or normal.stdout.strip():
            raise TerminalScenarioError(
                f"Ghostty validation diagnostics: {explicit.stdout}{normal.stdout}"
            )
        output = run([ghostty, "+show-config", "--changes-only=false"], fixture).stdout
        values = effective_values(output)
        if "Cozette" not in values.get("font-family", []):
            raise TerminalScenarioError("Ghostty did not load the shared Cozette family")
        bindings = run([ghostty, "+list-keybinds", "--plain"], fixture).stdout
        if "ctrl+shift+enter=new_window" not in bindings or r"shift+enter=text:\\n" not in bindings:
            raise TerminalScenarioError(f"Ghostty lost shared bindings: {bindings}")
        if present:
            if values.get("command") != [expected_command]:
                raise TerminalScenarioError(
                    f"Ghostty did not resolve Frame command: {values.get('command')}"
                )
            if values.get("bell-audio-path") != [str(fixture.bell)]:
                raise TerminalScenarioError("Ghostty did not resolve the host-visible Ocean bell")
            if not fixture.bell.is_file() or not fixture.bell.read_bytes():
                raise TerminalScenarioError("published bell is unreadable")
            if not any(str(machine) in path for path in values.get("config-file", [])):
                raise TerminalScenarioError(
                    "Ghostty effective include path is not the deployed machine file"
                )
        elif str(fixture.wrapper) in output:
            raise TerminalScenarioError(
                "missing machine config unexpectedly supplied a Frame command"
            )
        outputs["present" if present else "missing"] = values
    # Invalid imported options must be diagnosed, rather than accepted as defaults.
    machine.write_bytes(content + b"\nframe-invalid-option = yes\n")
    bad = subprocess.run(
        [ghostty, "+validate-config"], env=fixture.env, capture_output=True, text=True, timeout=120
    )
    machine.write_bytes(content)
    if bad.returncode == 0 or "frame-invalid-option" not in bad.stdout + bad.stderr:
        raise TerminalScenarioError("Ghostty validation accepted an invalid imported option")
    return outputs


def command_pty_scenario(argv: list[str], env: dict[str, str], *, input_bytes: bytes) -> bytes:
    """Execute the rendered command without opening a GUI, with bounded PTY I/O."""
    master, slave = pty.openpty()

    def controlling_terminal():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        argv,
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        preexec_fn=controlling_terminal,
    )
    os.close(slave)
    output = bytearray()
    deadline = time.monotonic() + 20
    os.write(master, input_bytes)
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.2)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
            if process.poll() is not None:
                break
        try:
            status = process.wait(timeout=2)
        except subprocess.TimeoutExpired as exc:
            raise TerminalScenarioError("terminal command timed out") from exc
        if status != 0:
            raise TerminalScenarioError(f"terminal command exited {process.returncode}: {output!r}")
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        os.close(master)
    return bytes(output)


def argv_check_script(fixture: Fixture) -> str:
    checks = [f'[ "$#" = {len(fixture.args)} ] || exit 91']
    for index, argument in enumerate(fixture.args, 1):
        checks.append(f'[ "${index}" = {shlex.quote(argument)} ] || exit 92')
    return "#!/bin/sh\n" + "\n".join(checks) + "\n"


def test_terminal_command_spawns_frame_fish(fixture: Fixture, fish: str) -> None:
    # This test wrapper stands in for namespace entry. It checks exact argv and
    # launches the selected profile's real fish. Namespace behavior has separate tests.
    fixture.wrapper.write_text(
        argv_check_script(fixture) + f"exec {shlex.quote(fish)} --no-config --interactive\n"
    )
    fixture.wrapper.chmod(0o755)
    command = next(
        line.partition("=")[2].strip()
        for line in (fixture.ghostty.parent / "machine").read_text().splitlines()
        if line.startswith("command =")
    )
    shell = tomllib.loads((fixture.alacritty.parent / "machine.toml").read_text())["terminal"][
        "shell"
    ]
    for argv in (["/bin/sh", "-c", command], [shell["program"], *shell["args"]]):
        output = command_pty_scenario(
            argv,
            fixture.env,
            input_bytes=b"printf 'FRAME_%s_%s\\n' FISH $version; exit\n",
        )
        if b"FRAME_FISH_" not in output:
            raise TerminalScenarioError(f"rendered terminal command did not start fish: {output!r}")


def export_font_artifact(repo: Path, profile: Path, destination: Path) -> None:
    """Use production export, then transfer only regular fonts/bell/template bytes."""
    from host_fontconfig import validate_artifact

    manifest = json.loads((profile / "share/frame-cli/assets.json").read_text())
    refs = profile / "share/frame-cli/assets"
    if not manifest["fonts"] or manifest["bell"]["reference"] != "bell":
        raise TerminalScenarioError(
            "profile asset manifest does not use fonts/* and bell references"
        )
    declared = [*manifest["fonts"], manifest["bell"]]
    declared.extend(
        companion for font in manifest["fonts"] for companion in font.get("companions", [])
    )
    for record in declared:
        if (refs / record["reference"]).resolve(strict=True) != Path(record["path"]).resolve(
            strict=True
        ):
            raise TerminalScenarioError(f"asset reference differs from manifest: {record}")
    with tempfile.TemporaryDirectory(prefix="frame export scenario ") as temporary:
        root = Path(temporary)
        home = root / "home with spaces"
        home.mkdir()
        activation = Activation(
            SimpleNamespace(home=home, state=home / "frame state", repo=repo, environ={}),
            source_resolver=lambda path: path.resolve(strict=True),
        )
        name = activation.export(str(profile))
        generation = activation.assets / "generations" / name
        if destination.exists() or destination.is_symlink():
            raise TerminalScenarioError(f"artifact destination already exists: {destination}")
        destination.mkdir(parents=True)
        shutil.copytree(generation / "fonts", destination / "fonts", symlinks=True)
        shutil.copyfile(
            generation / "bell-window-system.oga", destination / "bell-window-system.oga"
        )
        shutil.copyfile(repo / "frame/templates/fontconfig.conf", destination / "fontconfig.conf")
        validate_artifact(destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--root", type=Path, required=True)
    prepare.add_argument("--repo", type=Path, required=True)
    prepare.add_argument("--bell", type=Path, required=True)
    ghost = sub.add_parser("ghostty")
    ghost.add_argument("--ghostty", required=True)
    ghost.add_argument("--fish", required=True)
    ghost.add_argument("--repo", type=Path, required=True)
    ghost.add_argument("--bell", type=Path, required=True)
    export = sub.add_parser("export-fonts")
    export.add_argument("--repo", type=Path, required=True)
    export.add_argument("--profile", type=Path, required=True)
    export.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare_fixture(args.root, args.repo, args.bell)
    elif args.command == "export-fonts":
        export_font_artifact(args.repo, args.profile, args.destination)
    else:
        with tempfile.TemporaryDirectory(prefix="frame real Ghostty ") as temporary:
            fixture = prepare_fixture(Path(temporary), args.repo, args.bell)
            effective = ghostty_deployed_config_validation(args.ghostty, fixture)
            test_terminal_command_spawns_frame_fish(fixture, args.fish)
            print(json.dumps({"effective": effective, "fishCommands": True}, indent=2))


if __name__ == "__main__":
    main()
