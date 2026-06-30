#!/usr/bin/env python3
"""slurp — move file(s) or director(ies) into dotfiles/ and symlink them back.

For each path, the item is moved into ``dotfiles/<target>/<path-relative-to-home>``
and replaced at its original location with a symlink pointing at the moved copy.
Symlinks are relative when the item lives under $HOME, absolute otherwise.

Every move is transactional: if the symlink can't be created the original is
restored, and when overwriting an existing dotfiles copy the old copy is kept as
a backup until the new one is safely in place. The tool never leaves a path in a
half-moved state.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import termios
import tty
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent
DOTFILES_SOURCE = REPO_DIR / "dotfiles"


# ---------------------------------------------------------------------------
# Terminal colors (auto-disabled when not a TTY or NO_COLOR is set)
# ---------------------------------------------------------------------------


def _color_enabled() -> bool:
    return sys.stdout.isatty() and "NO_COLOR" not in os.environ


def _wrap(code: str, text: str) -> str:
    if not _color_enabled():
        return text
    return f"\033[{code}m{text}\033[0m"


def bold(text: str) -> str:
    return _wrap("1", text)


def green(text: str) -> str:
    return _wrap("32", text)


def yellow(text: str) -> str:
    return _wrap("33", text)


def red(text: str) -> str:
    return _wrap("31", text)


def cyan(text: str) -> str:
    return _wrap("36", text)


def dim(text: str) -> str:
    return _wrap("2", text)


# ---------------------------------------------------------------------------
# Pure logic (no I/O — trivially testable)
# ---------------------------------------------------------------------------


def shorten_path(path: str | Path, home: Path | None = None) -> str:
    """Shorten a path for display, using ~ for the home directory."""
    path_str = str(path)
    if home is None:
        home = Path.home()
    home_str = str(home)
    if path_str.startswith(home_str + "/"):
        return "~" + path_str[len(home_str) :]
    return path_str


def relative_placement(absolute: Path, home: Path, cwd: Path) -> tuple[Path, bool]:
    """Work out where a path should live inside a dotfiles target.

    Returns ``(relative_path, under_home)``. Paths under $HOME are placed by
    their path relative to home (so ``~/.config/foo`` -> ``.config/foo``).
    Anything else is placed by its path relative to the current directory, and
    falling back to just its name when it lives outside the tree entirely.
    """
    try:
        return absolute.relative_to(home), True
    except ValueError:
        pass
    try:
        return absolute.relative_to(cwd), False
    except ValueError:
        return Path(absolute.name), False


def symlink_target_for(dest: Path, link_location: Path, under_home: bool) -> str:
    """Compute the string a symlink at ``link_location`` should point at.

    Relative (so the repo stays portable) when the item is under $HOME,
    absolute otherwise.
    """
    if under_home:
        return os.path.relpath(dest, link_location.parent)
    return str(dest)


def points_at(link: Path, dest: Path) -> bool:
    """True if ``link`` is a symlink already resolving to ``dest``."""
    if not link.is_symlink():
        return False
    raw = Path(os.readlink(link))
    resolved = raw if raw.is_absolute() else (link.parent / raw)
    return os.path.normpath(resolved) == os.path.normpath(dest)


# ---------------------------------------------------------------------------
# Filesystem helpers
# ---------------------------------------------------------------------------


def _remove_path(path: Path) -> None:
    """Remove a file, symlink, or directory tree."""
    if path.is_symlink() or not path.is_dir():
        path.unlink()
    else:
        shutil.rmtree(path)


def _unique_backup(dest: Path) -> Path:
    """A non-existent sibling path to stash an existing dest before overwriting."""
    candidate = dest.with_name(dest.name + ".slurp-bak")
    counter = 1
    while candidate.exists() or candidate.is_symlink():
        candidate = dest.with_name(f"{dest.name}.slurp-bak.{counter}")
        counter += 1
    return candidate


def list_targets(dotfiles_dir: Path) -> list[str]:
    """Sorted list of immediate subdirectories of the dotfiles directory."""
    if not dotfiles_dir.is_dir():
        return []
    return sorted(e.name for e in dotfiles_dir.iterdir() if e.is_dir())


def show_diff(existing: Path, incoming: Path) -> None:
    """Print a recursive diff of the existing dotfiles copy vs. the incoming source.

    Lines are labelled ``dotfiles`` (the current copy) and ``incoming`` (what the
    move would put there). Works for both files and directories via ``diff -ruN``.
    """
    try:
        result = subprocess.run(
            [
                "diff",
                "-ruN",
                "--label",
                "dotfiles",
                "--label",
                "incoming",
                str(existing),
                str(incoming),
            ],
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        print(f"  {yellow('(diff command not available)')}")
        return
    if result.returncode == 0:
        print(f"  {dim('(no differences — contents are identical)')}")
        return
    for line in result.stdout.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            print(green(line))
        elif line.startswith("-") and not line.startswith("---"):
            print(red(line))
        elif line.startswith("@@"):
            print(cyan(line))
        else:
            print(dim(line))


# ---------------------------------------------------------------------------
# Interactive prompts (single-keystroke on a TTY, line-based otherwise)
# ---------------------------------------------------------------------------


def _read_key() -> str:
    if not sys.stdin.isatty():
        return sys.stdin.readline().strip()[:1]
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        char = sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    return char


def prompt_choice(prompt: str, choices: str, default: str) -> str:
    """Prompt for one of ``choices`` (a string of letters). Returns lowercase letter."""
    valid = set(choices.lower())
    while True:
        print(prompt, end="", flush=True)
        char = _read_key().lower()
        print()
        if char in ("\r", "\n", ""):
            return default
        if char in valid:
            return char
        print(f"  {yellow('?')} please choose one of [{choices}]")


def choose_target(dotfiles_dir: Path) -> str:
    """Interactively pick (or default-create) a dotfiles target subdirectory."""
    targets = list_targets(dotfiles_dir)
    if not targets:
        print(f"No targets found in {dotfiles_dir}. Using {cyan('common-all')}.")
        return "common-all"
    print("Available targets:")
    for i, name in enumerate(targets, 1):
        print(f"  {i}. {name}")
    print()
    while True:
        try:
            raw = input(f"Choose target [1-{len(targets)}]: ").strip()
        except EOFError:
            raise SystemExit("Error: no target selected.")
        if raw.isdigit() and 1 <= int(raw) <= len(targets):
            return targets[int(raw) - 1]
        print(f"  {red('Invalid selection.')}")


# ---------------------------------------------------------------------------
# The transactional move
# ---------------------------------------------------------------------------


def perform_slurp(absolute: Path, dest: Path, symlink_target: str) -> None:
    """Move ``absolute`` to ``dest`` and replace it with a symlink, atomically.

    Assumes ``dest`` does not currently exist (the caller resolves conflicts
    first). On any failure the original is restored at ``absolute`` and the
    function re-raises, never leaving a partial state.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(absolute), str(dest))
    try:
        os.symlink(symlink_target, absolute)
    except OSError:
        # Couldn't create the symlink — put the original back where it was.
        shutil.move(str(dest), str(absolute))
        raise


