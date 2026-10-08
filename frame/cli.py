#!/usr/bin/python3
"""Host-executable command interface for the home-backed Frame environment."""

import argparse
import importlib
import json
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from frame.core import Frame
    from frame.paths import FrameError
else:
    from .core import Frame
    from .paths import FrameError


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--home", help="Selected existing home; defaults to HOME")
    result.add_argument("--state-dir", help="State directory beneath the selected home")
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("install", "update"):
        command = commands.add_parser(name)
        command.add_argument("--nixpkgs-pin", help="Trusted revision/hash JSON selection")
        command.add_argument("--overrides", help="Trusted executable Nix package override")
    command = commands.add_parser("enter")
    command.add_argument("argv", nargs=argparse.REMAINDER)
    commands.add_parser("status")
    commands.add_parser("rollback")
    command = commands.add_parser("ready", help="Read-only namespace and automatic-entry preflight")
    command.add_argument("--quiet", action="store_true")
    command = commands.add_parser("activate")
    command.add_argument("--dry-run", action="store_true")
    command = commands.add_parser("agent")
    command.add_argument("action", choices=("status", "stop"))
    return result


def activate(frame, *, dry_run=False, confirm=None):
    module = importlib.import_module("frame.activation")
    frame.activation_config_home()
    input_fn = (lambda text: "yes" if confirm(text) else "no") if confirm else None
    return module.handle_cli(frame, dry_run=dry_run, input_fn=input_fn)


def main(argv=None, *, runner=None, repo=None, environ=None, downloader=None, confirm=None):
    args = parser().parse_args(argv)
    try:
        frame = Frame(
            args.home,
            args.state_dir,
            runner=runner,
            repo=repo,
            environ=environ,
            downloader=downloader,
        )
        if args.command in ("install", "update"):
            getattr(frame, args.command)(args.nixpkgs_pin, args.overrides)
        elif args.command == "rollback":
            frame.rollback()
        elif args.command == "enter":
            command = args.argv
            if command and command[0] == "--":
                command = command[1:]
            return frame.enter(command or None)
        elif args.command == "status":
            print(json.dumps(frame.status(), indent=2, sort_keys=True))
        elif args.command == "ready":
            frame.readiness(activation=True)
        elif args.command == "activate":
            return activate(frame, dry_run=args.dry_run, confirm=confirm)
        elif args.command == "agent":
            manager = frame.make_agent_manager()
            if args.action == "status":
                print(json.dumps(manager.status(frame.environ).as_dict(), indent=2, sort_keys=True))
            else:
                manager.stop()
    except (FrameError, OSError, ValueError, RuntimeError) as exc:
        if not getattr(args, "quiet", False):
            print(f"frame-cli: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
