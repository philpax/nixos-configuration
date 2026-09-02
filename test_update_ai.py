"""Tests for update_ai.py — pure formatting, derivation consumption, and drift gate."""

from __future__ import annotations

import importlib.util
import textwrap
from pathlib import Path

# update-ai.py is hyphenated (a CLI script name), so it is not importable as a
# normal module; load it from its path.
_spec = importlib.util.spec_from_file_location(
    "update_ai", Path(__file__).resolve().parent / "update-ai.py"
)
update_ai = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(update_ai)


# A representative slice of `nix eval` output: one mindgame model (thinking) and
# the two redline models (no_reasoning, no max_output_tokens). Fields match the
# shape produced by anankeLib.mkClientModel.
def _providers():
    return [
        (
            "ananke-mindgame",
            {
                "display_name": "Custom (ananke-mindgame)",
                "api_key_env": "ANANKE_MINDGAME_API_KEY",
                "base_url": "http://mindgame:7070/v1",
                "models": [
                    {
                        "name": "qwen3.6-27b-ninfer-mtp3",
                        "context_window": 196608,
                        "supports_vision": False,
                        "class": "medium",
                        "reasoning": {"type": "thinking"},
                        "max_output_tokens": 32768,
                    },
                    {
                        "name": "muse-glimmer",
                        "context_window": 131072,
                        "supports_vision": True,
                        "class": "medium",
                        "reasoning": {"type": "none"},
                        "max_output_tokens": 32768,
                    },
                ],
            },
        ),
        (
            "ananke-redline",
            {
                "display_name": "Custom (ananke-redline)",
                "api_key_env": "ANANKE_REDLINE_API_KEY",
                "base_url": "http://redline:7070/v1",
                "models": [
                    {
                        "name": "qwen3.6-27b",
                        "context_window": 180000,
                        "supports_vision": True,
                        "class": "medium",
                        "reasoning": {"type": "none"},
                    },
                    {
                        "name": "gemma-4-31b-it-qat",
                        "context_window": 240000,
                        "supports_vision": True,
                        "class": "medium",
                        "reasoning": {"type": "none"},
                    },
                ],
            },
        ),
    ]


# Build the shared render context (mirrors update_ai.gather_context) and render a
# named template through the real loader, so tests exercise the same path the
# expander uses rather than bespoke per-format functions.


def _ctx(providers):
    return {
        "providers": providers,
        "maki_tier": update_ai.MAKI_TIER,
        "pt_class": update_ai.PT_CLASS,
        "pt_static_models": update_ai.PT_STATIC_MODELS,
    }


def _render_maki(providers):
    return update_ai._env.get_template("providers.toml.j2").render(**_ctx(providers))


def _render_pt(providers):
    return update_ai._env.get_template("config.yaml.j2").render(**_ctx(providers))


# ---------------------------------------------------------------------------
# makima template
# ---------------------------------------------------------------------------