def overwrite_slurp(absolute: Path, dest: Path, symlink_target: str) -> None:
    """Like :func:`perform_slurp` but ``dest`` already exists and gets replaced.

    The existing dest is stashed as a backup until the new copy and its symlink
    are both in place; on failure the backup is restored.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    backup = _unique_backup(dest)
    os.replace(dest, backup)
    try:
        perform_slurp(absolute, dest, symlink_target)
    except BaseException:
        # Restore the previous dotfiles copy if the new move failed.
        if not dest.exists() and not dest.is_symlink():
            os.replace(backup, dest)
        raise
    _remove_path(backup)


def relink_only(absolute: Path, dest: Path, symlink_target: str) -> None:
    """Discard the source and point its location at the existing dotfiles copy."""
    _remove_path(absolute)
    os.symlink(symlink_target, absolute)


# ---------------------------------------------------------------------------
# Per-item orchestration
# ---------------------------------------------------------------------------


def resolve_input(input_path: str, home: Path, cwd: Path) -> Path:
    """Expand ~, make absolute relative to cwd, and normalize."""
    expanded = os.path.expanduser(input_path)
    p = Path(expanded)
    if not p.is_absolute():
        p = cwd / p
    # Normalize without resolving symlinks in the final component, so we can
    # detect/operate on a symlink the user passed directly.
    return Path(os.path.normpath(p))


def slurp_item(
    input_path: str,
    target_dir: Path,
    home: Path,
    cwd: Path,
    force: bool,
    dry_run: bool,
) -> bool:
    """Process one path. Returns True on success (or clean skip), False on error."""
    absolute = resolve_input(input_path, home, cwd)
    display = shorten_path(absolute, home)

    if not absolute.exists() and not absolute.is_symlink():
        print(f"{red('error')} {display}: path not found")
        return False

    relative, under_home = relative_placement(absolute, home, cwd)
    dest = target_dir / relative
    symlink_target = symlink_target_for(dest, absolute, under_home)

    # Already slurped to this exact destination — nothing to do.
    if points_at(absolute, dest) and (dest.exists() or dest.is_symlink()):
        print(f"{dim('skip')} {display}: already symlinked into dotfiles")
        return True

    if absolute.is_symlink():
        print(
            f"{yellow('warning')} {display} is a symlink "
            f"(-> {os.readlink(absolute)}); moving the link itself."
        )

    dest_exists = dest.exists() or dest.is_symlink()
    resolution = "move"  # move | overwrite | relink | skip

    if dest_exists:
        if force:
            resolution = "overwrite"
        elif not sys.stdin.isatty():
            print(
                f"{yellow('skip')} {display}: destination exists "
                f"({shorten_path(dest, home)}); use --force or run interactively."
            )
            return False
        else:
            print(f"{yellow('conflict')} {shorten_path(dest, home)} already exists.")
            while True:
                choice = prompt_choice(
                    "  [o]verwrite dotfiles copy / [k]eep existing & relink / [d]iff / [s]kip? ",
                    "okds",
                    "s",
                )
                if choice == "d":
                    show_diff(dest, absolute)
                    continue
                break
            resolution = {"o": "overwrite", "k": "relink", "s": "skip"}[choice]

    if resolution == "skip":
        print(f"{dim('skip')} {display}")
        return True

    if dry_run:
        action = {
            "move": "move into dotfiles",
            "overwrite": "overwrite dotfiles copy with this one",
            "relink": "discard source, relink to existing dotfiles copy",
        }[resolution]
        print(f"{cyan('[dry-run]')} {display}")
        print(f"            {action}")
        print(f"            symlink -> {symlink_target}")
        return True

    try:
        if resolution == "overwrite":
            overwrite_slurp(absolute, dest, symlink_target)
        elif resolution == "relink":
            relink_only(absolute, dest, symlink_target)
        else:
            perform_slurp(absolute, dest, symlink_target)
    except OSError as e:
        print(f"{red('error')} {display}: {e}")
        return False

    verb = "relinked" if resolution == "relink" else "moved"
    print(f"{green(verb)} {display} -> {shorten_path(dest, home)}")
    return True


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="slurp",
        description="Move file(s) or director(ies) into dotfiles/ and symlink them back.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  slurp ~/.config/nvim\n"
            "  slurp -t common-all ~/.ssh\n"
            "  slurp -t redline ~/my-custom-config\n"
            "  slurp --dry-run ~/.config/telescope"
        ),
    )
    parser.add_argument("paths", nargs="+", help="file(s) or director(ies) to slurp")
    parser.add_argument(
        "-t", "--target", help="target subdirectory in dotfiles/ (prompts if omitted)"
    )
    parser.add_argument(
        "-d",
        "--dotfiles",
        type=Path,
        default=DOTFILES_SOURCE,
        help="override dotfiles directory (default: ./dotfiles)",
    )
    parser.add_argument("-n", "--dry-run", action="store_true", help="show what would be done")
    parser.add_argument(
        "-f", "--force", action="store_true", help="overwrite existing dotfiles copies"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    home = Path.home()
    cwd = Path.cwd()

    dotfiles_dir: Path = args.dotfiles
    target = args.target
    if not target:
        if not dotfiles_dir.is_dir():
            print(f"Error: dotfiles directory not found: {dotfiles_dir}")
            return 1
        target = choose_target(dotfiles_dir)

    target_dir = dotfiles_dir / target
    if not args.dry_run:
        target_dir.mkdir(parents=True, exist_ok=True)

    print(f"Target: {bold(str(target_dir))}\n")

    errors = 0
    for path in args.paths:
        if not slurp_item(path, target_dir, home, cwd, args.force, args.dry_run):
            errors += 1

    print()
    if errors:
        print(f"Done with {red(str(errors))} error(s).")
        return 1
    print(green("Done!"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
