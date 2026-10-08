"""Rootless fixture/validator tests. Real loader execution is a required Nix CI job."""

import importlib.util
import os
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tests"))
import host_fontconfig as fonts  # noqa: E402
import terminal_scenarios as terminals  # noqa: E402


@pytest.fixture
def fixture(tmp_path):
    return terminals.prepare_fixture(tmp_path / "test root with spaces", REPO)


def artifact(tmp_path):
    root = tmp_path / "font artifact with spaces"
    (root / "fonts/family").mkdir(parents=True)
    (root / "fonts/family/Cozette.ttf").write_bytes(b"synthetic font bytes")
    (root / "bell-window-system.oga").write_bytes(b"OggS bell")
    (root / "fontconfig.conf").write_bytes((REPO / "frame/templates/fontconfig.conf").read_bytes())
    return root


def test_terminal_generated_paths_and_commands(fixture):
    assert fixture.ghostty.is_symlink()
    assert fixture.alacritty.is_symlink()
    assert "checkout with spaces" in str(fixture.alacritty.resolve())
    import tomllib

    main = tomllib.loads(fixture.alacritty.read_text())
    machine = tomllib.loads((fixture.alacritty.parent / "machine.toml").read_text())
    assert main["general"]["import"] == ["~/.config/alacritty/machine.toml"]
    assert "shell" not in main.get("terminal", {})
    assert main["font"]["normal"] == {"family": "Cozette", "style": "Regular"}
    assert len(main["keyboard"]["bindings"]) == 2
    assert machine == {
        "terminal": {"shell": {"program": str(fixture.wrapper), "args": fixture.args}}
    }
    ghostty = (fixture.ghostty.parent / "machine").read_text()
    assert "initial-command" not in ghostty
    assert f"bell-audio-path = {fixture.bell}" in ghostty
    assert fixture.bell.read_bytes().startswith(b"OggS")
    assert str(fixture.home) == fixture.env["HOME"]
    assert fixture.env["XDG_CONFIG_HOME"] == str(fixture.home / ".config")


def test_rendered_command_preserves_spaced_wrapper_argv(fixture):
    fixture.wrapper.write_text(
        terminals.argv_check_script(fixture) + "read -r ignored\nprintf 'WRAPPER_ARGV_OK\\n'\n"
    )
    fixture.wrapper.chmod(0o755)
    command = next(
        line.partition("=")[2].strip()
        for line in (fixture.ghostty.parent / "machine").read_text().splitlines()
        if line.startswith("command =")
    )
    output = terminals.command_pty_scenario(
        ["/bin/sh", "-c", command], fixture.env, input_bytes=b"proceed\n"
    )
    assert b"WRAPPER_ARGV_OK" in output


def test_terminal_command_failure_is_not_success(fixture):
    with pytest.raises(terminals.TerminalScenarioError, match="exited 19"):
        terminals.command_pty_scenario(["/bin/sh", "-c", "exit 19"], fixture.env, input_bytes=b"")


def test_missing_real_loader_is_a_failure(fixture):
    with pytest.raises(terminals.TerminalScenarioError, match="required loader executable absent"):
        terminals.ghostty_deployed_config_validation("/absent-frame-loader", fixture)


def test_effective_config_retains_repeated_bindings():
    parsed = terminals.effective_values(
        "# comment\nfont-family = Cozette\nkeybind = a=b\nkeybind = c=d\n"
    )
    assert parsed == {"font-family": ["Cozette"], "keybind": ["a=b", "c=d"]}
    with pytest.raises(terminals.TerminalScenarioError, match="invalid effective"):
        terminals.effective_values("invalid output")


def test_font_artifact_regular_bytes(tmp_path):
    root = artifact(tmp_path)
    paths = fonts.validate_artifact(root)
    assert len(paths) == 3
    assert all(not path.is_symlink() for path in paths)


@pytest.mark.parametrize("target", ["/nix/store/absent/Cozette.ttf", "missing.ttf", "../family"])
def test_font_artifact_rejects_all_links(tmp_path, target):
    root = artifact(tmp_path)
    (root / "fonts/namespace-only.ttf").symlink_to(target)
    with pytest.raises(fonts.FontArtifactError, match="symlink"):
        fonts.validate_artifact(root)