class TestFmtMaki:
    def test_thinking_model_emits_supports_thinking(self):
        toml = _render_maki(_providers())
        block = toml.split("[[ananke-mindgame.models]]")[1].split("[[ananke-mindgame.models]]")[0]
        assert 'id = "qwen3.6-27b-ninfer-mtp3"' in block
        assert 'tier = "medium"' in block
        assert "context_window = 196608" in block
        assert "max_output_tokens = 32768" in block
        assert "supports_thinking = true" in block
        assert "supports_vision = false" in block

    def test_no_reasoning_model_omits_supports_thinking(self):
        toml = _render_maki(_providers())
        # muse-glimmer block (the second mindgame model)
        muse = toml.split('id = "muse-glimmer"')[1].split("[[ananke")[0]
        assert "supports_thinking" not in muse
        assert "supports_vision = true" in muse

    def test_redline_model_omits_max_output_tokens(self):
        toml = _render_maki(_providers())
        gemma = toml.split('id = "gemma-4-31b-it-qat"')[1].split("[[ananke")[0]
        assert "max_output_tokens" not in gemma
        assert "context_window = 240000" in gemma

    def test_drift_fixes_hold(self):
        toml = _render_maki(_providers())
        assert "context_window = 131072" in toml  # muse-glimmer: was 262144
        assert "context_window = 240000" in toml  # gemma-qat: was 200000
        assert (
            "context_window = 262144"
            not in toml.split('id = "muse-glimmer"')[1].split("[[ananke")[0]
        )

    def test_provider_header(self):
        toml = _render_maki(_providers())
        assert '[ananke-mindgame]\ndisplay_name = "Custom (ananke-mindgame)"' in toml
        assert 'base_url = "http://mindgame:7070/v1"' in toml
        assert 'api_key_env = "ANANKE_MINDGAME_API_KEY"' in toml
        assert "discover_models = true" in toml

    def test_class_mapping(self):
        providers = [
            (
                "ananke-x",
                {
                    "display_name": "Custom (ananke-x)",
                    "api_key_env": "ANANKE_X_API_KEY",
                    "base_url": "http://x:7070/v1",
                    "models": [
                        {
                            "name": "big",
                            "context_window": 1,
                            "supports_vision": False,
                            "class": "large",
                            "reasoning": {"type": "none"},
                        },
                        {
                            "name": "mid",
                            "context_window": 1,
                            "supports_vision": False,
                            "class": "medium",
                            "reasoning": {"type": "none"},
                        },
                        {
                            "name": "smol",
                            "context_window": 1,
                            "supports_vision": False,
                            "class": "small",
                            "reasoning": {"type": "none"},
                        },
                    ],
                },
            ),
        ]
        toml = _render_maki(providers)
        assert 'tier = "strong"' in toml
        assert 'tier = "medium"' in toml
        assert 'tier = "weak"' in toml

    def test_trailing_newline_only(self):
        toml = _render_maki(_providers())
        assert toml.endswith("supports_vision = true\n")
        assert not toml.endswith("\n\n")


# ---------------------------------------------------------------------------
# polytoken template
# ---------------------------------------------------------------------------


class TestFmtPolytoken:
    def test_defaults_are_static(self):
        # Defaults are hand-maintained in the template, not derived from models.
        yaml = _render_pt(_providers())
        assert "  full: ananke-mindgame/qwen3.6-27b-ninfer-mtp3" in yaml
        assert "  mini: ananke-mindgame/qwen3.6-27b-ninfer-mtp3" in yaml
        assert "  nano: ananke-mindgame/qwen3.6-35b-a3b-ninfer-dflash7" in yaml

    def test_thinking_emits_can_disable(self):
        yaml = _render_pt(_providers())
        block = yaml.split("ananke-mindgame/qwen3.6-27b-ninfer-mtp3:")[1].split("ananke-mindgame/")[
            0
        ]
        assert "    reasoning:\n      type: thinking\n      can_disable: true" in block
        assert "    context_window: 196608" in block
        assert "    max_output_tokens_per_turn: 32768" in block
        assert "    supports_vision: false" in block
        assert "    class: mini" in block

    def test_no_reasoning_emits_no_reasoning(self):
        yaml = _render_pt(_providers())
        block = yaml.split("ananke-mindgame/muse-glimmer:")[1].split("ananke-mindgame/")[0]
        assert "    reasoning:\n      type: no_reasoning\n" in block
        assert "can_disable" not in block

    def test_static_synthetic_glm_model(self):
        yaml = _render_pt(_providers())
        block = yaml.split("synthetic/hf:zai-org/GLM-5.2:")[1].split("default_permission_matcher")[
            0
        ]
        assert "    provider_name: hf:zai-org/GLM-5.2" in block
        assert "    variant: other" in block
        assert "    class: full" in block
        assert "    provider: synthetic" in block
        assert "    reasoning:\n      type: no_reasoning\n" in block
        assert "    context_window: 512000" in block
        assert "    compaction_threshold: 0.8" in block

    def test_redline_omits_max_output_tokens(self):
        yaml = _render_pt(_providers())
        block = yaml.split("ananke-redline/gemma-4-31b-it-qat:")[1].split(
            "default_permission_matcher"
        )[0]
        assert "max_output_tokens_per_turn" not in block
        assert "    context_window: 240000" in block

    def test_drift_fixes_hold(self):
        yaml = _render_pt(_providers())
        assert "context_window: 131072" in yaml  # muse-glimmer
        assert "context_window: 240000" in yaml  # gemma-qat
        assert "context_window: 200000" not in yaml
        assert "context_window: 262144" not in yaml

    def test_static_sections_present(self):
        yaml = _render_pt(_providers())
        assert "version: 3" in yaml
        assert "config_command_substitution: true" in yaml
        assert "default_permission_matcher: bypass_plus" in yaml
        assert "mcp_servers:" in yaml
        assert "ida-pro-mcp:" in yaml
        assert "integrations:" in yaml
        assert "tui:" in yaml
        # static non-ananke providers
        assert "  umans:" in yaml
        assert "  codex:" in yaml

    def test_can_disable_false(self):
        providers = [
            (
                "ananke-x",
                {
                    "display_name": "d",
                    "api_key_env": "E",
                    "base_url": "http://x:7070/v1",
                    "models": [
                        {
                            "name": "m",
                            "context_window": 1,
                            "supports_vision": False,
                            "class": "medium",
                            "reasoning": {"type": "thinking", "can_disable": False},
                        }
                    ],
                },
            ),
        ]
        yaml = _render_pt(providers)
        assert "      can_disable: false" in yaml

    def test_class_mapping(self):
        providers = [
            (
                "ananke-x",
                {
                    "display_name": "d",
                    "api_key_env": "E",
                    "base_url": "http://x:7070/v1",
                    "models": [
                        {
                            "name": "a",
                            "context_window": 1,
                            "supports_vision": False,
                            "class": "large",
                            "reasoning": {"type": "none"},
                        },
                        {
                            "name": "b",
                            "context_window": 1,
                            "supports_vision": False,
                            "class": "medium",
                            "reasoning": {"type": "none"},
                        },
                        {
                            "name": "c",
                            "context_window": 1,
                            "supports_vision": False,
                            "class": "small",
                            "reasoning": {"type": "none"},
                        },
                    ],
                },
            ),
        ]
        yaml = _render_pt(providers)
        assert "    class: full" in yaml
        assert "    class: mini" in yaml
        assert "    class: nano" in yaml


