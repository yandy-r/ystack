#!/usr/bin/env python3
"""Regression tests for OpenCode V2 config validation and MCP translation."""

from __future__ import annotations

import contextlib
import io
import json
import runpy
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

from generate_opencode_common import translate_mcp_servers
from generate_opencode_plugin import (
    build_agents_config,
    build_opencode_config,
    build_provider_config,
    expected_agent_ids,
    load_model_settings,
    validate_agent_models,
)
from validate_opencode_config import validate_config

REPO_ROOT = Path(__file__).resolve().parent.parent


class OpenCodeConfigValidationTestCase(unittest.TestCase):
    def assert_has_error(self, errors: list[str], expected: str) -> None:
        self.assertTrue(
            any(expected in error for error in errors),
            f"expected an error containing {expected!r}; got {errors!r}",
        )

    def test_generated_bundle_is_valid_v2(self) -> None:
        config = json.loads((REPO_ROOT / ".opencode-plugin/opencode.json").read_text(encoding="utf-8"))

        self.assertEqual(validate_config(config), [])

    def test_committed_bundle_agents_match_models_json(self) -> None:
        config = json.loads((REPO_ROOT / ".opencode-plugin/opencode.json").read_text(encoding="utf-8"))

        self.assertEqual(config["agents"], build_agents_config(load_model_settings()))

    def test_generated_config_sets_subagent_depth(self) -> None:
        config: dict[str, Any] = build_opencode_config()

        self.assertEqual(config["experimental"]["subagent_depth"], 2)

    def test_rejects_v1_and_bundle_forbidden_top_level_fields(self) -> None:
        config: dict[str, Any] = {
            "$schema": "https://opencode.ai/config.json",
            "model": "Frontier",
            "instructions": ["AGENTS.md"],
            "permissions": {"default_policy": "allow"},
            "auto_approve": True,
            "provider": {"9router": {}},
            "plugins": [],
            "mcp": {
                "github": {"type": "local", "command": ["npx"]},
                "servers": {},
            },
        }

        errors = validate_config(config)

        self.assert_has_error(errors, "instructions must not be set in the bundle")
        self.assert_has_error(errors, "auto_approve is not a documented V2 config field")
        self.assert_has_error(errors, "provider is V1 config; use providers")
        self.assert_has_error(errors, "model='Frontier' is not a 'provider/model' reference")
        self.assert_has_error(errors, "permissions must be an ordered list")
        self.assert_has_error(errors, "sit directly under mcp")

    def test_rejects_v1_nested_fields_and_bad_variant(self) -> None:
        config: dict[str, Any] = {
            "$schema": "https://opencode.ai/config.json",
            "model": "9router/Frontier-Lite",
            "providers": {
                "9router": {
                    "npm": "@ai-sdk/openai-compatible",
                    "options": {"baseURL": "https://example.test/v1"},
                    "models": {
                        "Frontier-Lite": {
                            "modalities": {"input": ["text"], "output": ["text"]},
                            "limit": {"context": 1_000_000},
                        }
                    },
                }
            },
            "agents": {
                "general": {
                    "model": "9router/Frontier-Lite#high",
                    "mode": "subagent",
                },
                "legacy": {
                    "prompt": "Legacy agent prompt",
                    "tools": {},
                    "mode": "worker",
                },
            },
            "plugins": [],
            "mcp": {
                "servers": {
                    "github": {
                        "type": "local",
                        "command": ["npx"],
                        "environment": {
                            "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_API_TOKEN}",
                        },
                    }
                }
            },
        }

        errors = validate_config(config)

        self.assert_has_error(errors, "providers.9router.npm is V1; use package")
        self.assert_has_error(errors, "providers.9router.options is V1; use settings")
        self.assert_has_error(errors, "modalities is V1; use capabilities")
        self.assert_has_error(errors, "limit.output must be an integer token count")
        self.assert_has_error(errors, "selects an undeclared variant")
        self.assert_has_error(errors, "agents.legacy.prompt is V1; use system")
        self.assert_has_error(errors, "agents.legacy.tools is V1; use permissions")
        self.assert_has_error(errors, "mode='worker' must be one of primary, subagent, all")
        self.assert_has_error(errors, "uses a shell placeholder")

    def test_rejects_malformed_v2_permission_rules(self) -> None:
        config: dict[str, Any] = build_opencode_config()
        config["agents"]["general"]["permissions"] = [
            {"action": 42, "resource": "", "effect": "sometimes"},
            {"action": "read", "effect": "allow"},
            {"action": None, "resource": "*", "effect": "allow"},
            {"action": "read", "resource": None, "effect": "allow"},
            {"action": "read", "resource": "*", "effect": None},
            {"action": "read", "resource": "*", "effect": ["allow"]},
        ]

        errors = validate_config(config)

        self.assert_has_error(errors, "agents.general.permissions[0].action must be a non-empty string")
        self.assert_has_error(errors, "agents.general.permissions[0].resource must be a non-empty string")
        self.assert_has_error(errors, "effect='sometimes' must be one of allow, deny, ask")
        self.assert_has_error(errors, "agents.general.permissions[1] is missing resource")
        self.assert_has_error(errors, "agents.general.permissions[2].action must be a non-empty string")
        self.assert_has_error(errors, "agents.general.permissions[3].resource must be a non-empty string")
        self.assert_has_error(errors, "agents.general.permissions[4].effect must be a non-empty string")
        self.assert_has_error(errors, "agents.general.permissions[5].effect must be a non-empty string")

    def test_mcp_translation_uses_v2_disabled_field(self) -> None:
        translated = translate_mcp_servers(
            {
                "local": {"command": "npx", "args": ["server"], "enabled": False},
                "remote": {"url": "https://example.test/mcp", "enabled": False},
            }
        )

        self.assertTrue(translated["local"]["disabled"])
        self.assertNotIn("enabled", translated["local"])
        self.assertTrue(translated["remote"]["disabled"])
        self.assertNotIn("enabled", translated["remote"])

    def test_agent_models_validation_catches_missing_and_stale_and_malformed(self) -> None:
        expected = expected_agent_ids()
        valid_mapping = {agent_id: "openai/gpt-5.6-sol" for agent_id in expected}

        # Valid mapping passes
        self.assertEqual(validate_agent_models(valid_mapping), valid_mapping)

        # Missing agent
        incomplete = dict(valid_mapping)
        incomplete.pop("general")
        with self.assertRaises(SystemExit) as ctx:
            validate_agent_models(incomplete)
        self.assertIn("missing agent IDs: general", str(ctx.exception))

        # Stale agent
        extra = dict(valid_mapping)
        extra["stale-agent-xyz"] = "openai/gpt-5.6-sol"
        with self.assertRaises(SystemExit) as ctx:
            validate_agent_models(extra)
        self.assertIn("stale agent IDs: stale-agent-xyz", str(ctx.exception))

        # Malformed model reference (bare model name or not provider/model)
        malformed = dict(valid_mapping)
        malformed["architect"] = "gpt-6-astra"
        with self.assertRaises(SystemExit) as ctx:
            validate_agent_models(malformed)
        self.assertIn("expected 'provider/model'", str(ctx.exception))

    def test_provider_config_effort_and_verbosity_and_subagent_variant(self) -> None:
        settings = load_model_settings()
        providers: dict[str, Any] = build_provider_config(settings)

        self.assertIn("openai", providers)
        openai_models = providers["openai"]["models"]
        self.assertIn("gpt-5.6-sol", openai_models)

        main_entry = openai_models["gpt-5.6-sol"]
        self.assertEqual(
            main_entry["settings"],
            {"reasoningEffort": "high", "textVerbosity": "medium"},
        )
        self.assertEqual(len(main_entry["variants"]), 1)
        subagent_variant = main_entry["variants"][0]
        self.assertEqual(subagent_variant["id"], "subagent")
        self.assertEqual(
            subagent_variant["settings"],
            {"reasoningEffort": "high", "textVerbosity": "low"},
        )

    def test_model_settings_validator_diagnoses_each_agent_divergence(self) -> None:
        bundle_path = REPO_ROOT / ".opencode-plugin/opencode.json"
        config = json.loads(bundle_path.read_text(encoding="utf-8"))
        config["agents"].pop("general")
        config["agents"]["architect"] = "openai/gpt-6-astra"
        config["agents"]["planner"] = {"model": "openai/other"}
        config["agents"]["stale-agent-xyz"] = {"model": "openai/gpt-5.6-sol"}
        original_read_text = Path.read_text

        def fake_read_text(self: Path, *args: Any, **kwargs: Any) -> str:
            if self == bundle_path:
                return json.dumps(config)
            return original_read_text(self, *args, **kwargs)

        stderr = io.StringIO()
        with patch.object(Path, "read_text", fake_read_text), contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as ctx:
                runpy.run_path(str(REPO_ROOT / "scripts/validate-model-settings.py"), run_name="__main__")

        self.assertEqual(ctx.exception.code, 1)
        output = stderr.getvalue()
        self.assertIn("agents.general: missing from generated opencode.json", output)
        self.assertIn("agents.architect: malformed entry 'openai/gpt-6-astra'", output)
        self.assertIn("agents.planner.model: got 'openai/other', expected 'openai/gpt-5.6-sol'", output)
        self.assertIn("agents.stale-agent-xyz: emitted but not declared in models.json", output)

    def test_agents_config_mapping_preserved_after_generation(self) -> None:
        settings: dict[str, Any] = load_model_settings()
        agents_config = build_agents_config(settings)
        declared_mapping = settings["agents"]

        self.assertEqual(set(agents_config.keys()), set(declared_mapping.keys()))
        for agent_id, reference in declared_mapping.items():
            self.assertEqual(agents_config[agent_id], {"model": reference})


if __name__ == "__main__":
    unittest.main(verbosity=2)
