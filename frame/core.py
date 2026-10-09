"""Standard-library deployment and namespace execution for Frame."""

import hashlib
import importlib
import json
import os
import platform
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path

from .paths import FrameError, Paths

HELPER_VERSION = "2.1.1"
NIX_VERSION = "2.28.5"
HELPER_URL = (
    "https://github.com/nix-community/nix-user-chroot/releases/download/2.1.1/"
    "nix-user-chroot-bin-2.1.1-aarch64-unknown-linux-musl"
)
HELPER_SHA256 = "9aeaa70f4fb645afb343b0417e494b0271457a8cb465c4ac82b6c3b19040d397"
NIX_URL = "https://releases.nixos.org/nix/nix-2.28.5/nix-2.28.5-aarch64-linux.tar.xz"
NIX_SHA256 = "a7d20e2897de8044ed35a481d455e88130b6d70e40f2470d1b7c26727f6c8d8c"
NIX_CONFIG = """build-users-group =
experimental-features = nix-command flakes
sandbox = true
require-sigs = true
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
"""
NIX_INHERITED = (
    "NIX_CONFIG",
    "NIX_REMOTE",
    "NIX_STORE_DIR",
    "NIX_STORE",
    "NIX_STATE_DIR",
    "NIX_LOG_DIR",
    "NIX_DATA_DIR",
    "NIX_SSL_CERT_FILE",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
)
STORE_TARGET = re.compile(r"^/nix/store/[a-z0-9]{32}-[A-Za-z0-9+._?=-]+$")
GENERATION = re.compile(r"^profile-([1-9][0-9]*)-link$")
CERTIFICATE_ARCHIVE_PATH = re.compile(
    rf"^nix-{re.escape(NIX_VERSION)}-aarch64-linux/store/"
    r"[a-z0-9]{32}-nss-cacert-[A-Za-z0-9+._=-]+/etc/ssl/certs/ca-bundle\.crt$"
)
IDENTITY_SCRIPT = (
    "import os,sys; a=os.stat(sys.argv[1]); b=os.stat('/nix'); "
    "sys.exit(0 if (a.st_dev,a.st_ino)==(b.st_dev,b.st_ino) "
    "and os.geteuid()==int(sys.argv[2]) else 1)"
)


def digest(path):
    hasher = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def download(url, destination):
    with urllib.request.urlopen(url, timeout=60) as source, Path(destination).open("wb") as output:
        shutil.copyfileobj(source, output)


def extract_installer(archive, destination):
    """Accept only the pinned Nix release tree, without special files or escaping links."""
    root = f"nix-{NIX_VERSION}-aarch64-linux"
    with tarfile.open(archive, "r:xz") as bundle:
        members = bundle.getmembers()
        names = {str(Path(member.name)): member for member in members}
        destination = Path(destination)
        if destination.exists() and any(destination.iterdir()):
            raise FrameError("Installer extraction requires an empty staging directory")
        destination.mkdir(parents=True, exist_ok=True)
        for member in members:
            name = Path(member.name)
            if name.is_absolute() or ".." in name.parts or not name.parts or name.parts[0] != root:
                raise FrameError(f"Unsafe installer archive path: {member.name}")
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise FrameError(f"Unsupported installer archive entry: {member.name}")
            if member.issym() or member.islnk():
                target = Path(member.linkname)
                if target.is_absolute():
                    parts = target.parts
                    if (
                        not member.issym()
                        or ".." in parts
                        or len(parts) < 4
                        or parts[:3] != ("/", "nix", "store")
                        or not STORE_TARGET.fullmatch("/nix/store/" + parts[3])
                    ):
                        raise FrameError(f"Escaping installer archive link: {member.name}")
                    referenced = str(Path(root) / "store" / Path(*parts[3:]))
                    if referenced not in names:
                        raise FrameError(
                            f"Installer logical store link target is absent: {member.name}"
                        )
                    continue
                base = name.parent if member.issym() else Path()
                combined = base / target
                depth = 0
                for part in combined.parts:
                    if part == "..":
                        depth -= 1
                    elif part not in (".", ""):
                        depth += 1
                    if depth < 1:
                        raise FrameError(f"Escaping installer archive link: {member.name}")
                if target.is_absolute() or not combined.parts or combined.parts[0] != root:
                    raise FrameError(f"Escaping installer archive link: {member.name}")
        seen = {}
        for member in members:
            name = Path(member.name)
            if str(name) in seen:
                raise FrameError(f"Duplicate installer archive path: {name}")
            if any(
                str(parent) in names and not names[str(parent)].isdir() for parent in name.parents
            ):
                raise FrameError(f"Installer archive path has a link/file parent: {name}")
            if member.islnk():
                previous = seen.get(member.linkname)
                if previous is None or not previous.isfile():
                    raise FrameError(
                        f"Installer hardlink target is not a prior regular file: {name}"
                    )
            member.mode &= 0o777
            seen[str(name)] = member

        # No extraction traverses symlink parents. Only prevalidated logical store links remain.
        def checked_filter(member, _destination):
            member.uid = member.gid = os.getuid()
            member.uname = member.gname = None
            return member

        bundle.extractall(destination, members=members, filter=checked_filter)
    installer = Path(destination) / root / "install"
    if not installer.is_file() or installer.is_symlink():
        raise FrameError("Pinned installer archive does not contain its regular install script")
    return installer