# ---------------------------------------------------------------------------
# discover_templates — generic expander
# ---------------------------------------------------------------------------


class TestDiscoverTemplates:
    def test_finds_both_colocated_templates(self):
        names = {p.name for p in update_ai.discover_templates()}
        assert names == {"providers.toml.j2", "config.yaml.j2"}

    def test_output_path_is_j2_stripped_sibling(self):
        rendered = update_ai.render_all(_ctx(_providers()))
        outputs = {p.name for p in rendered}
        assert outputs == {"providers.toml", "config.yaml"}


# ---------------------------------------------------------------------------
# check_file — drift gate
# ---------------------------------------------------------------------------


class TestCheckFile:
    def test_matches(self, tmp_path):
        path = tmp_path / "f"
        path.write_text("hello\n")
        assert update_ai.check_file(path, "hello\n") is True

    def test_drift(self, tmp_path):
        path = tmp_path / "f"
        path.write_text("hello\n")
        assert update_ai.check_file(path, "world\n") is False

    def test_missing_file_drift(self, tmp_path):
        path = tmp_path / "missing"
        assert update_ai.check_file(path, "anything") is False


# ---------------------------------------------------------------------------
# end-to-end shape: full makima output for the fixture
# ---------------------------------------------------------------------------


class TestMakiFullOutput:
    def test_snapshot(self):
        toml = _render_maki(_providers())
        expected = textwrap.dedent("""\
            [ananke-mindgame]
            display_name = "Custom (ananke-mindgame)"
            protocol = "openai"
            base_url = "http://mindgame:7070/v1"
            api_key_env = "ANANKE_MINDGAME_API_KEY"
            discover_models = true

            [[ananke-mindgame.models]]
            id = "qwen3.6-27b-ninfer-mtp3"
            tier = "medium"
            context_window = 196608
            max_output_tokens = 32768
            supports_thinking = true
            supports_vision = false

            [[ananke-mindgame.models]]
            id = "muse-glimmer"
            tier = "medium"
            context_window = 131072
            max_output_tokens = 32768
            supports_vision = true

            [ananke-redline]
            display_name = "Custom (ananke-redline)"
            protocol = "openai"
            base_url = "http://redline:7070/v1"
            api_key_env = "ANANKE_REDLINE_API_KEY"
            discover_models = true

            [[ananke-redline.models]]
            id = "qwen3.6-27b"
            tier = "medium"
            context_window = 180000
            supports_vision = true

            [[ananke-redline.models]]
            id = "gemma-4-31b-it-qat"
            tier = "medium"
            context_window = 240000
            supports_vision = true
        """)
        assert toml == expected
