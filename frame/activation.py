"""Consent-gated home integration. Callers hold the Frame mutation lock for writes."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable
from xml.sax.saxutils import escape

from .paths import FrameError

BEGIN = b"# >>> frame-cli managed startup >>>"
END = b"# <<< frame-cli managed startup <<<"


class ActivationError(FrameError):
    pass


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _absolute(path: Path) -> Path:
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise ActivationError(f"expected absolute path without traversal: {path}")
    return path


def _beneath(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


@dataclass
class Operation:
    path: Path
    kind: str
    content: bytes | str
    source: str
    previous: dict | None = None
    conflict: str | None = None
    mode: int = 0o644
    original: bytes | None = None
    existed: bool = False


@dataclass
class Plan:
    profile: str
    operations: list[Operation]
    font_dir: Path
    sync_plan: object = None
    readiness: bool = False
    warnings: list[str] = field(default_factory=list)

    @property
    def conflicts(self) -> list[Operation]:
        return [op for op in self.operations if op.conflict]

    def describe(self) -> str:
        from types import SimpleNamespace

        from sync_workflow import Section, describe_sync_plan

        selected = getattr(self.sync_plan, "plan", self.sync_plan)
        context = (
            selected
            if hasattr(selected, "home")
            else SimpleNamespace(
                home=self.font_dir.parent,
                repo=self.font_dir.parent,
                target="frame",
                layers=(),
                operations=(),
                exclusions=(),
            )
        )
        sections = [
            Section(
                "CLI profile",
                (
                    self.profile,
                    f"Wrapper readiness: {'ready' if self.readiness else 'unavailable'}",
                ),
            )
        ]
        for kind, title in (
            ("file", "Generated configuration"),
            ("link", "Host assets"),
            ("startup", "Shell startup"),
        ):
            items = tuple(
                str(op.path) + (f" [skipped: {op.conflict}]" if op.conflict else "")
                for op in self.operations
                if op.kind == kind
            )
            sections.append(Section(title, items))
        footer = list(self.warnings)
        if not hasattr(selected, "home") and self.sync_plan is not None:
            describe = getattr(self.sync_plan, "describe", None)
            footer.append(describe() if describe else str(self.sync_plan))
        return describe_sync_plan(context, extra_sections=sections, footer=footer)


@dataclass
class Prepared:
    profile: str
    generation: str
    previous_profile: str | None
    previous_generation: str | None


class Activation:
    def __init__(
        self,
        frame,
        *,
        env: dict[str, str] | None = None,
        source_resolver: Callable[[Path], Path] | None = None,
    ):
        self.frame = frame
        self.home = _absolute(Path(frame.home)).resolve()
        self.state = _absolute(Path(frame.state))
        self.repo = _absolute(Path(frame.repo)).resolve()
        self.wrapper = self.home / ".local/bin/frame-cli"
        self.env = dict(frame.environ if env is None else env)
        self.assets = self.state / "host-assets"
        self.manifest_path = self.state / "activation.json"
        self.journal_path = self.state / "activation-switch.json"
        self.source_resolver = source_resolver or getattr(frame, "resolve_store_path", None)
        self._safe(self.state)

    def _confined(self, path: Path) -> Path:
        path = _absolute(path)
        if not _beneath(path, self.home) or path == self.home:
            raise ActivationError(f"activation path outside home: {path}")
        return path

    def _safe(self, path: Path) -> Path:
        path = self._confined(path)
        current = self.home
        for part in path.relative_to(self.home).parts[:-1]:
            current /= part
            try:
                info = current.lstat()
            except FileNotFoundError:
                break
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
                raise ActivationError(f"unsafe activation parent directory: {current}")
        return path

    @contextmanager
    def _parent_fd(self, path: Path, *, create=False):
        """Keep parent traversal and mutation relative to no-follow directory handles."""
        self._safe(path)
        fd = os.open(self.home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            if os.fstat(fd).st_uid != os.getuid():
                raise ActivationError(f"activation home not user-owned: {self.home}")
            for part in path.relative_to(self.home).parts[:-1]:
                if create:
                    try:
                        os.mkdir(part, mode=0o700, dir_fd=fd)
                    except FileExistsError:
                        pass
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = next_fd
                if os.fstat(fd).st_uid != os.getuid():
                    raise ActivationError(f"activation parent not user-owned: {path.parent}")
            self._safe(path)
            yield fd
        finally:
            os.close(fd)

    def _mkdir(self, path: Path) -> None:
        with self._parent_fd(path, create=True) as parent:
            self._safe(path)
            try:
                os.mkdir(path.name, mode=0o700, dir_fd=parent)
            except FileExistsError:
                pass
            fd = os.open(path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            try:
                if os.fstat(fd).st_uid != os.getuid():
                    raise ActivationError(f"activation directory not user-owned: {path}")
            finally:
                os.close(fd)

    def _symlink(self, path: Path, target: str) -> None:
        with self._parent_fd(path, create=True) as parent:
            temporary = ".frame-link-" + uuid.uuid4().hex
            try:
                self._safe(path)
                os.symlink(target, temporary, dir_fd=parent)
                self._safe(path)
                os.replace(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent)
            finally:
                try:
                    os.unlink(temporary, dir_fd=parent)
                except FileNotFoundError:
                    pass

    def _unlink(self, path: Path) -> None:
        with self._parent_fd(path) as parent:
            self._safe(path)
            os.unlink(path.name, dir_fd=parent)

    def policy(self) -> Path:
        config = self.env.get("XDG_CONFIG_HOME", "")
        if config and (
            not Path(config).is_absolute()
            or ".." in Path(config).parts
            or Path(config) != self.home / ".config"
            or Path(config).resolve() != self.home / ".config"
        ):
            raise ActivationError("activation requires default XDG_CONFIG_HOME (<home>/.config)")
        self._safe(self.home / ".config/frame-cli")
        data = self.env.get("XDG_DATA_HOME", "")
        data_home = _absolute(Path(data)) if data else self.home / ".local/share"
        self._safe(data_home / "fonts/frame-cli")
        if data_home.resolve() != data_home or not _beneath(data_home, self.home):
            raise ActivationError("XDG_DATA_HOME must be absolute and confined to home")
        font_dir = data_home / "fonts/frame-cli"
        old = self.read_manifest()
        if old and old["font_dir"] != str(font_dir):
            raise ActivationError(
                "font XDG path changed since activation; retain recorded location"
            )
        return font_dir

    def _read_json(self, path: Path) -> dict | None:
        self._safe(path)
        if not path.exists() and not path.is_symlink():
            return None
        st = path.lstat()
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            raise ActivationError(f"control file is not a user-owned regular file: {path}")
        try:
            result = json.loads(path.read_bytes())
        except (ValueError, OSError) as exc:
            raise ActivationError(f"invalid activation metadata: {path}") from exc
        if not isinstance(result, dict):
            raise ActivationError(f"invalid activation metadata: {path}")
        return result

    def read_manifest(self) -> dict | None:
        result = self._read_json(self.manifest_path)
        if result is None:
            return None
        if (
            result.get("version") != 1
            or result.get("home") != str(self.home)
            or result.get("state") != str(self.state)
            or not isinstance(result.get("owned"), dict)
            or not isinstance(result.get("font_dir"), str)
            or not isinstance(result.get("complete"), bool)
            or "profile" not in result
            or "generation" not in result
            or (result["profile"] is not None and not isinstance(result["profile"], str))
        ):
            raise ActivationError("malformed or foreign activation manifest")
        self._confined(Path(result["font_dir"]))
        for path, record in result["owned"].items():
            self._confined(Path(path))
            if not isinstance(record, dict) or record.get("kind") not in {
                "file",
                "link",
                "startup",
            }:
                raise ActivationError("malformed activation ownership")
            key = "target" if record["kind"] == "link" else "sha256"
            if not isinstance(record.get(key), str) or not isinstance(record.get("source"), str):
                raise ActivationError("malformed activation ownership")
        for key in ("generation",):
            if result.get(key) is not None:
                self._generation(result[key])
        return result

    def _generation(self, name: str) -> Path:
        if not isinstance(name, str) or not re.fullmatch(r"[a-f0-9]{32}", name):
            raise ActivationError("invalid asset generation")
        return self._safe(self.assets / "generations" / name)

    def _atomic(self, path: Path, content: bytes, mode: int = 0o600) -> None:
        with self._parent_fd(path, create=True) as parent:
            temporary = f".{path.name}." + uuid.uuid4().hex
            try:
                self._safe(path)
                fd = os.open(
                    temporary,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    mode,
                    dir_fd=parent,
                )
                with os.fdopen(fd, "wb") as stream:
                    stream.write(content)
                    stream.flush()
                    os.fchmod(stream.fileno(), mode)
                    os.fsync(stream.fileno())
                self._safe(path)
                os.replace(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent)
            finally:
                try:
                    os.unlink(temporary, dir_fd=parent)
                except FileNotFoundError:
                    pass

    def _json(self, path: Path, value: dict) -> None:
        self._atomic(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())

    def _template(self, name: str) -> str:
        return (Path(__file__).parent / "templates" / name).read_text()

    def generated(self, font_dir: Path) -> list[Operation]:
        arguments = ["--home", str(self.home), "--state-dir", str(self.state)]
        wrapper_path = shlex.quote(str(self.wrapper))
        wrapper = " ".join(shlex.quote(part) for part in [str(self.wrapper), *arguments])
        hook = (
            self._template("auto-enter.bash")
            .replace("$wrapper", wrapper)
            .replace("@WRAPPER_PATH@", wrapper_path)
        )
        bell = str(self.assets / "current/bell-window-system.oga")
        ghostty = (
            self._template("ghostty.machine")
            .replace("@COMMAND@", f"/bin/sh -c {shlex.quote('exec ' + wrapper + ' enter')}")
            .replace("@BELL@", bell)
        )
        alacritty = (
            self._template("alacritty.machine.toml")
            .replace("@WRAPPER@", json.dumps(str(self.wrapper)))
            .replace("@ARGS@", json.dumps([*arguments, "enter"]))
        )
        xml = self._template("fontconfig.conf").replace("@FONT_DIR@", escape(str(font_dir)))
        return [
            Operation(self.state / "auto-enter.bash", "file", hook.encode(), "auto-enter.bash"),
            Operation(
                self.home / ".config/ghostty/machine", "file", ghostty.encode(), "ghostty.machine"
            ),
            Operation(
                self.home / ".config/alacritty/machine.toml",
                "file",
                alacritty.encode(),
                "alacritty.machine.toml",
            ),
            Operation(
                self.home / ".config/fontconfig/conf.d/99-frame-cli.conf",
                "file",
                xml.encode(),
                "fontconfig.conf",
            ),
            Operation(font_dir, "link", str(self.assets / "current/fonts"), "profile font assets"),
        ]

    def _block(self, content: bytes) -> bytes | None:
        if BEGIN not in content or END not in content:
            return None
        start = content.index(BEGIN)
        end = content.index(END) + len(END)
        return content[start:end]

    def _startup_content(self, original: bytes, login: bool) -> bytes:
        begins = original.count(BEGIN)
        ends = original.count(END)
        if begins or ends:
            if begins != 1 or ends != 1:
                raise ActivationError("duplicate or malformed frame-cli startup markers")
            start = original.index(BEGIN)
            end = original.index(END) + len(END)
            if end <= start or (start and original[start - 1 : start] != b"\n"):
                raise ActivationError("malformed frame-cli startup markers")
            if end < len(original) and original[end : end + 1] != b"\n":
                raise ActivationError("malformed frame-cli startup markers")
            if end < len(original):
                end += 1
            original = original[:start] + original[end:]
        hook = shlex.quote(str(self.state / "auto-enter.bash"))
        condition = "" if login else " && ! shopt -q login_shell"
        block = (
            BEGIN.decode() + "\n"
            'if [ -n "${BASH_VERSION-}" ]; then\n'
            "    case $- in\n"
            f"        *i*) if [ -f {hook} ]{condition}; then . {hook}; fi ;;\n"
            "    esac\n"
            "fi\n" + END.decode() + "\n"
        ).encode()
        return original + (b"\n" if original and not original.endswith(b"\n") else b"") + block

    def startup(self) -> list[Operation]:
        login = next(
            (
                self.home / name
                for name in (".bash_profile", ".bash_login", ".profile")
                if os.path.lexists(self.home / name)
            ),
            self.home / ".bash_profile",
        )
        result = []
        for path, is_login in ((self.home / ".bashrc", False), (login, True)):
            op = Operation(path, "startup", b"", "Bash startup block")
            try:
                self._safe(path)
            except ActivationError as exc:
                op.conflict = str(exc)
                result.append(op)
                continue
            exists = os.path.lexists(path)
            op.existed = exists
            if exists:
                st = path.lstat()
                if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
                    op.conflict = "startup file is not a user-owned regular file"
                    result.append(op)
                    continue
                op.mode = stat.S_IMODE(st.st_mode)
            original = path.read_bytes() if exists else b""
            op.original = original
            try:
                op.content = self._startup_content(original, is_login)
                owned = (self.read_manifest() or {}).get("owned", {}).get(str(path))
                block = self._block(original)
                if owned and (block is None or _digest(block) != owned.get("block_sha256")):
                    op.conflict = "user-modified managed startup block"
                elif block is not None and not owned:
                    op.conflict = "unowned managed startup block"
            except ActivationError as exc:
                op.conflict = str(exc)
            result.append(op)
        return result

    def _matches(self, path: Path, record: dict) -> bool:
        try:
            self._safe(path)
        except ActivationError:
            return False
        if not os.path.lexists(path):
            return False
        st = path.lstat()
        if st.st_uid != os.getuid():
            return False
        if record["kind"] == "link":
            return stat.S_ISLNK(st.st_mode) and os.readlink(path) == record["target"]
        if not stat.S_ISREG(st.st_mode):
            return False
        content = path.read_bytes()
        if record["kind"] == "startup":
            block = self._block(content)
            return block is not None and _digest(block) == record.get("block_sha256")
        return _digest(content) == record["sha256"]

    def _conflict(self, op: Operation, owned: dict) -> None:
        try:
            self._safe(op.path)
        except ActivationError as exc:
            op.conflict = str(exc)
            return
        record = owned.get(str(op.path))
        op.previous = record
        if not os.path.lexists(op.path):
            return
        if record and self._matches(op.path, record):
            return
        op.conflict = "existing unowned or user-modified object"

    def plan(self, profile: str | Path | None = None, *, sync_plan=None) -> Plan:
        font_dir = self.policy()
        profile = str(profile if profile is not None else self.active_profile())
        old = self.read_manifest()
        owned = old["owned"] if old else {}
        operations = self.generated(font_dir)
        for op in operations:
            self._conflict(op, owned)
        operations.extend(self.startup())
        readiness = False
        try:
            result = self.frame.readiness(activation=True)
            readiness = result is not False
        except (ValueError, OSError, RuntimeError):
            pass
        return Plan(profile, operations, font_dir, sync_plan=sync_plan, readiness=readiness)

    def active_profile(self) -> str:
        validate = getattr(self.frame, "validate_profile", None)
        if validate:
            result = validate()
            if result is not None:
                return str(result)
        profile = self.state / "profile"
        if profile.is_symlink():
            target = Path(os.readlink(profile))
            if not target.is_absolute():
                target = profile.parent / target
            if target.is_symlink():
                return os.readlink(target)
            return str(target)
        return str(profile)

    def _source(self, path: Path) -> Path:
        if str(path).startswith("/nix/store/"):
            if not self.source_resolver:
                raise ActivationError("a selected-store source resolver is required")
            return Path(self.source_resolver(path)).resolve(strict=True)
        store = self.state / "store/store"
        if _beneath(path, store):
            logical = Path("/nix/store") / path.relative_to(store)
            if self.source_resolver:
                return Path(self.source_resolver(logical)).resolve(strict=True)
        if self.source_resolver:
            return Path(self.source_resolver(path)).resolve(strict=True)
        return path.resolve(strict=True)

    def _resolve_child(self, path: Path, root: Path, companions: tuple[Path, ...] = ()) -> Path:
        roots = (root, *companions)
        seen = set()
        # Resolve one link at a time so an undeclared intermediate store output is rejected.
        for _ in range(40):
            if str(path).startswith("/nix/store/"):
                parts = path.parts
                output = self._source(Path(*parts[:4]))
                path = output / Path(*parts[4:])
            path = Path(os.path.normpath(path))
            selected = next((allowed for allowed in roots if _beneath(path, allowed)), None)
            if selected is None:
                raise ActivationError(f"asset source escapes declared output: {path}")
            current = selected
            relative = path.relative_to(selected).parts
            for index, part in enumerate(relative):
                current /= part
                if current.is_symlink():
                    if current in seen:
                        raise ActivationError(f"asset symlink cycle: {current}")
                    seen.add(current)
                    target = Path(os.readlink(current))
                    path = target if target.is_absolute() else current.parent / target
                    path /= Path(*relative[index + 1 :])
                    break
            else:
                return path
        raise ActivationError("asset symlink cycle or chain exceeds 40 links")

    def _asset_destination(self, destination: Path) -> None:
        try:
            self._safe(destination)
        except ActivationError as exc:
            raise ActivationError(f"asset destination is redirected: {destination}") from exc
        if destination.is_symlink():
            raise ActivationError(f"asset destination is redirected: {destination}")

    def _copy_asset(self, source: Path, destination: Path) -> None:
        self._asset_destination(destination)
        with self._parent_fd(destination, create=True) as parent:
            self._asset_destination(destination)
            fd = os.open(
                destination.name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o644,
                dir_fd=parent,
            )
            with os.fdopen(fd, "wb") as output, source.open("rb") as input_file:
                shutil.copyfileobj(input_file, output)
                os.fchmod(output.fileno(), 0o644)

    def _copy_tree(
        self,
        source: Path,
        destination: Path,
        root: Path,
        seen=None,
        companions: tuple[Path, ...] = (),
    ) -> int:
        self._asset_destination(destination)
        source = self._resolve_child(source, root, companions)
        seen = set() if seen is None else seen
        if source in seen:
            raise ActivationError(f"asset symlink cycle: {source}")
        if source.is_file():
            source = self._resolve_child(source, root, companions)
            self._copy_asset(source, destination)
            return 1
        if not source.is_dir():
            raise ActivationError(f"asset is not a regular file/directory: {source}")
        self._asset_destination(destination)
        self._mkdir(destination)
        count = 0
        for child in sorted(source.iterdir()):
            count += self._copy_tree(
                child, destination / child.name, root, seen | {source}, companions
            )
        return count

    def export(self, profile: str) -> str:
        self.policy()
        profile_root = self._source(Path(profile))
        metadata = self._source(profile_root / "share/frame-cli/assets.json")
        try:
            declared = json.loads(metadata.read_bytes())
        except (ValueError, OSError) as exc:
            raise ActivationError("profile has invalid assets.json") from exc
        if not isinstance(declared, dict) or not isinstance(declared.get("fonts"), list):
            raise ActivationError("profile has invalid asset declarations")
        refs = profile_root / "share/frame-cli/assets"
        declared_fonts = []
        companion_references = set()
        for record in declared["fonts"]:
            if (
                not isinstance(record, dict)
                or not isinstance(record.get("reference"), str)
                or not re.fullmatch(r"fonts/[A-Za-z0-9._+-]+", record["reference"])
                or not isinstance(record.get("path"), str)
            ):
                raise ActivationError("invalid declared font reference")
            reference = record["reference"]
            root = self._source(refs / reference)
            if root != self._source(_absolute(Path(record["path"]))):
                raise ActivationError("font reference does not match declared output")
            declared_companions = record.get("companions", [])
            if not isinstance(declared_companions, list):
                raise ActivationError("font companions must be a list")
            companions = []
            prefix = "font-companions/" + Path(reference).name + "-"
            for companion in declared_companions:
                if (
                    not isinstance(companion, dict)
                    or not isinstance(companion.get("reference"), str)
                    or not re.fullmatch(r"font-companions/[A-Za-z0-9._+-]+", companion["reference"])
                    or not companion["reference"].startswith(prefix)
                    or not isinstance(companion.get("path"), str)
                ):
                    raise ActivationError("invalid per-font companion reference")
                companion_reference = companion["reference"]
                if companion_reference in companion_references:
                    raise ActivationError("duplicate font companion reference")
                companion_references.add(companion_reference)
                companion_root = self._source(refs / companion_reference)
                if companion_root != self._source(_absolute(Path(companion["path"]))):
                    raise ActivationError("font companion reference does not match declared output")
                companions.append(companion_root)
            declared_fonts.append((Path(reference).name, root, tuple(companions)))
        if len({name for name, _, _ in declared_fonts}) != len(declared_fonts):
            raise ActivationError("duplicate font output reference")
        bell_record = declared.get("bell")
        if (
            not isinstance(bell_record, dict)
            or bell_record.get("reference") != "bell"
            or not isinstance(bell_record.get("path"), str)
            or not isinstance(bell_record.get("relativePath"), str)
        ):
            raise ActivationError("invalid declared bell reference")
        bell_relative = Path(bell_record["relativePath"])
        if bell_relative.is_absolute() or ".." in bell_relative.parts:
            raise ActivationError("bell source path escapes declared output")
        name = uuid.uuid4().hex
        generation = self._generation(name)
        self._asset_destination(generation.parent)
        self._mkdir(generation.parent)
        self._asset_destination(generation)
        self._mkdir(generation)
        try:
            count = 0
            for reference, root, companions in declared_fonts:
                font_source = self._resolve_child(root / "share/fonts", root, companions)
                if not font_source.exists():
                    raise ActivationError(f"rooted font output has no share/fonts: {reference}")
                count += self._copy_tree(
                    font_source, generation / "fonts" / reference, root, companions=companions
                )
            if not count:
                raise ActivationError("profile font assets are empty")
            ocean = self._source(refs / "bell")
            if ocean != self._source(Path(bell_record["path"])):
                raise ActivationError("bell reference does not match declared output")
            bell = self._resolve_child(ocean / bell_relative, ocean)
            if not bell.is_file():
                raise ActivationError("Ocean bell is not a regular file")
            self._copy_asset(bell, generation / "bell-window-system.oga")
            self._asset_destination(generation / "generation.json")
            self._json(generation / "generation.json", {"profile": profile, "version": 1})
            return name
        except BaseException:
            self._asset_destination(generation)
            with self._parent_fd(generation) as parent:
                self._asset_destination(generation)
                shutil.rmtree(generation.name, dir_fd=parent)
            raise

    def _pointer(self, generation: str) -> None:
        directory = self._generation(generation)
        self._asset_destination(directory)
        info = self._read_json(directory / "generation.json")
        if not info or not (directory / "fonts").is_dir():
            raise ActivationError("asset generation is incomplete")
        pointer = self._safe(self.assets / "current")
        if os.path.lexists(pointer):
            if not pointer.is_symlink():
                raise ActivationError("asset pointer is not a managed symlink")
            old_target = os.readlink(pointer)
            if not re.fullmatch(r"generations/[a-f0-9]{32}", old_target):
                raise ActivationError("asset pointer target is foreign")
        old = self.read_manifest()
        if old and old["generation"] and os.path.lexists(pointer):
            allowed = {"generations/" + old["generation"]}
            journal = self._read_json(self.journal_path)
            if journal:
                journal_generation = journal.get("generation")
                if isinstance(journal_generation, str):
                    self._generation(journal_generation)
                    allowed.add("generations/" + journal_generation)
            if os.readlink(pointer) not in allowed:
                raise ActivationError("asset pointer changed outside managed publication")
        self._symlink(pointer, "generations/" + generation)

    def _empty_manifest(self, font_dir: Path) -> dict:
        return {
            "version": 1,
            "home": str(self.home),
            "state": str(self.state),
            "font_dir": str(font_dir),
            "owned": {},
            "profile": None,
            "generation": None,
            "complete": False,
        }

    def _apply_operations(self, operations: list[Operation], manifest: dict) -> list[str]:
        conflicts = []
        for op in operations:
            if op.kind == "startup" and conflicts and not op.conflict:
                op.conflict = "automatic startup deferred until integration conflicts are resolved"
            if not op.conflict:
                try:
                    self._safe(op.path)
                except ActivationError as exc:
                    op.conflict = str(exc)
            if op.conflict:
                conflicts.append(f"{op.path}: {op.conflict}")
                continue
            if op.kind == "startup":
                exists = os.path.lexists(op.path)
                if exists != op.existed or (
                    exists
                    and (
                        not stat.S_ISREG(op.path.lstat().st_mode)
                        or op.path.lstat().st_uid != os.getuid()
                        or op.path.read_bytes() != op.original
                    )
                ):
                    raise ActivationError(f"startup file changed after plan: {op.path}")
                if exists and op.content != op.original and str(op.path) not in manifest["owned"]:
                    backup = op.path.parent / (
                        op.path.name + ".frame-cli-backup-" + uuid.uuid4().hex
                    )
                    self._atomic(backup, op.original, op.mode)
                    manifest.setdefault("backups", {})[str(op.path)] = str(backup)
            else:
                self._conflict(op, manifest["owned"])
                if op.conflict:
                    conflicts.append(f"{op.path}: {op.conflict}")
                    continue
            if op.kind == "link":
                if not (op.path.is_symlink() and os.readlink(op.path) == op.content):
                    self._symlink(op.path, op.content)
                record = {"kind": "link", "target": op.content, "source": op.source}
            else:
                if not op.path.exists() or op.path.read_bytes() != op.content:
                    self._atomic(op.path, op.content, op.mode)
                record = {"kind": op.kind, "sha256": _digest(op.content), "source": op.source}
                if op.kind == "startup":
                    record["block_sha256"] = _digest(self._block(op.content))
            manifest["owned"][str(op.path)] = record
            self._json(self.manifest_path, manifest)
        return conflicts

    def apply(self, plan: Plan, *, confirmed: bool = False, sync_apply=None) -> dict:
        if not confirmed:
            raise ActivationError("activation requires explicit confirmation of the combined plan")
        if self.policy() != plan.font_dir:
            raise ActivationError("activation plan no longer matches font path")
        if not plan.readiness:
            raise ActivationError("installation is not ready; install before activation")
        self.reconcile()
        if self.active_profile() != plan.profile:
            raise ActivationError("profile changed after activation planning")
        sync_result = sync_apply(plan.sync_plan) if sync_apply else None
        manifest = self.read_manifest() or self._empty_manifest(plan.font_dir)
        generation = self.export(plan.profile)
        self._json(self.manifest_path, manifest)
        self._json(
            self.journal_path,
            {
                "version": 1,
                "profile": plan.profile,
                "generation": generation,
                "previous_profile": manifest["profile"],
                "previous_generation": manifest["generation"],
            },
        )
        self._pointer(generation)
        manifest.update(profile=plan.profile, generation=generation, complete=False)
        self._json(self.manifest_path, manifest)
        for op in plan.operations:
            if op.kind != "startup" and not op.conflict:
                self._conflict(op, manifest["owned"])
        selected = getattr(plan.sync_plan, "plan", plan.sync_plan)
        prerequisite_conflicts = [
            f"{op.destination}: {op.conflict}" for op in getattr(selected, "conflicts", ())
        ]
        prerequisite_conflicts.extend(getattr(sync_result, "warnings", ()))
        if getattr(sync_result, "complete", True) is False:
            prerequisite_conflicts.append(
                "home sync is incomplete; review the reported link results"
            )
        prerequisite_conflicts.extend(
            f"{op.path}: {op.conflict}"
            for op in plan.operations
            if op.kind != "startup" and op.conflict
        )
        startup_conflicts = any(op.kind == "startup" and op.conflict for op in plan.operations)
        if prerequisite_conflicts or startup_conflicts:
            for op in plan.operations:
                if op.kind == "startup" and not op.conflict:
                    op.conflict = (
                        "automatic startup deferred until integration conflicts are resolved"
                    )
        conflicts = self._apply_operations(plan.operations, manifest)
        conflicts.extend(prerequisite_conflicts)
        manifest["complete"] = not conflicts
        self._json(self.manifest_path, manifest)
        self._unlink(self.journal_path)
        self.refresh_fonts(plan.font_dir)
        return {"complete": not conflicts, "conflicts": conflicts, "generation": generation}

    def refresh_fonts(self, font_dir: Path) -> None:
        path = self.env.get("PATH", os.defpath)
        report = {
            "context": "host",
            "cache_available": False,
            "query_available": False,
            "required_families_verified": False,
        }
        command = shutil.which("fc-cache", path=path)
        query = shutil.which("fc-list", path=path)
        try:
            if command:
                result = subprocess.run(
                    [command, "-f", str(font_dir)],
                    env=self.env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                    timeout=30,
                )
                report.update(cache_available=True, cache_returncode=result.returncode)
            if query:
                result = subprocess.run(
                    [query, "--format", "%{file}\\t%{family}\\n"],
                    env=self.env,
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=30,
                )
                prefix = str(font_dir) + "/"
                families = sorted(
                    {
                        line.split("\t", 1)[1]
                        for line in result.stdout.splitlines()
                        if line.startswith(prefix) and "\t" in line
                    }
                )
                report.update(
                    query_available=True,
                    query_returncode=result.returncode,
                    families=families,
                    owned_fonts_discovered=bool(families),
                )
        except (OSError, subprocess.TimeoutExpired) as exc:
            report["error"] = str(exc)
        manifest = self.read_manifest()
        if manifest:
            manifest["font_validation"] = report
            self._json(self.manifest_path, manifest)

    def prepare(self, profile: str | Path) -> Prepared | None:
        self.policy()
        self.reconcile()
        manifest = self.read_manifest()
        if not manifest:
            return None
        font_dir = Path(manifest["font_dir"])
        operations = self.generated(font_dir)
        for op in operations:
            self._conflict(op, manifest["owned"])
        if any(op.conflict for op in operations):
            raise ActivationError(
                "generated integration changed; resolve conflicts before profile switch"
            )
        generation = self.export(str(profile))
        prepared = Prepared(str(profile), generation, manifest["profile"], manifest["generation"])
        self._json(self.journal_path, {"version": 1, **prepared.__dict__})
        return prepared

    def publish(self, prepared: Prepared | None) -> None:
        if prepared is None:
            return
        self.policy()
        if self.active_profile() != prepared.profile:
            raise ActivationError("profile did not switch to prepared asset profile")
        self._finish(prepared)

    def _finish(self, prepared: Prepared) -> None:
        manifest = self.read_manifest()
        if not manifest:
            raise ActivationError("activation manifest missing during publication")
        self._pointer(prepared.generation)
        manifest.update(profile=prepared.profile, generation=prepared.generation)
        self._json(self.manifest_path, manifest)
        conflicts = self._apply_operations(self.generated(Path(manifest["font_dir"])), manifest)
        if conflicts:
            manifest["complete"] = False
            self._json(self.manifest_path, manifest)
            raise ActivationError("generated integration changed during publication")
        self._unlink(self.journal_path)
        self.refresh_fonts(Path(manifest["font_dir"]))

    def reconcile(self) -> None:
        self.policy()
        journal = self._read_json(self.journal_path)
        if not journal:
            return
        if journal.get("version") != 1:
            raise ActivationError("invalid profile/assets switch journal")
        try:
            prepared = Prepared(
                **{
                    key: journal[key]
                    for key in (
                        "profile",
                        "generation",
                        "previous_profile",
                        "previous_generation",
                    )
                }
            )
        except KeyError as exc:
            raise ActivationError("incomplete profile/assets switch journal") from exc
        self._generation(prepared.generation)
        active = self.active_profile()
        if active == prepared.profile:
            self._finish(prepared)
        elif active == prepared.previous_profile:
            if prepared.previous_generation:
                self._pointer(prepared.previous_generation)
                manifest = self.read_manifest()
                if manifest:
                    manifest.update(
                        profile=prepared.previous_profile, generation=prepared.previous_generation
                    )
                    self._json(self.manifest_path, manifest)
            self._unlink(self.journal_path)
        else:
            raise ActivationError(
                "profile/assets mismatch; no journal entry matches active profile"
            )

    def status(self) -> dict:
        manifest = self.read_manifest()
        if not manifest:
            return {"activated": False, "mismatch": os.path.lexists(self.journal_path)}
        pointer = self.assets / "current"
        expected = "generations/" + manifest["generation"] if manifest["generation"] else None
        mismatch = (
            manifest["profile"] != self.active_profile()
            or not pointer.is_symlink()
            or os.readlink(pointer) != expected
            or os.path.lexists(self.journal_path)
        )
        changed = [
            path
            for path, record in manifest["owned"].items()
            if not self._matches(Path(path), record)
        ]
        return {
            "activated": True,
            "complete": manifest["complete"] and not changed,
            "mismatch": mismatch,
            "profile": manifest["profile"],
            "generation": manifest["generation"],
            "changed": changed,
            "font_dir": manifest["font_dir"],
            "font_validation": manifest.get(
                "font_validation",
                {
                    "context": "host",
                    "required_families_verified": False,
                    "status": "not queried",
                },
            ),
        }


def prepare(frame, candidate) -> Prepared | None:
    return Activation(frame).prepare(candidate)


def publish(frame, prepared: Prepared | None) -> None:
    Activation(frame).publish(prepared)


def reconcile(frame) -> None:
    Activation(frame).reconcile()


def status(frame) -> dict:
    return Activation(frame).status()


def handle_cli(frame, *, dry_run=False, confirm=None, input_fn=None, output=print) -> int:
    """Extend the shared sync workflow with generated assets and startup files."""
    from home_sync import apply_home_sync, plan_home_sync
    from sync_workflow import run_sync

    activation = None

    def planned():
        nonlocal activation
        activation = Activation(frame)
        font_dir = activation.policy()
        selected = plan_home_sync(
            target="frame",
            home=activation.home,
            repo=activation.repo,
            extra_exclusions=(
                str(activation.state.relative_to(activation.home)),
                str(activation.wrapper.relative_to(activation.home)),
                str(font_dir.relative_to(activation.home)),
            ),
        )
        return activation.plan(sync_plan=selected)

    def signature(plan):
        manager = activation
        current = []
        for op in plan.operations:
            path = op.path
            content = None
            if not op.conflict:
                manager._safe(path)
                if path.is_symlink():
                    content = ("link", os.readlink(path))
                elif os.path.lexists(path) and stat.S_ISREG(path.lstat().st_mode):
                    content = (
                        "file",
                        _digest(path.read_bytes()),
                        stat.S_IMODE(path.lstat().st_mode),
                    )
            current.append((str(path), op.kind, op.content, op.original, op.conflict, content))
        return (plan.profile, plan.readiness, plan.sync_plan, current, manager.read_manifest())

    def apply(current):
        sync_result = None

        def sync_apply(chosen):
            nonlocal sync_result
            sync_result = apply_home_sync(chosen, confirmed=True)
            return sync_result

        result = activation.apply(current, confirmed=True, sync_apply=sync_apply)
        if sync_result is not None:
            result.update(
                plan=current.sync_plan,
                ownership=sync_result.ownership,
                warnings=sync_result.warnings,
                backups=sync_result.backups,
            )
        return result

    return run_sync(
        planner=planned,
        applier=apply,
        describe=lambda plan: plan.describe(),
        signature=signature,
        lock=frame.lock,
        dry_run=dry_run,
        confirm=confirm,
        input_fn=input_fn,
        output=output,
    )
