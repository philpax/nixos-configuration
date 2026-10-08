"""Owned, home-confined paths shared by Frame operations."""

import contextlib
import fcntl
import json
import os
import stat
import tempfile
from pathlib import Path


class FrameError(RuntimeError):
    """An unsafe or unavailable Frame operation."""


def owned(path):
    info = path.lstat()
    if info.st_uid != os.getuid():
        raise FrameError(f"Path is not owned by the current user: {path}")
    return info


class Paths:
    def __init__(self, home, state_dir=None):
        try:
            self.home = Path(home).expanduser().resolve(strict=True)
        except (OSError, RuntimeError) as exc:
            raise FrameError(f"Cannot resolve selected home: {home}: {exc}") from exc
        if not self.home.is_dir():
            raise FrameError("Selected home is not a directory")
        owned(self.home)
        self.state = Path(state_dir or self.home / ".local/share/frame-cli").absolute()
        self.check(self.state)
        self.store = self.state / "store"
        self.profile = self.state / "profile"
        self.helper = self.state / "bin/nix-user-chroot"
        self.bootstrap_home = self.state / "bootstrap-home"
        self.tmp = self.state / "tmp"
        self.metadata = self.state / "bootstrap.json"
        self.wrapper = self.home / ".local/bin/frame-cli"

    def check(self, path, *, final_symlink=False):
        """Resolve parent components only; final profile links need separate validation."""
        path = Path(path).absolute()
        if ".." in path.parts or not path.is_relative_to(self.home) or path == self.home:
            raise FrameError(f"Path must be beneath the selected home: {path}")
        relative = path.relative_to(self.home)
        current = self.home
        for index, part in enumerate(relative.parts):
            current /= part
            if not current.exists() and not current.is_symlink():
                continue
            info = owned(current)
            last = index == len(relative.parts) - 1
            if stat.S_ISLNK(info.st_mode):
                if last and final_symlink:
                    continue
                raise FrameError(f"Control path or parent must not be a symlink: {current}")
            elif not last and not stat.S_ISDIR(info.st_mode):
                raise FrameError(f"Parent is not a directory: {current}")
        return path

    def mkdir(self, path):
        path = self.check(path)
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.check(path)
        return path

    def atomic_bytes(self, path, data, mode=0o600):
        path = self.check(path)
        self.mkdir(path.parent)
        fd, temporary = tempfile.mkstemp(prefix=".frame-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(data)
                output.flush()
                os.fsync(output.fileno())
            os.chmod(temporary, mode)
            self.check(path)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def write_json(self, path, value):
        self.atomic_bytes(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())

    def read_json(self, path):
        self.check(path)
        try:
            value = json.loads(Path(path).read_text())
        except (OSError, ValueError) as exc:
            raise FrameError(f"Invalid metadata: {path}: {exc}") from exc
        if not isinstance(value, dict):
            raise FrameError(f"Metadata must be an object: {path}")
        return value

    @contextlib.contextmanager
    def lock(self):
        self.mkdir(self.state)
        path = self.check(self.state / "mutation.lock")
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            if os.fstat(fd).st_uid != os.getuid():
                raise FrameError(f"Lock is not owned: {path}")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise FrameError("Another Frame mutation holds the lock") from exc
            yield
        finally:
            os.close(fd)
