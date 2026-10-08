"""Package/output equivalence and bounded Frame Nix profile checks."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
NIX = shutil.which("nix")
NIX_BUILD_TESTS = os.environ.get("FRAME_NIX_BUILD_TESTS") == "1"


def nix_eval(expression, *, check=True):
    if not NIX:
        pytest.skip("Nix is required for package expression tests")
    result = subprocess.run(
        [
            NIX,
            "--extra-experimental-features",
            "nix-command",
            "eval",
            "--impure",
            "--json",
            "--expr",
            expression,
        ],
        cwd=REPO,
        text=True,
        capture_output=True,
        timeout=240,
        check=False,
    )
    if check:
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
    return result


def nix_build(expression):
    if not NIX:
        pytest.skip("Nix is required for profile builds")
    result = subprocess.run(
        [
            NIX,
            "--extra-experimental-features",
            "nix-command",
            "build",
            "--impure",
            "--no-link",
            "--print-out-paths",
            "--expr",
            expression,
        ],
        cwd=REPO,
        text=True,
        capture_output=True,
        timeout=900,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return Path(result.stdout.strip())


@pytest.mark.parametrize("system", ["x86_64-linux", "aarch64-linux"])
def test_nixos_cli_lists_and_fonts_match_baseline(system):
    # The fixture contains original expressions, independent of extracted functions.
    data = nix_eval(f'''
      let e = import ./frame/environment.nix {{ system = "{system}"; }};
      in import ./tests/nix/cli-packages.nix {{ system = "{system}"; nixpkgs = e.source; }}
    ''')
    assert data["nixos_cli_lists_match_baseline"]
    assert data["nixos_cli_service_options_unchanged"]
    assert data["nixos_fonts_match_baseline"]
    assert [p["output"] for p in data["lists"]["dev"]][-6:] == [
        "bin",
        "dev",
        "out",
        "out",
        "out",
        "libgcc",
    ]


def test_frame_package_metadata_aarch64():
    data = nix_eval("""
      let e = import ./frame/environment.nix {};
      in {
        info = e.buildInfo;
        drvPath = e.profile.drvPath;
        expected = map (p: p.outPath) e.defaultCliPackages;
        expectedFonts = map (p: p.outPath) e.defaultFontPackages;
        runtime = map (p: p.outPath) e.runtimePackages;
        priorities = map (p: p.meta.priority or 5) e.profile.paths;
      }
    """)
    info = data["info"]
    assert info["system"] == "aarch64-linux"
    assert info["nixpkgs"]["rev"] == json.loads((REPO / "frame/nixpkgs.json").read_text())["rev"]
    outputs = info["cliPackages"]
    assert [p["path"] for p in outputs] == list(dict.fromkeys(data["expected"]))
    assert [p["path"] for p in info["fontPackages"]] == list(dict.fromkeys(data["expectedFonts"]))
    assert set(data["runtime"]) <= {p["path"] for p in outputs}
    assert any(p["name"].startswith("helix-") and "-steel-8d189f4" in p["name"] for p in outputs)
    assert any(p["name"].startswith("openssl-") and p["output"] == "dev" for p in outputs)
    assert len({p["reference"] for p in outputs}) == len(outputs)
    assert all(p["reference"].startswith("fonts/") for p in info["assets"]["fonts"])
    assert info["assets"]["bell"]["reference"] == "bell"
    assert info["assets"]["bell"]["relativePath"].endswith("/bell-window-system.oga")
    assert data["drvPath"].endswith(".drv")
    assert 4 in data["priorities"] and 6 in data["priorities"]
    assert info["fontPackages"] == info["assets"]["fonts"]
    companions = [(font, font.get("companions", [])) for font in info["fontPackages"]]
    assert sum(len(records) for _, records in companions) == 1
    dejavu, records = next((font, records) for font, records in companions if records)
    assert dejavu["name"].startswith("dejavu-fonts-")
    assert records[0]["name"].startswith("dejavu-fonts-minimal-")
    assert records[0]["reference"].startswith(
        "font-companions/" + Path(dejavu["reference"]).name + "-"
    )


def test_font_companions_generated_only_from_final_selected_outputs():
    data = nix_eval("""
      let
        base = import ./frame/environment.nix { system = "x86_64-linux"; };
        removed = import ./frame/environment.nix {
          system = "x86_64-linux";
          overrides = { pkgs, cliPackages, fontPackages }: {
            inherit cliPackages;
            fontPackages = builtins.filter (p: p.outPath != pkgs.dejavu_fonts.outPath) fontPackages;
          };
        };
        custom = import ./frame/environment.nix {
          system = "x86_64-linux";
          overrides = { pkgs, cliPackages, ... }: {
            inherit cliPackages;
            fontPackages = [ (pkgs.cozette.overrideAttrs (old: {
              passthru = (old.passthru or {}) // {
                frameFontCompanions = [ pkgs.dejavu_fonts.minimal ];
              };
            })) ];
          };
        };
      in {
        original = map (p: p.outPath) base.defaultFontPackages;
        selected = map (p: p.path) base.assetManifest.fonts;
        removed = removed.assetManifest.fonts;
        custom = custom.assetManifest.fonts;
        minimal = base.pkgs.dejavu_fonts.minimal.outPath;
      }
    """)
    assert data["selected"] == data["original"]
    assert all(not font.get("companions") for font in data["removed"])
    assert len(data["custom"]) == 1
    assert data["custom"][0]["companions"][0]["path"] == data["minimal"]


def test_invalid_font_companion_passthru_rejected():
    result = nix_eval(
        """
      (import ./frame/environment.nix {
        system = "x86_64-linux";
        overrides = { pkgs, cliPackages, ... }: {
          inherit cliPackages;
          fontPackages = [ (pkgs.cozette.overrideAttrs (old: {
            passthru = (old.passthru or {}) // { frameFontCompanions = [ "not a derivation" ]; };
          })) ];
        };
      }).assetManifest
    """,
        check=False,
    )
    assert result.returncode != 0
    assert "frameFontCompanions must be a derivation list" in result.stderr


def test_actual_dejavu_export_from_selected_x86_source(tmp_path):
    if not NIX_BUILD_TESTS:
        pytest.skip("set FRAME_NIX_BUILD_TESTS=1 to run actual DejaVu profile export")
    from types import SimpleNamespace

    from frame.activation import Activation

    profile = nix_build("""
      (import ./frame/environment.nix {
        system = "x86_64-linux";
        overrides = { pkgs, ... }: {
          cliPackages = import ./common-all/packages/runtime.nix { inherit pkgs; };
          fontPackages = [ pkgs.dejavu_fonts ];
        };
      }).profile
    """)
    manifest = json.loads((profile / "share/frame-cli/assets.json").read_text())
    info = json.loads((profile / "share/frame-cli/build-info.json").read_text())
    assert info["fontPackages"] == manifest["fonts"]
    assert info["assets"] == manifest
    assert len(manifest["fonts"]) == 1
    selected = manifest["fonts"][0]
    companion = selected["companions"][0]
    source = Path(selected["path"]) / "share/fonts/truetype/DejaVuSans.ttf"
    minimal = Path(companion["path"]) / "share/fonts/truetype/DejaVuSans.ttf"
    assert source.is_symlink() and source.resolve() == minimal
    assert (
        profile / "share/frame-cli/assets" / companion["reference"]
    ).resolve() == minimal.parents[3]
    requisites = subprocess.run(
        ["nix-store", "--query", "--requisites", str(profile)],
        check=True,
        text=True,
        capture_output=True,
        timeout=60,
    ).stdout.splitlines()
    assert companion["path"] in requisites
    home = tmp_path / "home"
    home.mkdir()
    frame = SimpleNamespace(home=home, state=home / "state", repo=REPO, environ={"HOME": str(home)})
    activation = Activation(frame, source_resolver=lambda path: path.resolve(strict=True))
    generation = activation.export(str(profile))
    destination = activation.assets / "generations" / generation
    exported = destination / "fonts" / Path(selected["reference"]).name / "truetype/DejaVuSans.ttf"
    assert exported.read_bytes() == minimal.read_bytes()
    assert not any(path.is_symlink() for path in destination.rglob("*"))


@pytest.mark.parametrize(
    "pin",
    [
        '{ rev = "short"; sha256 = "invalid"; }',
        '{ rev = "151fa4e8ddfdd8dd25d945ad94ed54a13de9f6e4"; }',
        "[]",
    ],
)
def test_invalid_source_pin_rejected(pin):
    result = nix_eval(
        f"(import ./frame/environment.nix {{ nixpkgsPin = {pin}; }}).drvPath", check=False
    )
    assert result.returncode != 0
    assert "pin must contain" in result.stderr


@pytest.mark.parametrize(
    ("override", "message"),
    [
        ("{ cliPackages = []; fontPackages = []; }", "overrides must be a function"),
        ("args: []", "derivation lists"),
        ('args: { cliPackages = [ "not a derivation" ]; fontPackages = []; }', "derivation lists"),
        ("args: { cliPackages = []; fontPackages = []; }", "removed required entry/runtime"),
        (
            "{ pkgs, cliPackages, fontPackages }: {"
            " cliPackages = builtins.filter (p: p.outPath != pkgs.python3.outPath) cliPackages;"
            " inherit fontPackages; }",
            "removed required entry/runtime",
        ),
        ('args: throw "intentional override failure"', "intentional override failure"),
    ],
)
def test_invalid_package_override_rejected(override, message):
    result = nix_eval(
        f"(import ./frame/environment.nix {{ overrides = ({override}); }}).drvPath", check=False
    )
    assert result.returncode != 0
    assert message in result.stderr


def test_invalid_override_file_rejected(tmp_path):
    override_file = tmp_path / "not-a-function.nix"
    override_file.write_text("{ cliPackages = []; fontPackages = []; }")
    result = nix_eval(
        "(import ./frame/environment.nix { overrides = "
        f"(builtins.toPath {json.dumps(str(override_file))}); }}).drvPath",
        check=False,
    )
    assert result.returncode != 0
    assert "overrides must be a function" in result.stderr


def test_frame_file_override_manifest_and_source():
    data = nix_eval("""
      let e = import ./frame/environment.nix {
        system = "x86_64-linux";
        overrides = ./frame/example-overrides.nix;
      };
      in { info = e.buildInfo; removed = e.pkgs.tldr.outPath; added = e.pkgs.hello.outPath; }
    """)
    outputs = {p["path"] for p in data["info"]["cliPackages"]}
    assert data["removed"] not in outputs
    assert data["added"] in outputs
    override = data["info"]["overrides"]
    assert override["kind"] == "file"
    assert override["source"] == "overrides.nix"
    assert (
        override["sha256"]
        == hashlib.sha256((REPO / "frame/example-overrides.nix").read_bytes()).hexdigest()
    )


@pytest.fixture(scope="module")
def lightweight_profile():
    if not NIX_BUILD_TESTS:
        pytest.skip("set FRAME_NIX_BUILD_TESTS=1 to run real lightweight profile builds")
    return nix_build("(import ./tests/nix/lightweight-profile.nix {}).profile")


def test_pinned_fish_readiness_has_no_home_writes(lightweight_profile, tmp_path):
    from types import SimpleNamespace

    from frame.core import Frame

    home = tmp_path / "untouched home"
    home.mkdir()
    env = {
        **os.environ,
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local/share"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "XDG_STATE_HOME": str(home / ".local/state"),
    }
    calls = []

    def run_readiness(argv):
        calls.append(argv)
        if "readiness" in argv:
            marker = argv.index("readiness")
            return subprocess.run(
                [str(lightweight_profile / "bin/bash"), *argv[1 : marker + 1]]
                + [
                    str(lightweight_profile),
                    str(lightweight_profile / "etc/ssl/certs/ca-bundle.crt"),
                ],
                env={**env, "PATH": str(lightweight_profile / "bin") + ":" + env["PATH"]},
                check=True,
                capture_output=True,
                text=True,
            )

    frame = SimpleNamespace(
        profile=lightweight_profile,
        _bootstrap_metadata=lambda: None,
        validate_profile=lambda: str(lightweight_profile),
        _identity=lambda: True,
        verified_certificate=lambda: lightweight_profile / "etc/ssl/certs/ca-bundle.crt",
        namespace_run=run_readiness,
        validate_entry_tools=lambda _logical: None,
        effective_configuration=lambda: None,
    )
    assert Frame.readiness(frame)
    assert any("readiness" in argv for argv in calls)
    assert not list(home.rglob("*")), "readiness must not initialize fish's user configuration"


def test_cli_profile_compiler_commands(lightweight_profile):
    check = nix_build("(import ./tests/nix/lightweight-profile.nix {}).compilerCheck")
    assert check.is_file()
    assert (lightweight_profile / "bin/cc").resolve() == (lightweight_profile / "bin/gcc").resolve()


def test_cli_profile_development_outputs(lightweight_profile):
    info = json.loads((lightweight_profile / "share/frame-cli/build-info.json").read_text())
    info_dir = lightweight_profile / "share/frame-cli"
    manifest = json.loads((info_dir / "output-manifest.json").read_text())
    assert manifest == info["cliPackages"]
    selected_dev = next(
        p for p in manifest if p["name"].startswith("openssl-") and p["output"] == "dev"
    )
    assert (lightweight_profile / "include/openssl/crypto.h").is_file()
    assert (lightweight_profile / "lib/pkgconfig/openssl.pc").is_file()
    for selected in manifest:
        reference = lightweight_profile / "share/frame-cli/outputs" / selected["reference"]
        assert reference.is_symlink()
        assert str(reference.resolve()) == selected["path"]
    requisites = subprocess.run(
        ["nix-store", "--query", "--requisites", str(lightweight_profile)],
        text=True,
        capture_output=True,
        check=True,
    ).stdout.splitlines()
    assert selected_dev["path"] in requisites
    assert (lightweight_profile / "share/frame-cli/nixpkgs").is_symlink()
    assert (lightweight_profile / "share/frame-cli/assets/fonts").is_dir()
    bell = info["assets"]["bell"]
    assert (
        lightweight_profile / "share/frame-cli/assets" / bell["reference"] / bell["relativePath"]
    ).is_file()


def test_unsupported_package_collision_fails(lightweight_profile):
    result = subprocess.run(
        [
            NIX,
            "--extra-experimental-features",
            "nix-command",
            "build",
            "--impure",
            "--no-link",
            "--expr",
            """
              (import ./tests/nix/lightweight-profile.nix {
                extraOverride = { pkgs, cliPackages, fontPackages }:
                  let collision = name: pkgs.runCommand name {} ''
                    mkdir -p "$out/bin"
                    echo ${name} > "$out/bin/frame-collision"
                  '';
                  in {
                    cliPackages = cliPackages ++ [ (collision "first") (collision "second") ];
                    inherit fontPackages;
                  };
              }).profile
            """,
        ],
        cwd=REPO,
        text=True,
        capture_output=True,
        timeout=240,
        check=False,
    )
    assert result.returncode != 0
    assert "collision" in result.stderr


def test_frame_package_override_scenario(lightweight_profile):
    changed = nix_build("""
      (import ./tests/nix/lightweight-profile.nix {
        extraOverride = { pkgs, cliPackages, fontPackages }: {
          cliPackages = builtins.filter (p: p != pkgs.hello) cliPackages ++ [ pkgs.jq ];
          inherit fontPackages;
        };
      }).profile
    """)
    assert changed != lightweight_profile
    assert (changed / "bin/jq").is_file()
    assert not (changed / "bin/hello").exists()
    info = json.loads((changed / "share/frame-cli/build-info.json").read_text())
    assert any(p["name"].startswith("jq-") for p in info["cliPackages"])
    assert not any(p["name"].startswith("hello-") for p in info["cliPackages"])
