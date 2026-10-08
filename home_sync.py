"""Read-only home-sync planning and confirmed, non-sudo application.

``plan_home_sync(target=..., home=..., repo=..., state_path=...)`` returns a
reviewable plan without writes. ``apply_home_sync(plan, confirmed=True)`` applies
that plan under its own lock. The caller must display the plan and obtain consent
first. Conflicts remain untouched unless the plan requests force, which backs up
non-directory objects. No agent executable or system command runs here.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import stat
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

# These paths belong to host credentials, session startup, or explicit activation.
PROTECTED_PATHS = (
    ".ssh",
    ".tokens",
    "nixos-clean.sh",
    ".local/state/makima/auth",
    ".config/wayland-autostart.sh",
    ".config/autostart",
    ".config/autostart-scripts",
    ".config/plasma-workspace/env",
    ".config/systemd",
    ".local/share/systemd",
    ".config/environment.d",
    ".config/environment",
    ".pam_environment",
    ".bashrc",
    ".bash_profile",
    ".bash_login",
    ".profile",
    ".zshenv",
    ".zprofile",
    ".zshrc",
    ".zlogin",
    ".xprofile",
    ".xsession",
    ".xsessionrc",
    ".config/mimeapps.list",
    ".config/gtk-3.0/settings.ini",
    ".config/gtk-4.0/settings.ini",
    ".config/ghostty/machine",
    ".config/alacritty/machine.toml",
    ".config/fontconfig/conf.d/99-frame-cli.conf",
    ".local/bin/frame-cli",
    ".config/frame-cli",
    ".local/share/frame-cli",
    ".local/share/fonts/frame-cli",
)
NAME_RE = re.compile(r"[a-z][a-z0-9-]*\Z")


@dataclass(frozen=True)
class HomeOperation:
    destination: Path
    desired_source: Path | None
    previous_source: Path | None
    action: str
    owned: bool = False
    protection: str | None = None
    conflict: str | None = None
    # lstat identity prevents force from replacing a changed object after consent.
    identity: tuple[int, int, int, int, int] | None = None


@dataclass(frozen=True)
class HomeSyncPlan:
    target: str
    home: Path
    repo: Path
    state_path: Path
    layers: tuple[str, ...]
    exclusions: tuple[str, ...]
    operations: tuple[HomeOperation, ...]
    overrides: tuple[tuple[Path, Path, Path], ...]
    warnings: tuple[str, ...]
    ownership: dict[str, str] = field(repr=False)
    state_bytes: bytes | None = field(repr=False)
    force: bool = False

    @property
    def conflicts(self) -> tuple[HomeOperation, ...]:
        return tuple(op for op in self.operations if op.conflict)

    @property
    def symlinks(self) -> list[tuple[Path, Path]]:
        return [
            (op.destination, op.desired_source)
            for op in self.operations
            if op.desired_source is not None and op.action != "protected"
        ]


@dataclass(frozen=True)
class HomeSyncResult:
    ownership: dict[str, str]
    warnings: tuple[str, ...]
    backups: tuple[Path, ...]


def _relative(value: str) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ValueError(f"Invalid relative path: {value!r}")
    path = Path(value)
    if path.is_absolute() or any(p in ("", ".", "..") for p in value.split("/")):
        raise ValueError(f"Unsafe relative path: {value!r}")
    return path


def _absolute(value: str | Path, root: Path) -> Path:
    text = str(value)
    path = Path(text)
    if (
        not path.is_absolute()
        or "\x00" in text
        or any(p in ("", ".", "..") for p in text.split("/")[1:])
        or path == root
        or not path.is_relative_to(root)
    ):
        raise ValueError(f"Path is not canonical beneath {root}: {value}")
    return path


def _identity(path: Path) -> tuple[int, int, int, int, int] | None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns)


def _check_parents(path: Path, home: Path) -> None:
    """Reject redirected parents without resolving the final managed link."""
    _absolute(path, home)
    current = home
    for part in path.relative_to(home).parts[:-1]:
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            return
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError(f"Unsafe parent directory: {current}")


def _control_file(path: Path, home: Path) -> None:
    _check_parents(path, home)
    info = _identity(path)
    if info is not None:
        mode = info[2]
        if not stat.S_ISREG(mode) or path.lstat().st_uid != os.getuid():
            raise ValueError(f"State/lock must be a user-owned regular file: {path}")


def _protected(path: Path, home: Path, exclusions: tuple[str, ...], directory=False) -> bool:
    relative = path.relative_to(home)
    return any(
        relative == exc
        or relative.is_relative_to(exc)
        or (directory and exc.is_relative_to(relative))
        for exc in map(Path, exclusions)
    )


def read_home_state(path: Path, *, home: Path, repo: Path) -> tuple[dict, bytes | None]:
    """Read full scoped metadata. Invalid metadata is an error, never empty state."""
    _control_file(path, home)
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return {"symlinks": {}}, None
    try:
        state = json.loads(raw)
    except (ValueError, UnicodeDecodeError) as exc:
        raise ValueError(f"Malformed home-sync state: {path}") from exc
    if (
        not isinstance(state, dict)
        or type(state.get("schema_version")) is not int
        or state["schema_version"] != 1
        or state.get("mode") != "home-only"
        or state.get("home") != str(home)
        or state.get("repo") != str(repo)
        or not isinstance(state.get("target"), str)
        or not NAME_RE.fullmatch(state["target"])
        or not isinstance(state.get("symlinks"), dict)
        or not all(isinstance(k, str) and isinstance(v, str) for k, v in state["symlinks"].items())
    ):
        raise ValueError(f"Malformed or mismatched home-sync metadata: {path}")
    return state, raw


def _read_selection(repo: Path, target: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    if not isinstance(target, str) or not NAME_RE.fullmatch(target):
        raise ValueError(f"Unsafe home-only target: {target!r}")
    target_dir = repo / target
    if target_dir.is_symlink() or not target_dir.is_dir():
        raise ValueError(f"Unknown home-only target: {target}")
    selection_path = target_dir / "sync.json"
    if selection_path.is_symlink() or not selection_path.is_file():
        raise ValueError(f"Home-only target requires sync.json: {selection_path}")
    try:
        selection = json.loads(selection_path.read_text())
    except (ValueError, UnicodeDecodeError) as exc:
        raise ValueError(f"Malformed home-only selection: {selection_path}") from exc
    if (
        not isinstance(selection, dict)
        or set(selection) != {"schema_version", "layers", "exclusions"}
        or type(selection["schema_version"]) is not int
        or selection["schema_version"] != 1
        or not isinstance(selection["layers"], list)
        or not isinstance(selection["exclusions"], list)
    ):
        raise ValueError("sync.json requires schema_version 1, layers, and exclusions")
    layers = selection["layers"]
    if not all(isinstance(layer, str) and NAME_RE.fullmatch(layer) for layer in layers):
        raise ValueError("Unsafe home-only layer name")
    if len(layers) != len(set(layers)) or target in layers:
        raise ValueError("Duplicate home-only layer or target")
    for layer in layers:
        folder = repo / layer
        if (
            folder.is_symlink()
            or not folder.is_dir()
            or not ((folder / "dotfiles").is_dir() or (folder / "configuration.nix").is_file())
        ):
            raise ValueError(f"Unknown home-only layer: {layer}")
    exclusions = tuple(str(_relative(value)) for value in selection["exclusions"])
    return tuple([*layers, target]), tuple(dict.fromkeys([*PROTECTED_PATHS, *exclusions]))


def _collect_links(repo: Path, home: Path, layers: tuple[str, ...]):
    # Import only selection helpers. The legacy mutation adapter is never called.
    import sync

    selected: dict[Path, Path] = {}
    overrides: list[tuple[Path, Path, Path]] = []

    def add(destination, source):
        _absolute(destination, home)
        source = source.absolute()
        if source != home / ".agents/skills":
            _absolute(source, repo)
            if not source.resolve().is_relative_to(repo):
                raise ValueError(f"Source escapes repository: {source}")
        if destination in selected and selected[destination] != source:
            overrides.append((destination, selected[destination], source))
        selected[destination] = source

    for layer in layers:
        for destination, source in sync.build_symlink_list(repo, home, layer, [], True):
            add(destination, source)
        skills = repo / layer / "dotfiles/.agents/skills"
        for destination, source in sync.build_skill_symlinks(skills, home / ".agents/skills"):
            add(destination, source)
        for destination, source in sync.build_layered_plugin_symlinks(
            repo, home / ".local/share/claude-plugins", layer, []
        ):
            add(destination, source)
    for destination, source in list(selected.items()):
        if (
            destination.parent == home / ".agents/skills"
            and (source / sync.WORK_COMPATIBLE_MARKER).is_file()
        ):
            add(home / ".claude-work/skills" / destination.name, source)
    for destination, source in sync.build_cog_symlinks(
        repo / "steel-cogs", home / ".config/steel/cogs"
    ):
        add(destination, source)
    add(home / ".claude/skills", home / ".agents/skills")
    return selected, overrides


def _link_source(path: Path) -> Path | None:
    """Compare link text lexically; resolving can traverse a new skill directory link."""
    if not path.is_symlink():
        return None
    text = os.readlink(path)
    return Path(os.path.normpath(text if os.path.isabs(text) else str(path.parent / text)))


def _valid_old_source(destination: Path, source: str, home: Path, repo: Path) -> Path:
    if destination == home / ".claude/skills" and source == str(home / ".agents/skills"):
        return Path(source)
    path = _absolute(source, repo)
    if not path.resolve().is_relative_to(repo):
        raise ValueError(f"Recorded source escapes repository: {path}")
    return path


def _migration_directory(path: Path, removals: set[Path]) -> bool:
    """An old skill directory disappears only when every leaf is owned and stale."""
    if path.is_symlink() or not path.is_dir() or not any(p.is_relative_to(path) for p in removals):
        return False
    for root, dirs, files in os.walk(path, followlinks=False):
        for name in [*dirs, *files]:
            entry = Path(root) / name
            if entry.is_symlink() or not entry.is_dir():
                if entry not in removals:
                    return False
    return True


def plan_home_sync(
    *,
    target: str,
    home: Path,
    repo: Path,
    state_path: Path | None = None,
    force: bool = False,
    extra_exclusions: tuple[str, ...] = (),
) -> HomeSyncPlan:
    """Select links and record decisions without prompts, locks, or writes.

    State defaults to <home>/.local/state/nixos-configuration/sync-home.json.
    Home and repo identities are canonical. A custom state path must be absolute
    beneath home. Invalid recorded paths are warned about and never followed.
    extra_exclusions reserves caller-owned relative paths, including custom
    activation state and asset destinations, for creation and stale cleanup.
    """
    home, repo = Path(home).resolve(strict=True), Path(repo).resolve(strict=True)
    if not home.is_dir() or not repo.is_dir() or home.stat().st_uid != os.getuid():
        raise ValueError("Home and repository must be directories; home must be user-owned")
    state_path = (
        Path(state_path) if state_path else home / ".local/state/nixos-configuration/sync-home.json"
    )
    _control_file(state_path, home)
    _control_file(state_path.with_name(state_path.name + ".lock"), home)
    layers, exclusions = _read_selection(repo, target)
    exclusions = tuple(
        dict.fromkeys([*exclusions, *(str(_relative(path)) for path in extra_exclusions)])
    )
    if _protected(state_path, home, exclusions, directory=True) or _protected(
        state_path.with_name(state_path.name + ".lock"), home, exclusions, directory=True
    ):
        raise ValueError("State and lock paths cannot occupy protected destinations")
    # Reserve control paths even when a custom location intersects source dotfiles.
    exclusions = tuple(
        dict.fromkeys(
            [
                *exclusions,
                str(state_path.relative_to(home)),
                str(state_path.with_name(state_path.name + ".lock").relative_to(home)),
            ]
        )
    )
    selected, overrides = _collect_links(repo, home, layers)
    state, raw = read_home_state(state_path, home=home, repo=repo)
    warnings: list[str] = []
    ownership: dict[str, str] = {}
    previous: dict[Path, Path] = {}
    stale: list[HomeOperation] = []
    for text, source in state["symlinks"].items():
        try:
            destination = _absolute(text, home)
            _check_parents(destination, home)
            recorded = _valid_old_source(destination, source, home, repo)
        except (ValueError, OSError) as exc:
            warnings.append(f"Skip invalid recorded entry {text}: {exc}")
            continue
        if _protected(destination, home, exclusions, directory=True):
            if destination not in selected:
                stale.append(
                    HomeOperation(destination, None, recorded, "protected", protection="exclusion")
                )
            continue
        previous[destination] = recorded
        if _link_source(destination) == recorded:
            ownership[text] = source
        elif destination.exists() or destination.is_symlink():
            warnings.append(f"Preserve modified object and drop ownership: {destination}")
        if destination not in selected:
            if text in ownership:
                stale.append(HomeOperation(destination, None, recorded, "remove", True))
            else:
                stale.append(
                    HomeOperation(
                        destination,
                        None,
                        recorded,
                        "skip",
                        conflict="stale object changed or missing",
                    )
                )
    removals = {op.destination for op in stale if op.action == "remove"}
    operations = sorted(stale, key=lambda op: (-len(op.destination.parts), str(op.destination)))
    for destination, source in sorted(selected.items()):
        if _protected(destination, home, exclusions, directory=True):
            operations.append(
                HomeOperation(
                    destination,
                    source,
                    previous.get(destination),
                    "protected",
                    protection="exclusion",
                )
            )
            continue
        try:
            _check_parents(destination, home)
        except ValueError as exc:
            operations.append(
                HomeOperation(
                    destination,
                    source,
                    previous.get(destination),
                    "skip",
                    protection="unsafe parent",
                    conflict=str(exc),
                )
            )
            continue
        owned = str(destination) in ownership
        current = _link_source(destination)
        old = previous.get(destination)
        identity = _identity(destination)
        action, conflict = "create", None
        if current == source:
            action = "keep"
        elif identity is None:
            pass
        elif owned and current == old and old.exists():
            action = "replace"
        elif destination == home / ".claude/skills" and _migration_directory(destination, removals):
            action = "create"
        else:
            conflict = (
                "existing directory"
                if destination.is_dir() and not destination.is_symlink()
                else "unowned or modified object"
            )
            action = "backup" if force and not stat.S_ISDIR(identity[2]) else "skip"
        operations.append(
            HomeOperation(
                destination, source, old, action, owned, conflict=conflict, identity=identity
            )
        )
    return HomeSyncPlan(
        target,
        home,
        repo,
        state_path,
        layers,
        exclusions,
        tuple(operations),
        tuple(overrides),
        tuple(warnings),
        ownership,
        raw,
        force,
    )


@contextmanager
def _parent_fd(path: Path, home: Path, *, create=False):
    """Open each parent without following symlinks, retaining the final directory fd."""
    _check_parents(path, home)
    fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in path.relative_to(home).parts[:-1]:
            if create:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            new_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = new_fd
            if os.fstat(fd).st_uid != os.getuid():
                raise ValueError(f"Foreign parent directory: {path.parent}")
        yield fd
    finally:
        os.close(fd)


@contextmanager
def _mutation_lock(plan: HomeSyncPlan):
    lock = plan.state_path.with_name(plan.state_path.name + ".lock")
    _control_file(lock, plan.home)
    with _parent_fd(lock, plan.home, create=True) as parent:
        fd = os.open(lock.name, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
                raise ValueError(f"Unsafe home-sync lock: {lock}")
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)


def _persist(plan: HomeSyncPlan, ownership: dict[str, str]) -> None:
    _control_file(plan.state_path, plan.home)
    state = {
        "schema_version": 1,
        "mode": "home-only",
        "home": str(plan.home),
        "repo": str(plan.repo),
        "target": plan.target,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "symlinks": ownership,
    }
    with _parent_fd(plan.state_path, plan.home, create=True) as parent:
        temp = f".{plan.state_path.name}.{uuid.uuid4().hex}.tmp"
        fd = os.open(
            temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600, dir_fd=parent
        )
        try:
            with os.fdopen(fd, "w") as output:
                json.dump(state, output, indent=2, sort_keys=True)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(temp, plan.state_path.name, src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
        finally:
            try:
                os.unlink(temp, dir_fd=parent)
            except FileNotFoundError:
                pass


def _cleanup(path: Path, home: Path, exclusions: tuple[str, ...]) -> None:
    current = path.parent
    while current != home:
        if _protected(current, home, exclusions, directory=True):
            break
        try:
            _check_parents(current, home)
            if current.is_symlink() or not current.is_dir():
                break
            with _parent_fd(current, home) as parent:
                os.rmdir(current.name, dir_fd=parent)
        except (OSError, ValueError):
            break
        current = current.parent


def apply_home_sync(plan: HomeSyncPlan, *, confirmed: bool = False) -> HomeSyncResult:
    """Apply only the reviewed operations, with incremental atomic ownership.

    Raises without mutation unless confirmed. State changes since planning require
    a new review. Filesystem changes after planning are preserved and reported.
    Failures propagate; completed and unvisited valid ownership remains in state.
    """
    if not confirmed:
        raise ValueError("Home sync requires explicit confirmation")
    warnings = list(plan.warnings)
    backups: list[Path] = []
    with _mutation_lock(plan):
        _, raw = read_home_state(plan.state_path, home=plan.home, repo=plan.repo)
        if raw != plan.state_bytes:
            raise ValueError("Home-sync state changed after planning; review a new plan")
        ownership = dict(plan.ownership)
        # Revalidate all retained entries before publishing, including unvisited ones.
        for destination, source in list(ownership.items()):
            try:
                _check_parents(Path(destination), plan.home)
                matches = _link_source(Path(destination)) == Path(source)
            except (ValueError, OSError):
                matches = False
            if not matches:
                ownership.pop(destination)
        _persist(plan, ownership)
        for op in plan.operations:
            destination = op.destination
            text = str(destination)
            if op.action in ("protected", "skip"):
                if op.action == "protected":
                    ownership.pop(text, None)
                if op.conflict:
                    warnings.append(f"Preserve {destination}: {op.conflict}")
                continue
            try:
                _check_parents(destination, plan.home)
            except (ValueError, OSError) as exc:
                ownership.pop(text, None)
                _persist(plan, ownership)
                warnings.append(f"Preserve {destination}: {exc}")
                continue
            current = _link_source(destination)
            if op.action == "remove":
                if current != op.previous_source:
                    ownership.pop(text, None)
                    _persist(plan, ownership)
                    warnings.append(f"Preserve changed stale link: {destination}")
                    continue
                with _parent_fd(destination, plan.home) as parent:
                    os.unlink(destination.name, dir_fd=parent)
                ownership.pop(text, None)
                _persist(plan, ownership)
                _cleanup(destination, plan.home, plan.exclusions)
                continue
            source = op.desired_source
            if source != plan.home / ".agents/skills" and (
                not source.exists() or not source.resolve().is_relative_to(plan.repo)
            ):
                warnings.append(f"Skip unavailable source: {source}")
                continue
            if current == source:
                ownership[text] = str(source)
                _persist(plan, ownership)
                continue
            allowed = (
                (op.action == "create" and _identity(destination) is None)
                or (op.action == "replace" and current == op.previous_source and op.owned)
                or (op.action == "backup" and _identity(destination) == op.identity)
            )
            if not allowed:
                ownership.pop(text, None)
                _persist(plan, ownership)
                warnings.append(f"Preserve object changed after planning: {destination}")
                continue
            with _parent_fd(destination, plan.home, create=True) as parent:
                if op.action == "backup":
                    if stat.S_ISDIR(
                        os.stat(destination.name, dir_fd=parent, follow_symlinks=False).st_mode
                    ):
                        raise ValueError(f"Directories cannot be forced: {destination}")
                    backup_name = f"{destination.name}.sync-backup-{uuid.uuid4().hex}"
                    # Link the exact object before unlinking, without following symlinks.
                    os.link(
                        destination.name,
                        backup_name,
                        src_dir_fd=parent,
                        dst_dir_fd=parent,
                        follow_symlinks=False,
                    )
                    backups.append(destination.with_name(backup_name))
                    os.unlink(destination.name, dir_fd=parent)
                    ownership.pop(text, None)
                    _persist(plan, ownership)
                if op.action == "replace":
                    temporary = f".{destination.name}.{uuid.uuid4().hex}.link"
                    try:
                        os.symlink(str(source), temporary, dir_fd=parent)
                        os.replace(
                            temporary, destination.name, src_dir_fd=parent, dst_dir_fd=parent
                        )
                    finally:
                        try:
                            os.unlink(temporary, dir_fd=parent)
                        except FileNotFoundError:
                            pass
                else:
                    os.symlink(str(source), destination.name, dir_fd=parent)
            ownership[text] = str(source)
            _persist(plan, ownership)
        return HomeSyncResult(ownership, tuple(warnings), tuple(backups))


def describe_home_plan(plan: HomeSyncPlan) -> str:
    """Render selections, exclusions, override precedence, and conflict decisions."""
    lines = [
        f"Home-only target: {plan.target}",
        f"Home: {plan.home}",
        f"Repository: {plan.repo}",
        f"State: {plan.state_path}",
        f"Ordered layers: {' '.join(plan.layers)}",
        "Exclusions (including descendants):",
    ]
    lines.extend(f"  {path}" for path in plan.exclusions)
    if plan.overrides:
        lines.append("Overrides:")
        lines.extend(f"  {destination}: {old} -> {new}" for destination, old, new in plan.overrides)
    lines.append("Operations (stale entries first):")
    for op in plan.operations:
        source = f" -> {op.desired_source}" if op.desired_source else ""
        reason = f" ({op.conflict or op.protection})" if op.conflict or op.protection else ""
        lines.append(f"  {op.action}: {op.destination}{source}{reason}")
    lines.extend(f"Warning: {warning}" for warning in plan.warnings)
    return "\n".join(lines)
