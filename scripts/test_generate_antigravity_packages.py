#!/usr/bin/env python3
"""Regressions for scripts/generate_antigravity_packages.py."""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_antigravity_packages as gen  # noqa: E402

FRONTMATTER = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)


def frontmatter(text: str) -> dict[str, object]:
    match = FRONTMATTER.match(text)
    assert match is not None, text[:80]
    data = yaml.safe_load(match.group(1))
    assert isinstance(data, dict)
    return data


class GeneratorTests(unittest.TestCase):
    tree: gen.Tree

    @classmethod
    def setUpClass(cls) -> None:
        cls.tree = gen.build()

    def text(self, rel: str) -> str:
        return str(self.tree[Path(rel)].content.decode("utf-8"))

    def test_checked_in_tree_matches_generator(self) -> None:
        self.assertEqual(gen.check(self.tree), [])

    def test_manifests_follow_the_plugin_schema(self) -> None:
        allowed = {"$schema", "name", "displayName", "version", "description", "author", "repository", "license"}
        version = gen.lockstep_version()
        for key in gen.PACKAGES:
            manifest = json.loads(self.text(f"{key}/plugin.json"))
            self.assertEqual(manifest["name"], key)
            self.assertEqual(manifest["version"], version)
            self.assertEqual(manifest["$schema"], gen.PLUGIN_SCHEMA)
            self.assertLessEqual(set(manifest), allowed)
            self.assertRegex(key, r"^[a-z0-9]+(-[a-z0-9]+)*$")

    def test_skills_are_flat_named_and_rewritten(self) -> None:
        skills = [rel for rel in self.tree if rel.parts[:2] == ("ycc", "skills") and rel.name == "SKILL.md"]
        self.assertGreater(len(skills), 10)
        for rel in skills:
            data = frontmatter(self.text(rel.as_posix()))
            self.assertEqual(data["name"], rel.parent.name)
            self.assertLessEqual(
                set(data), {"name", "description", "disable-model-invocation", "license", "compatibility"}
            )
            self.assertLessEqual(len(str(data["description"])), 1024)
        plan = self.text("ycc/skills/plan/SKILL.md")
        self.assertIn("~/.gemini/config/plugins/ycc/ycc-shared/", plan)
        self.assertNotIn("${CLAUDE_PLUGIN_ROOT}", plan)
        self.assertNotRegex(plan, r"/ycc:[a-z]")
        self.assertFalse(any(rel.parts[:3] == ("ycc", "skills", "_shared") for rel in self.tree))

    def test_worktree_root_is_antigravity(self) -> None:
        self.assertIn(".antigravity/worktrees", self.text("ycc/ycc-shared/scripts/worktree-paths.sh"))

    def test_agents_use_closed_tool_and_model_sets(self) -> None:
        agents = [rel for rel in self.tree if rel.parts[:2] == ("ycc", "agents")]
        self.assertGreater(len(agents), 10)
        for rel in agents:
            data = frontmatter(self.text(rel.as_posix()))
            self.assertEqual(tuple(data), gen.AGENT_KEYS)
            self.assertIn(data["model"], gen.ANTIGRAVITY_MODELS)
            tools = data["tools"]
            assert isinstance(tools, list)
            self.assertLessEqual(set(tools), gen.ANTIGRAVITY_TOOLS)
        finder = frontmatter(self.text("ycc/agents/code-finder.md"))
        self.assertEqual(finder["model"], "flash")
        self.assertEqual(
            finder["tools"], ["view_file", "list_dir", "grep_search", "find_by_name", "read_url_content", "search_web"]
        )

    def test_unknown_agent_tool_fails_closed(self) -> None:
        with self.assertRaises(ValueError):
            gen.map_tools(["Teleport"], "demo")
        self.assertEqual(gen.map_tools(["Bash(git:*)", "Bash", "mcp__x__y"], "demo"), ["run_command"])

    def test_rules_carry_valid_triggers(self) -> None:
        rules = [rel for rel in self.tree if rel.parts[:2] == ("ycc-rules", "rules")]
        self.assertGreater(len(rules), 10)
        for rel in rules:
            text = self.text(rel.as_posix())
            data = frontmatter(text)
            self.assertIn(data["trigger"], gen.RULE_TRIGGERS)
            if data["trigger"] == "glob":
                self.assertIsInstance(data["globs"], str)
            self.assertNotIn("rule://", text)
            self.assertLessEqual(len(text.encode("utf-8")), gen.RULE_MAX_BYTES)
        self.assertFalse(any(rel.name.endswith("-trigger.md") for rel in rules))

    def test_mcp_translation(self) -> None:
        servers = json.loads(self.text("ycc-mcp/mcp_config.json"))["mcpServers"]
        self.assertEqual(servers["context7"], {"serverUrl": "https://mcp.context7.com/mcp"})
        self.assertNotIn("env", servers["xero"])
        self.assertEqual(
            gen.translate_server("s", {"command": "x", "env": {"A": "${A}", "B": "literal-${A}"}}),
            {"command": "x", "env": {"B": "literal-${A}"}},
        )
        with self.assertRaises(ValueError):
            gen.translate_server("s", {"type": "sse", "url": "https://example.invalid"})


if __name__ == "__main__":
    unittest.main()
