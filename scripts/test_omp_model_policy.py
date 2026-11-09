#!/usr/bin/env python3
"""Policy tests for scripts/omp_model_policy.py (targets.omp and the managed snippet)."""

from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path
from typing import Any

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))

import omp_model_policy as policy  # noqa: E402
from generate_codex_common import SRC_AGENTS_DIR, parse_frontmatter  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent


def used_agent_models() -> set[str]:
    return {
        str(parse_frontmatter(path.read_text(encoding="utf-8"))[0].get("model", "inherit"))
        for path in SRC_AGENTS_DIR.glob("*.md")
    }


class OmpModelPolicyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.omp = policy.load_omp()
        self.snippet: dict[str, Any] = yaml.safe_load((REPO_ROOT / self.omp["config"]).read_text(encoding="utf-8"))
        self.used = used_agent_models()

    def errors(self, omp: dict[str, Any] | None = None, snippet: object = None) -> list[str]:
        return policy.omp_model_errors(
            self.omp if omp is None else omp, self.snippet if snippet is None else snippet, self.used
        )

    def assert_error(self, errors: list[str], *needles: str) -> None:
        self.assertTrue(
            any(all(needle in error for needle in needles) for error in errors),
            f"expected an error containing {needles!r}; got {errors!r}",
        )

    def test_p1_repo_models_and_snippet_are_valid(self) -> None:
        self.assertEqual(self.errors(), [])
        self.assertEqual(
            policy.agent_model_map(), {"opus": "@slow", "sonnet": "@task", "haiku": "@task", "inherit": None}
        )

    def test_p2_unknown_role_rejected(self) -> None:
        omp = copy.deepcopy(self.omp)
        omp["roles"]["architect"] = "subagent"
        self.assert_error(self.errors(omp), "roles.architect", "unknown OMP role")

    def test_p2_default_role_required_and_targets_main(self) -> None:
        omp = copy.deepcopy(self.omp)
        del omp["roles"]["default"]
        self.assert_error(self.errors(omp), "roles.default", "missing")

        omp = copy.deepcopy(self.omp)
        omp["roles"]["default"] = "subagent"
        self.assert_error(self.errors(omp), "roles.default", "expected 'main'", "'subagent'")

    def test_p3_bad_selector_or_effort_rejected(self) -> None:
        cases = {
            "bare id": ("subagent", "model", "claude-opus-5", "subagent.model"),
            "missing provider": ("main", "model", "/claude-fable-5-1", "main.model"),
            "unknown effort": ("fallback", "effort", "ultra", "fallback.effort"),
        }
        for label, (entry, field, value, needle) in cases.items():
            with self.subTest(label):
                omp = copy.deepcopy(self.omp)
                omp[entry][field] = value
                self.assert_error(self.errors(omp), needle, repr(value))

    def test_p3_auto_and_inherit_efforts_accepted(self) -> None:
        for effort in ("auto", "inherit"):
            with self.subTest(effort):
                omp = copy.deepcopy(self.omp)
                omp["fallback"]["effort"] = effort
                snippet = policy.expected_snippet(omp)
                self.assertEqual(self.errors(omp, snippet), [])

    def test_p4_agent_model_alias_rejected(self) -> None:
        omp = copy.deepcopy(self.omp)
        omp["agentModels"]["opus"] = "pi/slow"
        self.assert_error(self.errors(omp), "agentModels.opus", "legacy 'pi/'")

        omp = copy.deepcopy(self.omp)
        omp["agentModels"]["opus"] = "@plan"
        self.assert_error(self.errors(omp), "agentModels.opus", "'@plan'", "does not manage")

        omp = copy.deepcopy(self.omp)
        del omp["agentModels"]["sonnet"]
        self.assert_error(self.errors(omp), "agentModels", "sonnet")

    def test_p5_snippet_extra_key_or_drift_rejected(self) -> None:
        snippet = copy.deepcopy(self.snippet)
        snippet["tools"]["approval"] = {"bash": "allow"}
        self.assert_error(self.errors(snippet=snippet), "tools.approval", "not a ycc-managed OMP key")

        snippet = copy.deepcopy(self.snippet)
        snippet["modelRoles"]["slow"] = "anthropic/claude-opus-5:max"
        self.assert_error(self.errors(snippet=snippet), "modelRoles.slow", "claude-opus-5:max")

    def test_p6_fallback_chains_follow_switch(self) -> None:
        chains = self.snippet["retry"]["fallbackChains"]
        self.assertEqual(chains, {role: ["openai/gpt-5.6-sol"] for role in self.omp["roles"]})

        omp = copy.deepcopy(self.omp)
        omp["fallbackChains"] = False
        snippet = policy.expected_snippet(omp)
        self.assertNotIn("retry", snippet)
        self.assertEqual(self.errors(omp, snippet), [])
        self.assert_error(self.errors(omp), "retry.fallbackChains", "fallbackChains is false")

        omp["fallbackChains"] = "yes"
        self.assert_error(self.errors(omp), "fallbackChains", "expected true or false", "'yes'")

    def test_p6_fallback_chain_drift_or_same_model_rejected(self) -> None:
        snippet = copy.deepcopy(self.snippet)
        snippet["retry"]["fallbackChains"]["slow"] = ["openai/gpt-5.6-sol:high"]
        self.assert_error(self.errors(snippet=snippet), "retry.fallbackChains", "gpt-5.6-sol:high")

        snippet = copy.deepcopy(self.snippet)
        snippet["retry"]["maxRetries"] = 5
        self.assert_error(self.errors(snippet=snippet), "retry.maxRetries", "not a ycc-managed OMP key")

        omp = copy.deepcopy(self.omp)
        omp["subagent"]["model"] = omp["fallback"]["model"]
        self.assert_error(self.errors(omp), "fallbackChains", "'slow'", "same model")


if __name__ == "__main__":
    unittest.main()
