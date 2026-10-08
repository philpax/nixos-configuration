"""Read-only link planning and confirmed application for explicit filesystem roots.

The caller selects links and supplies exclusions. Application keeps the user-owned
manifest under a bounded lock. A permission-denied operation outside home can run
through sudo; the worker uses the same filesystem function and never saves state.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

NAME_RE = re.compile(r"[a-z][a-z0-9-]*\Z")
LOCK_TIMEOUT = 30.0
WORKER_TIMEOUT = 120.0
MAX_STATE_BYTES = 8 * 1024 * 1024
MAX_WORKER_BYTES = 1024 * 1024


@dataclass(frozen=True)
class SyncOperation:
    destination: Path
    desired_source: Path | None
    previous_source: Path | None
    action: str
    owned: bool = False
    protection: str | None = None
    conflict: str | None = None
    identity: tuple[int, int, int, int, int] | None = None


@dataclass(frozen=True)
class SyncPlan:
    target: str
    home: Path
    repo: Path
    state_path: Path
    layers: tuple[str, ...]
    exclusions: tuple[str, ...]
    operations: tuple[SyncOperation, ...]
    overrides: tuple[tuple[Path, Path, Path], ...]
    warnings: tuple[str, ...]
    ownership: dict[str, str] = field(repr=False)
    state_bytes: bytes | None = field(repr=False)
    force: bool = False
    roots: tuple[Path, ...] = ()

    @property
    def conflicts(self) -> tuple[SyncOperation, ...]:
        return tuple(op for op in self.operations if op.conflict)

    @property
    def symlinks(self) -> list[tuple[Path, Path]]:
        return [
            (op.destination, op.desired_source)
            for op in self.operations
            if op.desired_source is not None and op.action != "protected"
        ]


@dataclass(frozen=True)
class SyncResult:
    ownership: dict[str, str]
    warnings: tuple[str, ...]
    backups: tuple[Path, ...]
    complete: bool = True


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


def _stat_identity(info) -> tuple[int, int, int, int, int]:
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns)


def _identity(path: Path) -> tuple[int, int, int, int, int] | None:
    try:
        return _stat_identity(path.lstat())
    except FileNotFoundError:
        return None


def _scope(path: Path, home: Path, roots: tuple[Path, ...] = ()) -> Path:
    # Extra roots never relax the ownership rule for a path inside home.
    if path.is_relative_to(home):
        _absolute(path, home)
        return home
    matches = [root for root in roots if path.is_relative_to(root) and path != root]
    if not matches:
        raise ValueError(f"Destination is outside authorized roots: {path}")
    root = max(matches, key=lambda item: len(item.parts))
    _absolute(path, root)
    return root


def _namespace_overflow_uid(uid: int) -> int | None:
    """Recognize only a namespace that preserves the current non-root UID alone."""
    if uid == 0 or uid != os.getuid() or os.geteuid() != uid:
        return None

    def read(path: str, limit: int) -> str:
        try:
            with open(path, "rb") as source:
                raw = source.read(limit + 1)
            if len(raw) > limit:
                raise ValueError(f"metadata exceeds {limit} bytes")
            return raw.decode("ascii")
        except (OSError, UnicodeError, ValueError) as exc:
            raise ValueError(f"Cannot verify user namespace from {path}: {exc}") from exc

    mapping = read("/proc/self/uid_map", 64 * 1024)
    entries = []
    for line in mapping.splitlines():
        if not re.fullmatch(r"[ \t]*[0-9]{1,10}[ \t]+[0-9]{1,10}[ \t]+[0-9]{1,10}[ \t]*", line):
            raise ValueError("Cannot verify user namespace: malformed /proc/self/uid_map")
        inside, outside, count = map(int, line.split())
        if count == 0 or max(inside + count, outside + count) > 2**32 - 1:
            raise ValueError("Cannot verify user namespace: invalid /proc/self/uid_map range")
        entries.append((inside, outside, count))
    if not entries:
        raise ValueError("Cannot verify user namespace: empty /proc/self/uid_map")
    # This excludes initial namespaces, root mappings, remapped users and worker UIDs.
    if entries != [(uid, uid, 1)]:
        return None
    overflow = read("/proc/sys/kernel/overflowuid", 32).strip()
    if not re.fullmatch(r"[0-9]{1,10}", overflow) or not 0 < int(overflow) < 2**32 - 1:
        raise ValueError("Cannot verify user namespace: invalid /proc/sys/kernel/overflowuid")
    return int(overflow) if int(overflow) != uid else None


def _safe_directory(
    info, current: Path, boundary: Path, uid: int, *, user_only=False, user_home=None
):
    strict = user_only and (
        current.is_relative_to(boundary)
        or (user_home is not None and current.is_relative_to(user_home))
    )
    allowed = {uid} if strict else {0, uid}
    if stat.S_ISDIR(info.st_mode):
        if info.st_uid in allowed:
            return
        if (
            user_only
            and not strict
            and current in boundary.parents
            and not info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        ):
            try:
                overflow_uid = _namespace_overflow_uid(uid)
            except ValueError as exc:
                raise ValueError(f"Unsafe parent directory: {current}; {exc}") from exc
            # stat cannot distinguish unmapped root from other unmapped owners.
            # Only ancestors without group/other write access receive this exception.
            if overflow_uid is not None and info.st_uid == overflow_uid:
                return
    raise ValueError(f"Unsafe parent directory: {current}")


def _check_parents(path: Path, home: Path, *, roots=(), uid=None, user_home=None) -> None:
    """Validate lexical confinement and every existing parent, without following links."""
    uid = os.getuid() if uid is None else uid
    boundary = _scope(path, home, roots)
    current = Path("/")
    for part in path.parts[1:-1]:
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            return
        _safe_directory(
            info, current, boundary, uid, user_only=boundary == home, user_home=user_home
        )


def _canonical_roots(roots, home: Path, uid: int) -> tuple[Path, ...]:
    result = []
    for value in roots:
        root = Path(value)
        _absolute(root, Path("/"))
        if root.resolve() != root:
            raise ValueError(f"Root is not canonical: {root}")
        if root == home:
            continue
        # Validate the root itself as a parent of a possible managed object.
        _check_parents(root / ".sync-validation", home, roots=(root,), uid=uid)
        result.append(root)
    return tuple(sorted(set(result), key=str))


def _canonical_context(home: Path, repo: Path, roots, *, uid: int):
    home, repo = Path(home).resolve(strict=True), Path(repo).resolve(strict=True)
    if not home.is_dir() or not repo.is_dir() or home.stat().st_uid != uid:
        raise ValueError("Home and repository must be directories; home must be user-owned")
    _check_parents(home / ".sync-validation", home, uid=uid)
    return home, repo, _canonical_roots(roots, home, uid)


def _control_root(path: Path, home: Path, repo: Path | None) -> Path:
    for root in (home, repo):
        if root is not None and path.is_relative_to(root) and path != root:
            _absolute(path, root)
            return root
    raise ValueError(f"State/lock must be beneath home or repository: {path}")


def _control_file(path: Path, home: Path, *, repo: Path | None = None, uid=None) -> None:
    uid = os.getuid() if uid is None else uid
    root = _control_root(path, home, repo)
    # A repository manifest has the same user-owned parent rule as a home manifest.
    _check_parents(path, root, uid=uid, user_home=home)
    try:
        info = path.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_nlink != 1:
        raise ValueError(f"State/lock must be a user-owned regular file: {path}")


def _protected(path: Path, home: Path, exclusions: tuple[str, ...], directory=False) -> bool:
    if not path.is_relative_to(home):
        return False
    relative = path.relative_to(home)
    return any(
        relative == exc
        or relative.is_relative_to(exc)
        or (directory and exc.is_relative_to(relative))
        for exc in map(Path, exclusions)
    )


def _attached_parent(fd: int, path: Path) -> None:
    opened = os.fstat(fd)
    visible = path.parent.lstat()
    if not stat.S_ISDIR(visible.st_mode) or (opened.st_dev, opened.st_ino) != (
        visible.st_dev,
        visible.st_ino,
    ):
        raise ValueError(f"Parent directory changed during operation: {path.parent}")


@contextmanager
def _parent_fd(path: Path, home: Path, *, create=False, roots=(), uid=None, user_home=None):
    """Walk from / with O_NOFOLLOW and keep the final parent directory open."""
    uid = os.getuid() if uid is None else uid
    boundary = _scope(path, home, roots)
    _check_parents(path, home, roots=roots, uid=uid, user_home=user_home)
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    current = Path("/")
    try:
        for part in path.parts[1:-1]:
            current /= part
            if create and current.is_relative_to(boundary):
                try:
                    os.mkdir(part, mode=0o700 if boundary == home else 0o755, dir_fd=fd)
                except FileExistsError:
                    pass
            new_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = new_fd
            opened = os.fstat(fd)
            _safe_directory(
                opened, current, boundary, uid, user_only=boundary == home, user_home=user_home
            )
            # A renamed ancestor must not redirect a retained directory descriptor.
            visible = current.lstat()
            if (opened.st_dev, opened.st_ino) != (visible.st_dev, visible.st_ino):
                raise ValueError(f"Parent directory changed during traversal: {current}")
        _attached_parent(fd, path)
        yield fd
    finally:
        os.close(fd)


def read_state(path: Path, *, home: Path, repo: Path, roots=()) -> tuple[dict, bytes | None]:
    """Read scoped metadata or a validated legacy manifest. Invalid state is an error."""
    home, repo, roots = _canonical_context(home, repo, roots, uid=os.getuid())
    path = Path(path)
    _control_file(path, home, repo=repo)
    root = _control_root(path, home, repo)
    try:
        with _parent_fd(path, root, user_home=home) as parent:
            fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
            with os.fdopen(fd, "rb") as source:
                info = os.fstat(source.fileno())
                if (
                    not stat.S_ISREG(info.st_mode)
                    or info.st_uid != os.getuid()
                    or info.st_nlink != 1
                ):
                    raise ValueError(f"Unsafe sync state: {path}")
                raw = source.read(MAX_STATE_BYTES + 1)
    except FileNotFoundError:
        return {"symlinks": {}}, None
    if len(raw) > MAX_STATE_BYTES:
        raise ValueError(f"Sync state is too large: {path}")
    try:
        state = json.loads(raw)
    except (ValueError, UnicodeDecodeError) as exc:
        raise ValueError(f"Malformed sync state: {path}") from exc
    valid = isinstance(state, dict) and isinstance(state.get("symlinks"), dict)
    if valid:
        valid = all(isinstance(k, str) and isinstance(v, str) for k, v in state["symlinks"].items())
    version = state.get("schema_version") if isinstance(state, dict) else None
    if type(version) is int and version in (1, 2):
        valid = (
            valid
            and state.get("home") == str(home)
            and state.get("repo") == str(repo)
            and isinstance(state.get("target"), str)
            and NAME_RE.fullmatch(state["target"])
        )
        if version == 1:
            valid = valid and state.get("mode") == "home-only"
        else:
            valid = (
                valid
                and state.get("mode") == "sync"
                and state.get("roots") == [str(root) for root in roots]
            )
    elif version is None:
        valid = (
            valid
            and path == repo / ".sync-state.json"
            and set(state) == {"machine", "timestamp", "symlinks"}
            and isinstance(state.get("machine"), str)
            and NAME_RE.fullmatch(state["machine"])
            and isinstance(state.get("timestamp"), str)
        )
    else:
        valid = False
    if not valid:
        raise ValueError(f"Malformed or mismatched sync metadata: {path}")
    return state, raw


def _link_source(path: Path) -> Path | None:
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
    """Allow a directory-to-link transition only after every owned stale leaf is removed."""
    if path.is_symlink() or not path.is_dir() or not any(p.is_relative_to(path) for p in removals):
        return False
    for root, dirs, files in os.walk(path, followlinks=False):
        for name in [*dirs, *files]:
            entry = Path(root) / name
            if entry.is_symlink() or not entry.is_dir():
                if entry not in removals:
                    return False
    return True


def _object_owner(path: Path, home: Path, uid: int) -> bool:
    try:
        owner = path.lstat().st_uid
    except FileNotFoundError:
        return True
    return owner in ({uid} if path.is_relative_to(home) else {0, uid})


def _control_paths(state_path: Path) -> tuple[Path, ...]:
    return tuple(
        state_path.with_name(state_path.name + suffix)
        for suffix in ("", ".lock", ".worker-lock", ".worker-request")
    )


def _reserved(path: Path, state_path: Path) -> bool:
    return any(
        path.is_relative_to(control) or control.is_relative_to(path)
        for control in _control_paths(state_path)
    )


def plan_links(
    *,
    target: str,
    home: Path,
    repo: Path,
    selected: dict[Path, Path],
    state_path: Path | None = None,
    layers=(),
    exclusions=(),
    overrides=(),
    force=False,
    roots=(),
) -> SyncPlan:
    """Record link decisions without writes, locks, prompts, or subprocesses."""
    if not isinstance(target, str) or not NAME_RE.fullmatch(target):
        raise ValueError(f"Unsafe sync target: {target!r}")
    uid = os.getuid()
    home, repo, roots = _canonical_context(home, repo, roots, uid=uid)
    state_path = (
        Path(state_path) if state_path else home / ".local/state/nixos-configuration/sync-home.json"
    )
    controls = _control_paths(state_path)
    for path in controls:
        _control_file(path, home, repo=repo)
    exclusions = tuple(dict.fromkeys(str(_relative(value)) for value in exclusions))
    if any(_protected(path, home, exclusions, directory=True) for path in controls):
        raise ValueError("State and lock paths cannot occupy protected destinations")
    exclusions = tuple(
        dict.fromkeys(
            [
                *exclusions,
                *(str(path.relative_to(home)) for path in controls if path.is_relative_to(home)),
            ]
        )
    )
    checked = {}
    for destination, source in selected.items():
        destination = Path(destination)
        _scope(destination, home, roots)
        source = _valid_old_source(destination, str(source), home, repo)
        checked[destination] = source
    selected = checked
    state, raw = read_state(state_path, home=home, repo=repo, roots=roots)
    warnings: list[str] = []
    ownership: dict[str, str] = {}
    previous: dict[Path, Path] = {}
    stale: list[SyncOperation] = []
    recorded_roots = () if state.get("mode") == "home-only" else roots
    for text, source in state["symlinks"].items():
        try:
            destination = Path(text)
            _scope(destination, home, recorded_roots)
            _check_parents(destination, home, roots=recorded_roots)
            recorded = _valid_old_source(destination, source, home, repo)
            if not _object_owner(destination, home, uid):
                raise ValueError(f"Foreign managed object: {destination}")
        except (ValueError, OSError) as exc:
            warnings.append(f"Skip invalid recorded entry {text}: {exc}")
            continue
        if _protected(destination, home, exclusions, directory=True) or _reserved(
            destination, state_path
        ):
            if destination not in selected:
                stale.append(
                    SyncOperation(destination, None, recorded, "protected", protection="exclusion")
                )
            continue
        previous[destination] = recorded
        if _link_source(destination) == recorded:
            ownership[text] = source
        elif _identity(destination) is not None:
            warnings.append(f"Preserve modified object and drop ownership: {destination}")
        if destination not in selected:
            stale.append(
                SyncOperation(
                    destination,
                    None,
                    recorded,
                    "remove" if text in ownership else "skip",
                    text in ownership,
                    conflict=None if text in ownership else "stale object changed or missing",
                    identity=_identity(destination),
                )
            )
    removals = {op.destination for op in stale if op.action == "remove"}
    operations = sorted(stale, key=lambda op: (-len(op.destination.parts), str(op.destination)))
    for destination, source in sorted(selected.items()):
        if _protected(destination, home, exclusions, directory=True) or _reserved(
            destination, state_path
        ):
            operations.append(
                SyncOperation(
                    destination,
                    source,
                    previous.get(destination),
                    "protected",
                    protection="exclusion",
                )
            )
            continue
        try:
            _check_parents(destination, home, roots=roots)
            if not _object_owner(destination, home, uid):
                raise ValueError(f"Foreign managed object: {destination}")
        except (ValueError, OSError) as exc:
            operations.append(
                SyncOperation(
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
        elif _migration_directory(destination, removals):
            action = "create"
        else:
            conflict = (
                "existing directory" if stat.S_ISDIR(identity[2]) else "unowned or modified object"
            )
            action = "backup" if force and not stat.S_ISDIR(identity[2]) else "skip"
        operations.append(
            SyncOperation(
                destination, source, old, action, owned, conflict=conflict, identity=identity
            )
        )
    return SyncPlan(
        target,
        home,
        repo,
        state_path,
        tuple(layers),
        exclusions,
        tuple(operations),
        tuple(overrides),
        tuple(warnings),
        ownership,
        raw,
        force,
        roots,
    )


def _validate_control_fd(fd: int, path: Path, uid: int) -> None:
    info = os.fstat(fd)
    visible = path.lstat()
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != uid
        or info.st_nlink != 1
        or not stat.S_ISREG(visible.st_mode)
        or visible.st_uid != uid
        or visible.st_nlink != 1
        or (info.st_dev, info.st_ino) != (visible.st_dev, visible.st_ino)
    ):
        raise ValueError(f"Unsafe sync control file: {path}")


def _flock(fd: int, path: Path, uid: int) -> None:
    deadline = time.monotonic() + LOCK_TIMEOUT
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            _validate_control_fd(fd, path, uid)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise TimeoutError(f"Timed out waiting for sync lock: {path}") from None
            time.sleep(0.05)


@contextmanager
def _control_lock(path: Path, home: Path, repo: Path, *, uid: int, create=False):
    _control_file(path, home, repo=repo, uid=uid)
    root = _control_root(path, home, repo)
    with _parent_fd(path, root, create=create, uid=uid, user_home=home) as parent:
        flags = os.O_RDONLY | os.O_NOFOLLOW
        if create:
            flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
        fd = os.open(path.name, flags, 0o600, dir_fd=parent)
        try:
            _validate_control_fd(fd, path, uid)
            _flock(fd, path, uid)
            yield fd
        finally:
            os.close(fd)


@contextmanager
def _mutation_lock(plan: SyncPlan):
    with _control_lock(
        _control_paths(plan.state_path)[1], plan.home, plan.repo, uid=os.getuid(), create=True
    ):
        yield


@contextmanager
def _worker_lease(plan: SyncPlan):
    with _control_lock(
        _control_paths(plan.state_path)[2], plan.home, plan.repo, uid=os.getuid(), create=True
    ) as fd:
        yield fd


def _request_record(plan: SyncPlan, record: dict | None) -> None:
    """Only the user process publishes or revokes worker authorization."""
    path = _control_paths(plan.state_path)[3]
    _control_file(path, plan.home, repo=plan.repo)
    root = _control_root(path, plan.home, plan.repo)
    with _parent_fd(path, root, create=record is not None, user_home=plan.home) as parent:
        if record is None:
            try:
                os.unlink(path.name, dir_fd=parent)
                os.fsync(parent)
            except FileNotFoundError:
                pass
            return
        temp = f".{path.name}.{uuid.uuid4().hex}.tmp"
        fd = os.open(
            temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600, dir_fd=parent
        )
        try:
            with os.fdopen(fd, "w") as output:
                json.dump(record, output, sort_keys=True)
                output.flush()
                os.fsync(output.fileno())
            _control_file(path, plan.home, repo=plan.repo)
            _attached_parent(parent, path)
            os.replace(temp, path.name, src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
        finally:
            try:
                os.unlink(temp, dir_fd=parent)
            except FileNotFoundError:
                pass


def _control_bytes(path: Path, home: Path, repo: Path, uid: int) -> bytes:
    _control_file(path, home, repo=repo, uid=uid)
    root = _control_root(path, home, repo)
    with _parent_fd(path, root, uid=uid, user_home=home) as parent:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
        with os.fdopen(fd, "rb") as source:
            _validate_control_fd(source.fileno(), path, uid)
            raw = source.read(MAX_STATE_BYTES + 1)
    if len(raw) > MAX_STATE_BYTES:
        raise ValueError(f"Sync control file is too large: {path}")
    return raw


def _request_digest(request: dict) -> str:
    return hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()


def _persist(plan: SyncPlan, ownership: dict[str, str]) -> None:
    _control_file(plan.state_path, plan.home, repo=plan.repo)
    state = {
        "schema_version": 2,
        "mode": "sync",
        "home": str(plan.home),
        "repo": str(plan.repo),
        "roots": [str(root) for root in plan.roots],
        "target": plan.target,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "symlinks": ownership,
    }
    root = _control_root(plan.state_path, plan.home, plan.repo)
    with _parent_fd(plan.state_path, root, create=True, user_home=plan.home) as parent:
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
            _control_file(plan.state_path, plan.home, repo=plan.repo)
            _attached_parent(parent, plan.state_path)
            os.replace(temp, plan.state_path.name, src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
        finally:
            try:
                os.unlink(temp, dir_fd=parent)
            except FileNotFoundError:
                pass


def _cleanup(
    path: Path, home: Path, exclusions: tuple[str, ...], *, roots=(), uid=None, controls=()
) -> None:
    uid = os.getuid() if uid is None else uid
    boundary = _scope(path, home, roots)
    current = path.parent
    while current != boundary:
        if _protected(current, home, exclusions, directory=True) or any(
            control.is_relative_to(current) for control in controls
        ):
            break
        try:
            with _parent_fd(current, home, roots=roots, uid=uid) as parent:
                info = os.stat(current.name, dir_fd=parent, follow_symlinks=False)
                _safe_directory(info, current, boundary, uid, user_only=boundary == home)
                os.rmdir(current.name, dir_fd=parent)
        except (OSError, ValueError):
            break
        current = current.parent


@dataclass
class _Progress:
    owned: bool | None = None
    changed: bool = False
    warnings: list[str] = field(default_factory=list)
    backups: list[Path] = field(default_factory=list)


def _at(parent: int, name: str):
    try:
        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        return None, None
    source = None
    if stat.S_ISLNK(info.st_mode):
        source = os.readlink(name, dir_fd=parent)
    return info, source


class _SourceAccessError(RuntimeError):
    """Source access failures cannot authorize destination privilege escalation."""


@contextmanager
def _source_access(source: Path):
    try:
        yield
    except PermissionError as exc:
        raise _SourceAccessError(f"Cannot access sync source: {source}: {exc}") from exc


def _mutate_operation(
    op: SyncOperation, *, home, repo, roots, exclusions, uid, progress, publish, controls=()
):
    """Apply one reviewed operation. Both the parent and sudo worker call this function."""
    if op.action not in ("create", "replace", "backup", "remove", "keep"):
        raise ValueError(f"Invalid sync operation: {op.action}")
    destination = op.destination
    _scope(destination, home, roots)
    _check_parents(destination, home, roots=roots, uid=uid)
    if _protected(destination, home, exclusions, directory=True) or any(
        destination.is_relative_to(control) or control.is_relative_to(destination)
        for control in controls
    ):
        raise ValueError(f"Protected destination: {destination}")
    if op.desired_source is not None:
        with _source_access(op.desired_source):
            source = _valid_old_source(destination, str(op.desired_source), home, repo)
            available = source == home / ".agents/skills" or source.exists()
        if not available:
            progress.owned = (
                None if (op.owned and _link_source(destination) == op.previous_source) else False
            )
            progress.warnings.append(f"Skip unavailable source: {source}")
            return
    else:
        source = None
    if op.previous_source is not None:
        with _source_access(op.previous_source):
            _valid_old_source(destination, str(op.previous_source), home, repo)
    try:
        with _parent_fd(
            destination, home, create=op.action != "remove", roots=roots, uid=uid
        ) as parent:
            info, link = _at(parent, destination.name)
            current = (
                Path(
                    os.path.normpath(
                        link if os.path.isabs(link) else str(destination.parent / link)
                    )
                )
                if link is not None
                else None
            )
            if info is not None and info.st_uid not in (
                {uid} if destination.is_relative_to(home) else {0, uid}
            ):
                raise ValueError(f"Foreign managed object: {destination}")
            if source is not None and current == source:
                progress.owned = True
                publish()
                return
            identity = _stat_identity(info) if info is not None else None
            if op.action == "remove":
                allowed = op.owned and current == op.previous_source and identity == op.identity
            else:
                allowed = (
                    (op.action == "create" and identity is None)
                    or (
                        op.action == "replace"
                        and op.owned
                        and current == op.previous_source
                        and identity == op.identity
                    )
                    or (
                        op.action == "backup"
                        and identity == op.identity
                        and identity is not None
                        and not stat.S_ISDIR(identity[2])
                    )
                )
                if allowed and op.action == "replace":
                    with _source_access(op.previous_source):
                        allowed = op.previous_source.exists()
            if not allowed:
                progress.owned = False
                progress.warnings.append(f"Preserve object changed after planning: {destination}")
                publish()
                return
            _check_parents(destination, home, roots=roots, uid=uid)
            _attached_parent(parent, destination)
            latest, latest_link = _at(parent, destination.name)
            latest_identity = _stat_identity(latest) if latest is not None else None
            if latest_identity != identity or latest_link != link:
                progress.owned = False
                progress.warnings.append(f"Preserve object changed during operation: {destination}")
                publish()
                return
            if op.action == "remove":
                os.unlink(destination.name, dir_fd=parent)
                progress.changed = True
                progress.owned = False
                publish()
            elif op.action == "backup":
                backup_name = f"{destination.name}.sync-backup-{uuid.uuid4().hex}"
                os.link(
                    destination.name,
                    backup_name,
                    src_dir_fd=parent,
                    dst_dir_fd=parent,
                    follow_symlinks=False,
                )
                progress.backups.append(destination.with_name(backup_name))
                os.unlink(destination.name, dir_fd=parent)
                progress.changed = True
                progress.owned = False
                publish()
                os.symlink(str(source), destination.name, dir_fd=parent)
                progress.owned = True
                publish()
            elif op.action == "replace":
                temporary = f".{destination.name}.{uuid.uuid4().hex}.link"
                try:
                    os.symlink(str(source), temporary, dir_fd=parent)
                    _check_parents(destination, home, roots=roots, uid=uid)
                    _attached_parent(parent, destination)
                    latest, latest_link = _at(parent, destination.name)
                    if latest is None or _stat_identity(latest) != identity or latest_link != link:
                        progress.owned = False
                        progress.warnings.append(
                            f"Preserve object changed during replacement: {destination}"
                        )
                        publish()
                        return
                    os.replace(temporary, destination.name, src_dir_fd=parent, dst_dir_fd=parent)
                    progress.changed = True
                    progress.owned = True
                    publish()
                finally:
                    try:
                        os.unlink(temporary, dir_fd=parent)
                    except FileNotFoundError:
                        pass
            else:
                os.symlink(str(source), destination.name, dir_fd=parent)
                progress.changed = True
                progress.owned = True
                publish()
    except FileNotFoundError:
        if op.action != "remove":
            raise
        progress.owned = False
        progress.warnings.append(f"Preserve changed stale link: {destination}")
        publish()
    if op.action == "remove" and progress.changed:
        _cleanup(destination, home, exclusions, roots=roots, uid=uid, controls=controls)


def _worker_request(plan: SyncPlan, op: SyncOperation) -> dict:
    return {
        "version": 1,
        "epoch": uuid.uuid4().hex,
        "uid": os.getuid(),
        "home": str(plan.home),
        "repo": str(plan.repo),
        "roots": [str(root) for root in plan.roots],
        "exclusions": list(plan.exclusions),
        "controls": [str(path) for path in _control_paths(plan.state_path)],
        "operation": {
            "destination": str(op.destination),
            "desired_source": str(op.desired_source) if op.desired_source is not None else None,
            "previous_source": str(op.previous_source) if op.previous_source is not None else None,
            "action": op.action,
            "owned": op.owned,
            "identity": list(op.identity) if op.identity is not None else None,
        },
    }


def _decode_request(request: dict, requester_uid: int):
    if (
        not isinstance(request, dict)
        or set(request)
        != {
            "version",
            "epoch",
            "uid",
            "home",
            "repo",
            "roots",
            "exclusions",
            "controls",
            "operation",
        }
        or type(request["version"]) is not int
        or request["version"] != 1
        or not isinstance(request["epoch"], str)
        or not re.fullmatch(r"[0-9a-f]{32}", request["epoch"])
        or type(request["uid"]) is not int
        or request["uid"] != requester_uid
        or not isinstance(request["home"], str)
        or not isinstance(request["repo"], str)
        or not isinstance(request["roots"], list)
        or not all(isinstance(root, str) for root in request["roots"])
        or not isinstance(request["exclusions"], list)
    ):
        raise ValueError("Invalid sync worker request")
    home, repo, roots = _canonical_context(
        Path(request["home"]), Path(request["repo"]), request["roots"], uid=requester_uid
    )
    if str(home) != request["home"] or str(repo) != request["repo"]:
        raise ValueError("Worker roots must be canonical")
    exclusions = tuple(str(_relative(value)) for value in request["exclusions"])
    values = request["controls"]
    if (
        not isinstance(values, list)
        or len(values) != 4
        or not all(isinstance(value, str) for value in values)
    ):
        raise ValueError("Invalid worker control paths")
    controls = tuple(Path(value) for value in values)
    if controls != _control_paths(controls[0]):
        raise ValueError("Worker control paths do not describe state, locks and request")
    for path in controls:
        _control_file(path, home, repo=repo, uid=requester_uid)
    item = request["operation"]
    if (
        not isinstance(item, dict)
        or set(item)
        != {"destination", "desired_source", "previous_source", "action", "owned", "identity"}
        or not isinstance(item["destination"], str)
        or any(
            value is not None and not isinstance(value, str)
            for value in (item["desired_source"], item["previous_source"])
        )
        or item["action"] not in ("create", "replace", "backup", "remove", "keep")
        or type(item["owned"]) is not bool
        or (
            item["identity"] is not None
            and (
                not isinstance(item["identity"], list)
                or len(item["identity"]) != 5
                or not all(type(n) is int for n in item["identity"])
            )
        )
    ):
        raise ValueError("Invalid sync worker operation")
    destination = Path(item["destination"])
    _scope(destination, home, roots)
    if destination.is_relative_to(home):
        raise ValueError("The sync worker cannot modify home destinations")
    source = Path(item["desired_source"]) if item["desired_source"] is not None else None
    previous = Path(item["previous_source"]) if item["previous_source"] is not None else None
    if (
        (
            item["action"] == "remove"
            and (source is not None or previous is None or not item["owned"])
        )
        or (item["action"] != "remove" and source is None)
        or (item["action"] == "replace" and (previous is None or not item["owned"]))
    ):
        raise ValueError("Incomplete sync worker operation")
    op = SyncOperation(
        destination,
        source,
        previous,
        item["action"],
        item["owned"],
        identity=tuple(item["identity"]) if item["identity"] is not None else None,
    )
    return op, home, repo, roots, exclusions, controls


def _authorize_worker(request: dict, home: Path, repo: Path, controls, uid: int) -> None:
    try:
        record = json.loads(_control_bytes(controls[3], home, repo, uid))
        state_hash = hashlib.sha256(_control_bytes(controls[0], home, repo, uid)).hexdigest()
    except FileNotFoundError as exc:
        raise ValueError("Stale sync worker request: authorization is absent") from exc
    if (
        not isinstance(record, dict)
        or set(record) != {"version", "epoch", "request_hash", "state_hash", "deadline"}
        or type(record["version"]) is not int
        or record["version"] != 1
        or record["epoch"] != request["epoch"]
        or record["request_hash"] != _request_digest(request)
        or record["state_hash"] != state_hash
        or type(record["deadline"]) not in (int, float)
        or not time.time() < record["deadline"]
    ):
        raise ValueError("Stale sync worker request: authorization changed or expired")


def _process_worker(request: dict, *, requester_uid: int) -> dict:
    progress = _Progress()
    error = None
    try:
        op, home, repo, roots, exclusions, controls = _decode_request(request, requester_uid)
        # The actual mutating process retains this lock, independently of sudo's lifetime.
        with _control_lock(controls[2], home, repo, uid=requester_uid):
            _authorize_worker(request, home, repo, controls, requester_uid)
            _mutate_operation(
                op,
                home=home,
                repo=repo,
                roots=roots,
                exclusions=exclusions,
                uid=requester_uid,
                progress=progress,
                publish=lambda: None,
                controls=controls,
            )
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"
    return {
        "version": 1,
        "ok": error is None,
        "error": error,
        "owned": progress.owned,
        "changed": progress.changed,
        "warnings": progress.warnings,
        "backups": [str(path) for path in progress.backups],
    }


class SyncWorkerError(RuntimeError):
    """The elevated operation failed or its result could not be verified."""


class _PersistenceError(RuntimeError):
    """State publication failed; destination permissions do not justify escalation."""


class _WorkerLeaseBusy(SyncWorkerError):
    """A surviving worker still excludes local mutation and state publication."""


def _publish_request(plan: SyncPlan, request: dict) -> str:
    text = json.dumps(request)
    if len(text.encode()) > MAX_WORKER_BYTES:
        raise ValueError("Sync worker request is too large")
    raw = _control_bytes(plan.state_path, plan.home, plan.repo, os.getuid())
    _request_record(
        plan,
        {
            "version": 1,
            "epoch": request["epoch"],
            "request_hash": _request_digest(request),
            "state_hash": hashlib.sha256(raw).hexdigest(),
            "deadline": time.time() + WORKER_TIMEOUT,
        },
    )
    return text


def _run_worker(plan: SyncPlan, op: SyncOperation, progress: _Progress, lease_fd: int) -> None:
    request = _publish_request(plan, _worker_request(plan, op))
    try:
        fcntl.flock(lease_fd, fcntl.LOCK_UN)
        try:
            completed = subprocess.run(
                ["sudo", "--", sys.executable, "-I", str(Path(__file__).resolve()), "--worker"],
                input=request,
                text=True,
                capture_output=True,
                timeout=WORKER_TIMEOUT,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise SyncWorkerError(
                f"Sync worker failed; destination may be partially changed: {op.destination}: {exc}"
            ) from exc
    finally:
        # Revocation does not wait for the lease. An already-authorized worker can
        # finish, but this process must reacquire exclusion before saving any state.
        try:
            _request_record(plan, None)
        finally:
            try:
                _flock(lease_fd, _control_paths(plan.state_path)[2], os.getuid())
            except Exception as exc:
                raise _WorkerLeaseBusy(
                    "Sync worker exclusion is unavailable; state recovery requires a later apply"
                ) from exc
    try:
        response = json.loads(completed.stdout)
        if (
            not isinstance(response, dict)
            or set(response)
            != {"version", "ok", "error", "owned", "changed", "warnings", "backups"}
            or type(response["version"]) is not int
            or response["version"] != 1
            or type(response["ok"]) is not bool
            or type(response["changed"]) is not bool
            or (response["owned"] is not None and type(response["owned"]) is not bool)
            or (response["error"] is not None and not isinstance(response["error"], str))
            or not isinstance(response["warnings"], list)
            or not all(isinstance(value, str) for value in response["warnings"])
            or not isinstance(response["backups"], list)
        ):
            raise ValueError("Invalid worker response")
        backups = []
        for value in response["backups"]:
            if not isinstance(value, str):
                raise ValueError("Invalid worker backup")
            path = _absolute(value, op.destination.parent)
            if path.parent != op.destination.parent or not path.name.startswith(
                op.destination.name + ".sync-backup-"
            ):
                raise ValueError("Worker backup escapes destination directory")
            backups.append(path)
        progress.owned = response["owned"]
        progress.changed = response["changed"]
        progress.warnings.extend(response["warnings"])
        progress.backups.extend(backups)
        if response["ok"] and (
            response["error"] is not None or (progress.owned is None and not progress.warnings)
        ):
            raise ValueError("Incomplete worker response")
    except (ValueError, TypeError) as exc:
        raise SyncWorkerError(
            f"Invalid sync worker result; destination may be partially changed: {op.destination}"
        ) from exc
    if completed.returncode != 0 or not response["ok"]:
        detail = response["error"] or completed.stderr.strip() or f"exit {completed.returncode}"
        raise SyncWorkerError(f"Sync worker failed for {op.destination}: {detail}")
    if progress.owned is True:
        try:
            _check_parents(op.destination, plan.home, roots=plan.roots)
            verified = (
                _object_owner(op.destination, plan.home, os.getuid())
                and _link_source(op.destination) == op.desired_source
            )
        except (ValueError, OSError):
            verified = False
        if not verified:
            progress.owned = False
            raise SyncWorkerError(f"Cannot verify completed sync worker link: {op.destination}")


def _retained(plan: SyncPlan, ownership: dict[str, str]) -> None:
    for text, source in list(ownership.items()):
        try:
            destination = Path(text)
            _check_parents(destination, plan.home, roots=plan.roots)
            _valid_old_source(destination, source, plan.home, plan.repo)
            matches = _object_owner(destination, plan.home, os.getuid()) and _link_source(
                destination
            ) == Path(source)
        except (ValueError, OSError):
            matches = False
        if not matches:
            ownership.pop(text)


def apply_sync(plan: SyncPlan, *, confirmed=False) -> SyncResult:
    """Apply the reviewed plan. Failures propagate after recording known progress."""
    if not confirmed:
        raise ValueError("Sync requires explicit confirmation")
    home, repo, roots = _canonical_context(plan.home, plan.repo, plan.roots, uid=os.getuid())
    if (home, repo, roots) != (plan.home, plan.repo, plan.roots):
        raise ValueError("Sync plan roots changed after planning")
    warnings = list(plan.warnings)
    backups: list[Path] = []
    with _mutation_lock(plan), _worker_lease(plan) as lease_fd:
        # A caller arriving after interruption revokes any request not yet started.
        _request_record(plan, None)
        _, raw = read_state(plan.state_path, home=home, repo=repo, roots=roots)
        if raw != plan.state_bytes:
            raise ValueError("Sync state changed after planning; review a new plan")
        ownership = dict(plan.ownership)
        _retained(plan, ownership)
        _persist(plan, ownership)
        for op in plan.operations:
            text = str(op.destination)
            if op.action in ("protected", "skip"):
                if op.action == "protected":
                    ownership.pop(text, None)
                if op.conflict:
                    warnings.append(f"Preserve {op.destination}: {op.conflict}")
                continue
            progress = _Progress()

            def publish():
                if progress.owned is True and op.desired_source is not None:
                    ownership[text] = str(op.desired_source)
                elif progress.owned is False:
                    ownership.pop(text, None)
                _retained(plan, ownership)
                try:
                    _persist(plan, ownership)
                except Exception as exc:
                    raise _PersistenceError(f"Cannot save sync progress: {exc}") from exc

            try:
                try:
                    _mutate_operation(
                        op,
                        home=home,
                        repo=repo,
                        roots=roots,
                        exclusions=plan.exclusions,
                        uid=os.getuid(),
                        progress=progress,
                        publish=publish,
                        controls=_control_paths(plan.state_path),
                    )
                except PermissionError:
                    if op.destination.is_relative_to(home) or progress.changed or progress.backups:
                        raise
                    # Recheck safety before asking sudo, including the original object identity.
                    _check_parents(op.destination, home, roots=roots)
                    if not _object_owner(op.destination, home, os.getuid()):
                        raise ValueError(f"Foreign managed object: {op.destination}") from None
                    _run_worker(plan, op, progress, lease_fd)
                    publish()
            except _WorkerLeaseBusy:
                # The worker can still mutate. Neither recovery nor publication is safe.
                raise
            except ValueError as exc:
                ownership.pop(text, None)
                _persist(plan, ownership)
                warnings.append(f"Preserve {op.destination}: {exc}")
            except Exception as exc:
                # A failed worker cannot establish ownership, even if it reports a link.
                if isinstance(exc, SyncWorkerError) and progress.owned is not False:
                    progress.owned = None
                _retained(plan, ownership)
                if progress.owned is not None:
                    publish()
                else:
                    _persist(plan, ownership)
                raise
            warnings.extend(progress.warnings)
            backups.extend(progress.backups)
        _retained(plan, ownership)
        _persist(plan, ownership)
    complete = all(
        op.action == "protected"
        or op.desired_source is None
        or ownership.get(str(op.destination)) == str(op.desired_source)
        for op in plan.operations
    )
    return SyncResult(ownership, tuple(warnings), tuple(backups), complete=complete)


def _worker_main() -> int:
    try:
        text = sys.stdin.read(MAX_WORKER_BYTES + 1)
        sudo_uid = os.environ.get("SUDO_UID", "")
        if os.geteuid() != 0 or not sudo_uid.isdecimal() or len(text.encode()) > MAX_WORKER_BYTES:
            raise ValueError("The worker requires sudo and a bounded request")
        response = _process_worker(json.loads(text), requester_uid=int(sudo_uid))
    except Exception as exc:
        response = {
            "version": 1,
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
            "owned": None,
            "changed": False,
            "warnings": [],
            "backups": [],
        }
    print(json.dumps(response))
    return 0 if response["ok"] else 1


if __name__ == "__main__":
    if sys.argv[1:] != ["--worker"]:
        raise SystemExit("sync_engine.py is only executable as the sudo sync worker")
    raise SystemExit(_worker_main())
