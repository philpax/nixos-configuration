"""Validate copied Frame assets with host Fontconfig, independently of Nix."""

from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
import tempfile
from pathlib import Path
from xml.sax.saxutils import escape

EXPECTED_FAMILIES = (
    "Cozette",
    "Iosevka",
    "Noto Sans",
    "Noto Serif",
    "Noto Color Emoji",
    "MesloLGS Nerd Font",
)
FONT_SUFFIXES = {".ttf", ".otf", ".otb", ".ttc", ".otc", ".bdf", ".pcf", ".gz"}


class FontArtifactError(RuntimeError):
    pass


def require_no_nix() -> None:
    if os.path.lexists("/nix"):
        raise FontArtifactError(
            "host-font validation requires an absent /nix (never hide a live store)"
        )


def validate_artifact(root: Path) -> list[Path]:
    """Reject links, special files and empty exports before following any entry."""
    root = Path(root).absolute()
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise FontArtifactError(f"artifact root is not a regular directory: {root}")
    files = []
    pending = [root]
    while pending:
        directory = pending.pop()
        for entry in sorted(directory.iterdir()):
            mode = entry.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise FontArtifactError(
                    f"artifact symlink is not host-visible regular bytes: {entry}"
                )
            if stat.S_ISDIR(mode):
                pending.append(entry)
            elif stat.S_ISREG(mode):
                files.append(entry)
            else:
                raise FontArtifactError(f"artifact contains a special file: {entry}")
    fonts = [p for p in files if p.is_relative_to(root / "fonts") and p.suffix in FONT_SUFFIXES]
    if not fonts:
        raise FontArtifactError("artifact contains no font bytes")
    bell = root / "bell-window-system.oga"
    if bell not in files or bell.stat().st_size == 0:
        raise FontArtifactError("artifact contains no regular Ocean bell bytes")
    template = root / "fontconfig.conf"
    if template not in files or "@FONT_DIR@" not in template.read_text():
        raise FontArtifactError("artifact lacks the relocatable Fontconfig template")
    return files


def fontconfig_environment(root: Path, home: Path) -> dict[str, str]:
    """Load only the copied font directory and the production family preferences."""
    home.mkdir(parents=True, exist_ok=True)
    config = home / "fonts.conf"
    template = (
        (root / "fontconfig.conf").read_text().replace("@FONT_DIR@", escape(str(root / "fonts")))
    )
    template = template.replace(
        "</fontconfig>", f"<cachedir>{escape(str(home / 'cache'))}</cachedir></fontconfig>"
    )
    config.write_text(template)
    env = dict(os.environ)
    for name in ("FONTCONFIG_SYSROOT", "FONTCONFIG_USE_MMAP", "FC_DEBUG"):
        env.pop(name, None)
    env.update(
        HOME=str(home),
        XDG_CONFIG_HOME=str(home / ".config"),
        XDG_DATA_HOME=str(home / ".local/share"),
        XDG_CACHE_HOME=str(home / "cache"),
        FONTCONFIG_FILE=str(config),
        FONTCONFIG_PATH=str(home),
    )
    return env


def fc_run(argv: list[str], env: dict[str, str]) -> str:
    try:
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=120)
    except FileNotFoundError as exc:
        raise FontArtifactError(f"required host Fontconfig command is absent: {argv[0]}") from exc
    if result.returncode or result.stderr.strip():
        raise FontArtifactError(f"{argv!r}: {result.returncode}: {result.stderr}")
    return result.stdout


def parse_font_records(text: str) -> list[tuple[set[str], Path]]:
    records = []
    for line in text.splitlines():
        families, separator, filename = line.partition("\t")
        if not separator:
            raise FontArtifactError(f"invalid Fontconfig record: {line!r}")
        records.append((set(families.split(",")), Path(filename)))
    return records


def discover(root: Path, home: Path) -> tuple[dict[str, str], list[tuple[set[str], Path]]]:
    env = fontconfig_environment(root, home)
    fc_run(["fc-cache", "-f", str(root / "fonts")], env)
    records = parse_font_records(fc_run(["fc-list", "--format", "%{family}\t%{file}\n"], env))
    return env, records


def host_fontconfig_discovery_scenario(root: Path, *, assert_no_nix: bool = True) -> dict:
    if assert_no_nix:
        require_no_nix()
    root = Path(root).absolute()
    files = validate_artifact(root)
    with tempfile.TemporaryDirectory(prefix="frame host fontconfig ") as temporary:
        temporary = Path(temporary)
        env, records = discover(root, temporary / "positive")
        font_root = (root / "fonts").resolve()
        for _, filename in records:
            if not filename.resolve().is_relative_to(font_root) or not filename.is_file():
                raise FontArtifactError(f"Fontconfig used a font outside the artifact: {filename}")
        matches = {}
        for family in EXPECTED_FAMILIES:
            if not any(family in families for families, _ in records):
                raise FontArtifactError(f"exported family not discovered: {family}")
            matched = parse_font_records(
                fc_run(["fc-match", "--format", "%{family}\t%{file}\n", family], env)
            )
            if len(matched) != 1 or family not in matched[0][0]:
                raise FontArtifactError(
                    f"fc-match substituted another family for {family}: {matched}"
                )
            filename = matched[0][1]
            if not filename.resolve().is_relative_to(font_root) or not filename.is_file():
                raise FontArtifactError(f"fc-match used non-artifact bytes: {filename}")
            matches[family] = str(filename.relative_to(root))
        negative = temporary / "negative artifact"
        (negative / "fonts").mkdir(parents=True)
        (negative / "fonts/cozette.ttf").symlink_to("/nix/store/absent-frame-font/cozette.ttf")
        (negative / "bell-window-system.oga").write_bytes(b"negative bell")
        (negative / "fontconfig.conf").write_bytes((root / "fontconfig.conf").read_bytes())
        try:
            validate_artifact(negative)
        except FontArtifactError:
            pass
        else:
            raise FontArtifactError("validator accepted a namespace-only font link")
        _, negative_records = discover(negative, temporary / "negative fontconfig")
        if any(set(EXPECTED_FAMILIES) & families for families, _ in negative_records):
            raise FontArtifactError("namespace-link fixture discovered an expected font family")
    return {"files": len(files), "matches": matches, "namespaceLinkRejected": True}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    args = parser.parse_args()
    print(json.dumps(host_fontconfig_discovery_scenario(args.artifact), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