def test_font_artifact_rejects_root_link_and_special_file(tmp_path):
    root = artifact(tmp_path)
    alias = tmp_path / "alias"
    alias.symlink_to(root, target_is_directory=True)
    with pytest.raises(fonts.FontArtifactError, match="regular directory"):
        fonts.validate_artifact(alias)
    os.mkfifo(root / "fonts/fifo")
    with pytest.raises(fonts.FontArtifactError, match="special file"):
        fonts.validate_artifact(root)


@pytest.mark.parametrize(
    "remove", ["fonts/family/Cozette.ttf", "bell-window-system.oga", "fontconfig.conf"]
)
def test_font_artifact_requires_complete_generation(tmp_path, remove):
    root = artifact(tmp_path)
    (root / remove).unlink()
    with pytest.raises(fonts.FontArtifactError):
        fonts.validate_artifact(root)


def test_host_font_job_refuses_existing_nix(monkeypatch):
    monkeypatch.setattr(fonts.os.path, "lexists", lambda path: path == "/nix")
    with pytest.raises(fonts.FontArtifactError, match="absent /nix"):
        fonts.require_no_nix()


def test_fontconfig_configuration_is_isolated(tmp_path, monkeypatch):
    root = artifact(tmp_path)
    monkeypatch.setenv("FONTCONFIG_SYSROOT", "/nix")
    monkeypatch.setenv("FONTCONFIG_FILE", "/etc/fonts/fonts.conf")
    env = fonts.fontconfig_environment(root, tmp_path / "isolated host home")
    assert "FONTCONFIG_SYSROOT" not in env
    config = Path(env["FONTCONFIG_FILE"]).read_text()
    assert str(root / "fonts") in config
    assert "@FONT_DIR@" not in config
    assert "/etc/fonts" not in config
    assert "<include" not in config
    assert "Iosevka" in config and "Noto Sans CJK JP" in config


def test_fontconfig_records_require_exact_families():
    records = fonts.parse_font_records("Cozette,Other Alias\t/tmp/font.ttf\n")
    assert records == [({"Cozette", "Other Alias"}, Path("/tmp/font.ttf"))]
    assert "Cozette" in records[0][0]
    assert "Cozette Substitution" not in records[0][0]
    with pytest.raises(fonts.FontArtifactError, match="invalid Fontconfig"):
        fonts.parse_font_records("invalid")


def test_host_discovery_rejects_family_substitution(tmp_path, monkeypatch):
    root = artifact(tmp_path)
    font = root / "fonts/family/Cozette.ttf"
    monkeypatch.setattr(fonts, "require_no_nix", lambda: None)

    def fake_fc(argv, env):
        if argv[0] == "fc-list":
            return f"Other Font\t{font}\n"
        return ""

    monkeypatch.setattr(fonts, "fc_run", fake_fc)
    with pytest.raises(fonts.FontArtifactError, match="exported family not discovered: Cozette"):
        fonts.host_fontconfig_discovery_scenario(root)


def test_host_discovery_exact_matches_and_negative_namespace_link(tmp_path, monkeypatch):
    root = artifact(tmp_path)
    font = root / "fonts/family/Cozette.ttf"
    monkeypatch.setattr(fonts, "require_no_nix", lambda: None)

    def fake_fc(argv, env):
        if "negative fontconfig" in env["HOME"]:
            return ""
        if argv[0] == "fc-list":
            return "".join(f"{family}\t{font}\n" for family in fonts.EXPECTED_FAMILIES)
        if argv[0] == "fc-match":
            return f"{argv[-1]}\t{font}\n"
        return ""

    monkeypatch.setattr(fonts, "fc_run", fake_fc)
    result = fonts.host_fontconfig_discovery_scenario(root)
    assert set(result["matches"]) == set(fonts.EXPECTED_FAMILIES)
    assert result["namespaceLinkRejected"]


def test_standalone_font_validator_has_no_frame_dependency():
    source = (REPO / "tests/host_fontconfig.py").read_text()
    assert "from frame" not in source and "import frame" not in source
    assert importlib.util.find_spec("host_fontconfig") is not None