def installer_certificate(archive, installer):
    """Select the unique regular cacert bundle from an already verified release archive."""
    with tarfile.open(archive, "r:xz") as bundle:
        candidates = [
            member for member in bundle.getmembers() if Path(member.name).name == "ca-bundle.crt"
        ]
        if (
            len(candidates) != 1
            or not candidates[0].isfile()
            or not CERTIFICATE_ARCHIVE_PATH.fullmatch(candidates[0].name)
        ):
            raise FrameError("Pinned installer must contain exactly one regular cacert CA bundle")
        member = candidates[0]
        certificate = Path(installer).parent / Path(member.name).relative_to(
            Path(member.name).parts[0]
        )
        if (
            not certificate.is_file()
            or certificate.is_symlink()
            or certificate.stat().st_size != member.size
            or member.size == 0
        ):
            raise FrameError("Verified installer certificate bytes are unavailable")
        return certificate, member.name


class Frame:
    def __init__(
        self, home=None, state_dir=None, *, runner=None, repo=None, environ=None, downloader=None
    ):
        self.environ = dict(os.environ if environ is None else environ)
        self.paths = Paths(home or self.environ.get("HOME", str(Path.home())), state_dir)
        self.home = self.paths.home
        self.state = self.paths.state
        self.profile = self.paths.profile
        self.repo = Path(repo or Path(__file__).resolve().parent.parent).resolve()
        self.runner = runner or subprocess.run
        self.downloader = downloader or download
        self._install_certificate = None

    @property
    def certificate_path(self):
        return self.state / "bootstrap-certificates/ca-bundle.crt"

    def verified_certificate(self, record=None):
        record = record or self._install_certificate
        if record is None:
            record = self.paths.read_json(self.paths.metadata).get("certificate")
        path = self.certificate_path
        if (
            not isinstance(record, dict)
            or record.get("path") != str(path)
            or not re.fullmatch(r"[a-f0-9]{64}", str(record.get("sha256", "")))
            or not CERTIFICATE_ARCHIVE_PATH.fullmatch(str(record.get("archive_path", "")))
        ):
            raise FrameError("Bootstrap certificate metadata is invalid")
        self.paths.check(path)
        info = path.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or info.st_uid != os.getuid()
            or info.st_mode & 0o022
            or digest(path) != record["sha256"]
        ):
            raise FrameError("Bootstrap certificate is not the retained verified regular file")
        return path

    def lock(self):
        return self.paths.lock()

    def run(self, argv, *, env=None, capture_output=True, check=True, cwd=None):
        result = self.runner(
            [str(arg) for arg in argv],
            env=env or self.environment(),
            cwd=cwd,
            capture_output=capture_output,
            text=True,
            check=False,
        )
        if check and result.returncode:
            detail = (getattr(result, "stderr", "") or "").strip()
            raise FrameError(f"Command failed ({result.returncode}): {argv[0]}: {detail}")
        return result

    def environment(self):
        env = {
            key: value for key, value in self.environ.items() if not key.startswith("BASH_FUNC_")
        }
        for key in (*NIX_INHERITED, "BASH_ENV", "ENV", "LD_LIBRARY_PATH", "LD_PRELOAD"):
            env.pop(key, None)
        env.update(
            HOME=str(self.home),
            NIX_CONF_DIR="/nix/etc/nix",
            NIX_USER_CONF_FILES="",
            NIX_REMOTE="local",
            NIX_BECOME="/usr/bin/false",
            TMPDIR=str(self.paths.tmp),
        )
        return env

    def _exports(self, env):
        return "\n".join(
            f"export {key}={shlex.quote(value)}"
            for key, value in env.items()
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key)
        )

    def namespace_argv(self, argv, *, profile=None, source=True, env=None, reuse=False):
        """Build host argv for a controlled namespace process, including detached children."""
        env = {
            key: value
            for key, value in (self.environment() if env is None else env).items()
            if not key.startswith("BASH_FUNC_")
        }
        for key in (*NIX_INHERITED, "BASH_ENV", "ENV", "LD_LIBRARY_PATH", "LD_PRELOAD"):
            env.pop(key, None)
        env.update(
            NIX_CONF_DIR="/nix/etc/nix",
            NIX_USER_CONF_FILES="",
            NIX_REMOTE="local",
            NIX_BECOME="/usr/bin/false",
            TMPDIR=str(self.paths.tmp),
        )
        selected = Path(profile or self.profile)
        prefix = "set -e\n"
        if source:
            boot = self.paths.bootstrap_home
            source_file = boot / ".nix-profile/etc/profile.d/nix.sh"
            prefix += (
                self._exports(
                    {
                        "HOME": str(boot),
                        "XDG_CONFIG_HOME": str(boot / ".config"),
                        "XDG_DATA_HOME": str(boot / ".local/share"),
                        "XDG_STATE_HOME": str(boot / ".local/state"),
                        "XDG_CACHE_HOME": str(boot / ".cache"),
                    }
                )
                + "\n"
            )
            prefix += f". {shlex.quote(str(source_file))}\n"
        prefix += "unset " + " ".join(NIX_INHERITED) + "\n"
        # Clear XDG values introduced by nix.sh before restoring the caller's original values.
        prefix += "unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME\n"
        restored = {
            key: value
            for key, value in env.items()
            if key
            in (
                "HOME",
                "PATH",
                "SSH_AUTH_SOCK",
                "SSH_AGENT_PID",
                "DBUS_SESSION_BUS_ADDRESS",
                "TERM",
                "COLORTERM",
                "DISPLAY",
                "WAYLAND_DISPLAY",
                "TMPDIR",
            )
            or key.startswith("XDG_")
            or key.startswith("NIX_")
        }
        prefix += self._exports(restored) + "\n"
        bootstrap_bin = self.paths.bootstrap_home / ".nix-profile/bin"
        if source or self._install_certificate is not None or self.paths.metadata.exists():
            cert = self.verified_certificate()
            prefix += (
                self._exports({"NIX_SSL_CERT_FILE": str(cert), "SSL_CERT_FILE": str(cert)}) + "\n"
            )
        path_prefix = ":".join(
            str(path)
            for path in (
                selected / "bin",
                selected / "sbin",
                bootstrap_bin,
                self.home / ".local/bin",
                self.home / ".cargo/bin",
            )
        )
        prefix += f'export PATH={shlex.quote(path_prefix)}:"$PATH"\n'
        prefix += (
            self._exports(
                {
                    "SHELL": str(selected / "bin/fish"),
                    "NIX_PATH": f"nixpkgs={selected}/share/frame-cli/nixpkgs",
                    "FRAME_CLI_ACTIVE": "1",
                    "FRAME_CLI_STATE": str(self.state),
                }
            )
            + "\n"
        )
        pkgconfig = str(selected / "lib/pkgconfig") + ":" + str(selected / "share/pkgconfig")
        prefix += (
            f"export PKG_CONFIG_PATH={shlex.quote(pkgconfig)}"
            "${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}\n"
        )
        prefix += 'exec "$@"'
        command = ["/bin/bash", "--noprofile", "--norc", "-c", prefix, "frame-cli", *argv]
        if not reuse:
            command = [self.paths.helper, self.paths.store, *command]
        return [str(item) for item in command]

    def namespace_run(
        self,
        argv,
        *,
        profile=None,
        capture_output=True,
        check=True,
        source=True,
        env=None,
        reuse=False,
    ):
        controlled = {
            key: value
            for key, value in (self.environment() if env is None else env).items()
            if not key.startswith("BASH_FUNC_")
        }
        for key in (*NIX_INHERITED, "BASH_ENV", "ENV", "LD_LIBRARY_PATH", "LD_PRELOAD"):
            controlled.pop(key, None)
        controlled.update(
            NIX_CONF_DIR="/nix/etc/nix",
            NIX_USER_CONF_FILES="",
            NIX_REMOTE="local",
            NIX_BECOME="/usr/bin/false",
            TMPDIR=str(self.paths.tmp),
        )
        command = self.namespace_argv(
            argv, profile=profile, source=source, env=controlled, reuse=reuse
        )
        return self.run(command, env=controlled, capture_output=capture_output, check=check)

    def resolve_store_path(self, logical):
        """Map a logical store path, including symlinks, into this selected physical store."""
        logical = Path(logical)
        if not logical.is_absolute() or ".." in logical.parts:
            raise FrameError(f"Invalid logical store path: {logical}")
        for _ in range(40):
            parts = logical.parts
            if len(parts) < 4 or parts[:3] != ("/", "nix", "store"):
                raise FrameError(f"Store reference escapes selected store: {logical}")
            physical = self.physical_target("/nix/store/" + parts[3])
            changed = False
            for index, part in enumerate(parts[4:], start=4):
                physical /= part
                self.paths.check(physical, final_symlink=True)
                if physical.is_symlink():
                    target = Path(os.readlink(physical))
                    if not target.is_absolute():
                        target = Path(*parts[:index]) / target
                    logical = Path(os.path.normpath(target)) / Path(*parts[index + 1 :])
                    changed = True
                    break
            if not changed:
                self.paths.check(physical)
                return physical
        raise FrameError("Store symlink chain is too long")

    def physical_target(self, target):
        if not STORE_TARGET.fullmatch(target):
            raise FrameError(f"Invalid profile store target: {target}")
        path = self.paths.store / "store" / target.removeprefix("/nix/store/")
        self.paths.check(path)
        if not path.is_dir() or path.is_symlink():
            raise FrameError(f"Profile target is absent from the selected store: {target}")
        return path

    def validate_profile(self, profile=None):
        profile = Path(profile or self.profile)
        self.paths.check(profile, final_symlink=True)
        if not profile.is_symlink():
            raise FrameError(f"Profile must be a generation symlink: {profile}")
        target = os.readlink(profile)
        if profile == self.profile:
            if not GENERATION.fullmatch(target):
                raise FrameError(f"Invalid profile generation link: {target}")
            generation = self.paths.state / target
            self.paths.check(generation, final_symlink=True)
            if not generation.is_symlink():
                raise FrameError("Profile generation is not a symlink")
            target = os.readlink(generation)
        elif not GENERATION.fullmatch(profile.name):
            raise FrameError("Unexpected generation name")
        self.physical_target(target)
        return target

    def _bootstrap_metadata(self):
        value = self.paths.read_json(self.paths.metadata)
        if (
            value.get("schema") != 1
            or value.get("home") != str(self.home)
            or value.get("state") != str(self.state)
            or value.get("uid") != os.getuid()
            or value.get("helper_version") != HELPER_VERSION
            or value.get("nix_version") != NIX_VERSION
            or value.get("helper_sha256") != HELPER_SHA256
            or value.get("installer_sha256") != NIX_SHA256
        ):
            raise FrameError("Bootstrap metadata does not describe this owned installation")
        self.paths.check(self.paths.store)
        self.paths.check(self.paths.helper)
        if not self.paths.store.is_dir() or not os.access(self.paths.helper, os.X_OK):
            raise FrameError("Bootstrap helper or store is unavailable")
        if digest(self.paths.helper) != HELPER_SHA256:
            raise FrameError("Bootstrap helper checksum mismatch")
        self.verified_certificate(value.get("certificate"))
        self.bootstrap_profile()
        return value

    def bootstrap_profile(self):
        def read_link(path):
            self.paths.check(path, final_symlink=True)
            if not path.is_symlink():
                raise FrameError("Bootstrap Nix profile must be an owned store symlink chain")
            return os.readlink(path)

        entry = self.paths.bootstrap_home / ".nix-profile"
        raw = read_link(entry)
        if not STORE_TARGET.fullmatch(raw):
            xdg_profile = self.paths.bootstrap_home / ".local/state/nix/profiles/profile"
            legacy = Path("/nix/var/nix/profiles/per-user") / pwd.getpwuid(os.getuid()).pw_name
            allowed = {
                xdg_profile: xdg_profile,
                legacy / "profile": self.paths.store / (legacy / "profile").relative_to("/nix"),
            }
            target = Path(raw)
            if ".." in target.parts:
                raise FrameError("Bootstrap profile control link contains traversal")
            control = target if target.is_absolute() else entry.parent / target
            if control not in allowed:
                raise FrameError("Bootstrap profile escapes its canonical owned profile controls")
            profile = allowed[control]
            raw = read_link(profile)
            target = Path(raw)
            generation = target if target.is_absolute() else profile.parent / target
            if (
                ".." in target.parts
                or not GENERATION.fullmatch(target.name)
                or generation.parent != profile.parent
            ):
                raise FrameError("Bootstrap profile must use a same-directory generation link")
            raw = read_link(generation)
            if not STORE_TARGET.fullmatch(raw):
                raise FrameError("Bootstrap generation escapes the selected logical store")
        physical = self.physical_target(raw)
        for relative in ("etc/profile.d/nix.sh",):
            source = self.resolve_store_path(raw + "/" + relative)
            if not source.is_file():
                raise FrameError(f"Bootstrap dependency is unavailable: {relative}")
        return raw, physical

    def _identity(self, *, reuse=False):
        argv = ["/usr/bin/python3", "-c", IDENTITY_SCRIPT, str(self.paths.store), str(os.getuid())]
        if reuse:
            return self.run(argv, check=False).returncode == 0
        return self.namespace_run(argv, source=False, check=False).returncode == 0

    def readiness(self, *, activation=False):
        """Read-only actual namespace check; metadata/active markers alone prove nothing."""
        if activation:
            self.activation_config_home()
            self.validate_wrapper()
        self._bootstrap_metadata()
        self.validate_profile()
        if not self._identity():
            raise FrameError("Cannot launch the selected home-backed /nix namespace")
        script = (
            'test -x "$1/bin/fish" && test -r "$2" && '
            '"$1/bin/fish" --version && nix --store local --version'
        )
        cert = self.verified_certificate()
        self.namespace_run(["/bin/bash", "-c", script, "readiness", self.profile, cert])
        self.validate_entry_tools(self.validate_profile())
        self.effective_configuration()
        return True

    def validate_entry_tools(self, logical):
        self.physical_target(logical)
        script = (
            "for name in fish bash python3 ssh-agent ssh-add; do "
            'if ! test -x "$1/bin/$name"; then '
            'printf "Missing required Frame executable: %s\\n" "$name" >&2; exit 1; '
            "fi; done"
        )
        self.namespace_run(
            ["/bin/bash", "-c", script, "frame-entry-tools", logical], profile=Path(logical)
        )

    def effective_configuration(self):
        result = self.namespace_run(["nix", "--store", "local", "config", "show", "--json"])
        try:
            settings = json.loads(result.stdout)
            required = {
                "build-users-group": "",
                "sandbox": True,
                "require-sigs": True,
                "substituters": ["https://cache.nixos.org"],
            }
            for key, expected in required.items():
                if settings[key]["value"] != expected:
                    raise FrameError(f"Unsafe effective Nix setting: {key}")
            features = settings["experimental-features"]["value"]
            if not {"nix-command", "flakes"}.issubset(features):
                raise FrameError("Required Nix command features are not effective")
            keys = settings["trusted-public-keys"]["value"]
            if "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" not in keys:
                raise FrameError("Default binary cache signing key is not effective")
        except (ValueError, KeyError, TypeError) as exc:
            raise FrameError("Cannot verify effective Nix configuration") from exc
        info = self.namespace_run(["nix", "--store", "local", "store", "info", "--json"])
        try:
            if json.loads(info.stdout)["url"] != "local":
                raise FrameError("Managed Nix does not use the selected local store")
        except (ValueError, KeyError, TypeError) as exc:
            raise FrameError("Cannot verify effective Nix store") from exc
        directory = self.namespace_run(
            ["nix", "--store", "local", "eval", "--raw", "--expr", "builtins.storeDir"]
        )
        if directory.stdout.strip() != "/nix/store":
            raise FrameError("Managed Nix does not use the logical /nix/store")
        return settings

    def activation_config_home(self):
        default = self.home / ".config"
        configured = self.environ.get("XDG_CONFIG_HOME", "")
        if configured and Path(configured) != default:
            raise FrameError("Activation requires unset XDG_CONFIG_HOME or <home>/.config")
        self.paths.check(default)
        shell = pwd.getpwuid(os.getuid()).pw_shell
        if Path(shell).name != "bash":
            raise FrameError("Automatic activation requires an account with the Bash login shell")
        return default

    def prerequisites(self):
        if platform.system() != "Linux":
            raise FrameError("Frame requires Linux user and mount namespaces")
        if platform.machine() not in ("aarch64", "arm64"):
            raise FrameError(
                "Fresh bootstrap supports aarch64 Linux only; no checked x86 installer"
            )
        for program in ("bash", "curl", "tar", "xz", "sha256sum", "git", "unshare"):
            if not shutil.which(program, path=self.environ.get("PATH")):
                raise FrameError(f"Missing host prerequisite: {program}; install it yourself")
        self.run(["unshare", "--user", "--map-root-user", "--mount", "/bin/true"])

    def _fetch_verified(self, url, expected, destination):
        self.paths.check(destination)
        self.downloader(url, destination)
        if digest(destination) != expected:
            destination.unlink()
            raise FrameError(f"Downloaded artifact checksum mismatch: {url}")

    def _bootstrap(self):
        if self.paths.metadata.exists():
            self._bootstrap_metadata()
            if not self._identity():
                raise FrameError(
                    "Existing bootstrap namespace failed; refusing to replace the store"
                )
            self.namespace_run(["nix", "--store", "local", "--version"])
            self.effective_configuration()
            return
        if self.paths.store.exists() or self.paths.store.is_symlink():
            raise FrameError("Unowned store already exists; refusing to overwrite it")
        self.prerequisites()
        for directory in (
            self.state / "downloads",
            self.state / "bin",
            self.paths.tmp,
            self.paths.bootstrap_home,
        ):
            self.paths.mkdir(directory)
        helper = self.state / "downloads/nix-user-chroot"
        archive = self.state / "downloads/nix.tar.xz"
        self._fetch_verified(HELPER_URL, HELPER_SHA256, helper)
        self._fetch_verified(NIX_URL, NIX_SHA256, archive)
        if self.paths.helper.exists() or self.paths.helper.is_symlink():
            raise FrameError("Existing bootstrap helper is not owned by this installation")
        with tempfile.TemporaryDirectory(prefix="installer-", dir=self.paths.tmp) as staging:
            installer = extract_installer(archive, staging)
            certificate, archive_path = installer_certificate(archive, installer)
            self.paths.atomic_bytes(self.certificate_path, certificate.read_bytes())
            certificate_record = {
                "path": str(self.certificate_path),
                "sha256": digest(self.certificate_path),
                "archive_path": archive_path,
            }
            self._install_certificate = certificate_record
            self.verified_certificate()
            self.paths.atomic_bytes(self.paths.helper, helper.read_bytes(), mode=0o700)
            self.paths.mkdir(self.paths.store / "etc/nix")
            self.paths.atomic_bytes(self.paths.store / "etc/nix/nix.conf", NIX_CONFIG.encode())
            if not self._identity():
                raise FrameError("Helper did not mount selected store at /nix")
            self.namespace_run(
                [
                    "/bin/bash",
                    "-c",
                    'test -w /nix && exec "$@"',
                    "installer",
                    "/bin/bash",
                    installer,
                    "--no-daemon",
                    "--no-channel-add",
                    "--no-modify-profile",
                ],
                source=False,
                env={
                    **self.environment(),
                    "HOME": str(self.paths.bootstrap_home),
                    "XDG_CONFIG_HOME": str(self.paths.bootstrap_home / ".config"),
                    "XDG_DATA_HOME": str(self.paths.bootstrap_home / ".local/share"),
                    "XDG_STATE_HOME": str(self.paths.bootstrap_home / ".local/state"),
                    "XDG_CACHE_HOME": str(self.paths.bootstrap_home / ".cache"),
                },
            )
        self.bootstrap_profile()
        self.paths.write_json(
            self.paths.metadata,
            {
                "schema": 1,
                "uid": os.getuid(),
                "home": str(self.home),
                "state": str(self.state),
                "helper_version": HELPER_VERSION,
                "nix_version": NIX_VERSION,
                "helper_sha256": HELPER_SHA256,
                "installer_sha256": NIX_SHA256,
                "certificate": certificate_record,
            },
        )
        self._install_certificate = None
        version = self.namespace_run(["nix", "--store", "local", "--version"])
        if NIX_VERSION not in version.stdout:
            raise FrameError("Installed Nix version does not match the checked release")
        self.effective_configuration()

    def wrapper_content(self):
        cli = self.repo / "frame/cli.py"
        argv = [
            "/usr/bin/python3",
            str(cli),
            "--home",
            str(self.home),
            "--state-dir",
            str(self.state),
        ]
        return ("#!/bin/sh\nexec " + shlex.join(argv) + ' "$@"\n').encode()

    def validate_wrapper(self):
        cli = self.repo / "frame/cli.py"
        if not cli.is_file() or not os.access("/usr/bin/python3", os.X_OK):
            raise FrameError("Host wrapper requires its stable checkout and /usr/bin/python3")
        path = self.paths.check(self.paths.wrapper)
        info = path.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or info.st_mode & 0o022
            or not os.access(path, os.X_OK)
            or path.read_bytes() != self.wrapper_content()
        ):
            raise FrameError(
                "Host wrapper is missing, changed, or not an owned executable regular file"
            )
        return path

    def install_wrapper(self):
        content = self.wrapper_content()
        path = self.paths.check(self.paths.wrapper)
        if path.exists():
            if not path.is_file() or path.read_bytes() != content:
                raise FrameError(f"Wrapper conflict; preserve or move {path} explicitly")
            return
        self.paths.atomic_bytes(path, content, mode=0o755)

    def select_sources(self, pin=None, overrides=None):
        config = self.home / ".config/frame-cli"
        self.paths.check(config)
        pin_path = Path(pin) if pin else config / "nixpkgs.json"
        if not pin and not os.path.lexists(pin_path):
            pin_path = self.repo / "frame/nixpkgs.json"
        try:
            selection = json.loads(pin_path.read_text())
        except (OSError, ValueError) as exc:
            raise FrameError(f"Cannot read selected nixpkgs pin: {pin_path}: {exc}") from exc
        if (
            not isinstance(selection, dict)
            or set(selection) != {"rev", "sha256"}
            or not re.fullmatch(r"[a-f0-9]{40}", str(selection.get("rev", "")))
            or not re.fullmatch(r"sha256-[A-Za-z0-9+/]{43}=", str(selection.get("sha256", "")))
        ):
            raise FrameError("Selected nixpkgs pin requires a complete rev and sha256 NAR hash")
        override_path = Path(overrides) if overrides else config / "overrides.nix"
        if (overrides or os.path.lexists(override_path)) and not override_path.is_file():
            raise FrameError("Selected override must be a readable regular Nix file")
        return selection, pin_path, override_path if override_path.is_file() else None

    def _build(self, pin=None, overrides=None):
        selection, _pin_path, override_path = self.select_sources(pin, overrides)
        self.paths.mkdir(self.state / "sources")
        # Immutable input snapshots ensure build-info and the actual build use the same bytes.
        pin_bytes = (json.dumps(selection, sort_keys=True) + "\n").encode()
        pin_copy = self.state / "sources" / (hashlib.sha256(pin_bytes).hexdigest() + ".json")
        self.paths.atomic_bytes(pin_copy, pin_bytes)
        argv = [
            "nix-build",
            self.repo / "frame/environment.nix",
            "--no-out-link",
            "--argstr",
            "system",
            "aarch64-linux",
            "--argstr",
            "nixpkgsPin",
            str(pin_copy),
        ]
        if override_path:
            data = override_path.read_bytes()
            copied = self.state / "sources" / (hashlib.sha256(data).hexdigest() + ".nix")
            self.paths.atomic_bytes(copied, data)
            argv += ["--argstr", "overrides", str(copied)]
        result = self.namespace_run(argv)
        lines = result.stdout.strip().splitlines()
        if len(lines) != 1:
            raise FrameError("Build did not return exactly one environment store path")
        candidate = lines[0]
        self.physical_target(candidate)
        return candidate

    def _activation(self):
        if not (self.state / "activation.json").exists():
            return None
        self.activation_config_home()
        return importlib.import_module("frame.activation")

    def _publish(self, candidate, *, rollback=False):
        self.validate_entry_tools(candidate)
        plugin = self._activation()
        prepared = None
        if plugin:
            plugin.reconcile(self)
            prepared = plugin.prepare(self, candidate)
        if rollback:
            self.namespace_run(
                ["nix-env", "--profile", self.profile, "--switch-generation", candidate]
            )
        elif not self.profile.is_symlink() or self.validate_profile() != candidate:
            self.namespace_run(["nix-env", "--profile", self.profile, "--set", candidate])
        self.validate_profile()
        if plugin:
            plugin.publish(self, prepared)

    def install(self, pin=None, overrides=None):
        with self.lock():
            self._bootstrap()
            self.install_wrapper()
            if self.profile.is_symlink():
                self.readiness()
                return
            candidate = self._build(pin, overrides)
            self._publish(candidate)

    def update(self, pin=None, overrides=None):
        with self.lock():
            plugin = self._activation()
            if plugin:
                plugin.reconcile(self)
            self.readiness()
            candidate = self._build(pin, overrides)
            self._publish(candidate)

    def rollback(self):
        with self.lock():
            plugin = self._activation()
            if plugin:
                plugin.reconcile(self)
            self.readiness()
            current = int(GENERATION.fullmatch(os.readlink(self.profile))[1])
            previous = []
            for path in self.state.iterdir():
                match = GENERATION.fullmatch(path.name)
                if match and int(match[1]) < current:
                    previous.append((int(match[1]), path))
            if not previous:
                raise FrameError("No previous profile generation exists")
            number, generation = max(previous)
            candidate = self.validate_profile(generation)
            self.validate_entry_tools(candidate)
            plugin = self._activation()
            prepared = None
            if plugin:
                plugin.reconcile(self)
                prepared = plugin.prepare(self, candidate)
            self.namespace_run(
                ["nix-env", "--profile", self.profile, "--switch-generation", str(number)]
            )
            self.validate_profile()
            if plugin:
                plugin.publish(self, prepared)

    def enter(self, command=None):
        self._bootstrap_metadata()
        self.validate_profile()
        verified_nested = self.environ.get("FRAME_CLI_ACTIVE") == "1" and self._identity(reuse=True)
        if not verified_nested and not self._identity():
            raise FrameError("Cannot enter the selected home-backed /nix namespace")
        env = self.environment()
        if not command and os.isatty(0) and os.isatty(1):
            plugin = importlib.import_module("frame.agent")
            env = plugin.interactive_entry(self, env)
        result = self.namespace_run(
            command or [self.profile / "bin/fish", "-l"],
            env=env,
            capture_output=False,
            check=False,
            reuse=verified_nested,
        )
        return 128 - result.returncode if result.returncode < 0 else result.returncode

    def make_agent_manager(self):
        module = importlib.import_module("frame.agent")
        self._bootstrap_metadata()
        return module.manager_for_frame(self)

    def status(self):
        data = {
            "home": str(self.home),
            "state": str(self.state),
            "store": str(self.paths.store),
            "profile": str(self.profile),
            "ready": False,
            "activation": (self.state / "activation.json").exists(),
        }
        try:
            self.readiness()
            generation = self.validate_profile()
            data.update(
                ready=True,
                helper_version=HELPER_VERSION,
                nix_version=NIX_VERSION,
                generation=int(GENERATION.fullmatch(os.readlink(self.profile))[1]),
            )
            build_info = self.resolve_store_path(generation + "/share/frame-cli/build-info.json")
            data["build_info"] = json.loads(build_info.read_text())
            if data["activation"]:
                module = importlib.import_module("frame.activation")
                data["activation_status"] = module.status(self)
        except (FrameError, OSError, ValueError) as exc:
            data["error"] = str(exc)
        return data
