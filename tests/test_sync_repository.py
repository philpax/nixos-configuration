"""Regression checks against the checked-out repository, not duplicate fixtures."""

import re
from pathlib import Path

import pytest

import sync
from sync_workflow import collect_links

REPO = Path(sync.__file__).resolve().parent
EXPECTED_TARGETS = {
    "common-ai",
    "common-all",
    "common-desktop",
    "common-dev",
    "common-dev-desktop",
    "frame",
    "jinroh",
    "mindgame",
    "paprika",
    "patlabor",
    "redline",
}
EXPECTED_DOTFILES_TARGETS = {
    "common-all",
    "common-desktop",
    "common-dev",
    "common-dev-desktop",
    "mindgame",
    "paprika",
    "patlabor",
    "redline",
}
EXPECTED_MACHINE_LAYERS = {
    "jinroh": ["common-all", "common-desktop"],
    "mindgame": [
        "common-ai",
        "common-all",
        "common-desktop",
        "common-dev",
        "common-dev-desktop",
    ],
    "paprika": ["common-all", "common-desktop", "common-dev", "common-dev-desktop"],
    "patlabor": ["common-all", "common-desktop", "common-dev", "common-dev-desktop"],
    "redline": ["common-ai", "common-all", "common-dev"],
}
STALE_PATH_RE = re.compile(
    r"nixos/(redline|mindgame|paprika|jinroh)"
    r"|dotfiles/(common|redline|mindgame|paprika|jinroh)"
    r"|dotfiles/<layer>"
    r"|nixos-configuration/nixos/"
)
STALE_PATH_FIXTURES = [
    ("Uses redline/dotfiles/.config/fish/config.fish.", False),
    ("Skills ship from common-dev/dotfiles/.agents/skills.", False),
    ("Old location was nixos/redline.", True),
    ("Old rendered path was dotfiles/common-dev/.config/tool.", True),
    ("The placeholder was dotfiles/<layer>.", True),
    ("~/nixos-configuration/nixos/paprika/configuration.nix", True),
]


def real_inventory(machine: str, tmp_path: Path) -> dict[Path, Path]:
    layers = (*sync.get_imported_layers(REPO / machine / "configuration.nix"), machine)
    home = tmp_path / f"{machine}-home"
    system = tmp_path / f"{machine}-system"
    selected, _ = collect_links(REPO, home, layers, nixos_root=system)
    return selected


@pytest.mark.parametrize(
    "machine,direct_imports,recursive_imports",
    [
        ("redline", ["common-ai", "common-all"], ["common-ai", "common-all", "common-dev"]),
        (
            "paprika",
            ["common-all", "common-desktop", "common-dev", "common-dev-desktop"],
            ["common-all", "common-desktop", "common-dev", "common-dev-desktop"],
        ),
    ],
)
def test_real_configuration_imports(machine, direct_imports, recursive_imports):
    config = REPO / machine / "configuration.nix"
    assert sync.parse_imported_layers(config.read_text()) == direct_imports
    assert sync.get_imported_layers(config) == recursive_imports


def test_discovered_machine_imports_match_repository_matrix():
    for machine, expected in EXPECTED_MACHINE_LAYERS.items():
        config = REPO / machine / "configuration.nix"
        assert config.is_file()
        assert sync.get_imported_layers(config) == expected


def test_repository_uses_target_first_layout_and_requires_each_target():
    targets = {directory.name: directory for directory in sync.discover_targets()}
    assert set(targets) == EXPECTED_TARGETS
    assert not (REPO / "nixos").exists()
    assert not (REPO / "dotfiles").exists()

    for name, directory in targets.items():
        assert directory.parent == REPO
        if name in EXPECTED_DOTFILES_TARGETS:
            assert (directory / "dotfiles").is_dir(), f"{name} needs a dotfiles directory"

    for machine in EXPECTED_MACHINE_LAYERS:
        assert (targets[machine] / "configuration.nix").is_file()
    assert (targets["frame"] / "sync.json").is_file()


def test_real_plugin_discovery_and_shared_inventory(tmp_path):
    plugin_root = tmp_path / "plugins"
    plugins = sync.build_layered_plugin_symlinks(REPO, plugin_root, "paprika", ["common-dev"])
    assert plugins == [
        (
            plugin_root / "deep-plan",
            REPO / "common-dev/dotfiles/.claude-plugins/deep-plan",
        )
    ]
    assert (plugins[0][1] / ".claude-plugin/plugin.json").is_file()

    selected = real_inventory("paprika", tmp_path)
    home = tmp_path / "paprika-home"
    system = tmp_path / "paprika-system"
    assert selected[home / ".local/share/claude-plugins/deep-plan"] == plugins[0][1]
    assert selected[system / "configuration.nix"] == REPO / "paprika/configuration.nix"
    for layer in EXPECTED_MACHINE_LAYERS["paprika"]:
        nix_files = (REPO / layer).rglob("*.nix")
        for source in nix_files:
            relative = source.relative_to(REPO / layer)
            if "dotfiles" not in relative.parts and not source.is_symlink():
                destination = system / layer / relative
                assert selected[destination] == source
    assert (
        selected[home / ".config/niri/outputs.kdl"]
        == REPO / "paprika/dotfiles/.config/niri/outputs.kdl"
    )
    assert selected[home / ".config/alacritty/alacritty.toml"] == (
        REPO / "common-dev-desktop/dotfiles/.config/alacritty/alacritty.toml"
    )


def test_real_headless_inventory_keeps_common_ai_without_desktop_dotfiles(tmp_path):
    selected = real_inventory("redline", tmp_path)
    home = tmp_path / "redline-home"
    system = tmp_path / "redline-system"

    assert selected[system / "configuration.nix"] == REPO / "redline/configuration.nix"
    assert selected[system / "common-ai/configuration.nix"] == REPO / "common-ai/configuration.nix"
    assert selected[home / ".gitconfig"] == REPO / "common-all/dotfiles/.gitconfig"
    assert selected[home / ".local/share/claude-plugins/deep-plan"] == (
        REPO / "common-dev/dotfiles/.claude-plugins/deep-plan"
    )
    assert not any(
        any(part in str(destination).lower() for part in ("niri", "alacritty", "quickshell"))
        for destination in selected
    )


@pytest.mark.parametrize("text,expected_stale", STALE_PATH_FIXTURES)
def test_stale_path_regex_contract(text, expected_stale):
    assert bool(STALE_PATH_RE.search(text)) is expected_stale


def test_repository_markdown_has_no_stale_paths_outside_migration_guide():
    markdown = (
        path
        for path in REPO.rglob("*.md")
        if ".git" not in path.parts and path.name != "MIGRATION.md"
    )
    matches = [
        f"{path.relative_to(REPO)}: {match.group(0)}"
        for path in markdown
        if (match := STALE_PATH_RE.search(path.read_text(errors="replace")))
    ]
    assert not matches, "Stale pre-target-first path spelling found:\n" + "\n".join(matches)
