#!/usr/bin/env python3
"""Regressions for scripts/generate_muse_packages.py.

The live check runs ``muse plugins validate`` against the checked-in packages
when ``muse`` is on PATH (``YCC_MUSE_BIN`` overrides) and is skipped otherwise.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_muse_packages as gen  # noqa: E402

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

    def test_manifest_families(self) -> None:
        version = gen.lockstep_version()
        ycc = json.loads(self.text("ycc/.claude-plugin/plugin.json"))
        self.assertEqual(ycc, {"name": "ycc", "version": version, "description": gen.PACKAGES["ycc"][1]})
        self.assertNotIn(Path("ycc/.muse-plugin/plugin.json"), self.tree)  # native would hide the agents
        mcp = json.loads(self.text("ycc-mcp/.muse-plugin/plugin.json"))
        self.assertEqual(mcp["compat"], {"source": "native", "manifestDir": ".muse-plugin"})
        self.assertEqual(mcp["name"], "ycc-mcp")
        self.assertEqual(mcp["version"], version)
        self.assertEqual(set(mcp["capabilities"]), {"skills", "commands", "hooks", "mcpServers", "reminders"})

    def test_skills_are_flat_named_and_rewritten(self) -> None:
        skills = [rel for rel in self.tree if rel.parts[:2] == ("ycc", "skills") and rel.name == "SKILL.md"]
        self.assertGreater(len(skills), 10)
        for rel in skills:
            data = frontmatter(self.text(rel.as_posix()))
            self.assertEqual(data["name"], rel.parent.name)
            self.assertLessEqual(set(data), {"name", "description", "disable-model-invocation", "argument-hint"})
            self.assertLessEqual(len(str(data["description"])), 1024)
        plan = self.text("ycc/skills/plan/SKILL.md")
        self.assertIn("~/.local/share/ycc/muse/ycc/ycc-shared/", plan)
        self.assertNotIn("${CLAUDE_PLUGIN_ROOT}", plan)
        self.assertFalse(any(rel.parts[:3] == ("ycc", "skills", "_shared") for rel in self.tree))

    def test_no_command_wrappers(self) -> None:
        # Muse lists every plugin skill as /ycc:<name>; a commands/ wrapper would duplicate it.
        self.assertFalse(any(rel.parts[:2] == ("ycc", "commands") for rel in self.tree))

    def test_namespace_follows_muse_ids(self) -> None:
        plan = self.text("ycc/skills/plan/SKILL.md")
        self.assertRegex(plan, r"/ycc:[a-z]")  # Muse invokes plugin skills as /ycc:<name>
        self.assertIn("ycc/planner", plan)  # Muse agent ids are ycc/<agent>
        self.assertNotRegex(plan, r"(?<![/\w])ycc:planner\b")
        self.assertEqual(
            gen.muse_namespace("Run /ycc:plan or spawn ycc:planner; see ycc:init.", {"planner": "planner"}),
            "Run /ycc:plan or spawn ycc/planner; see ycc:init.",
        )

    def test_rules_ship_as_relevance_loaded_skills(self) -> None:
        manifest = json.loads(self.text("ycc-rules/.muse-plugin/plugin.json"))
        entries = manifest["capabilities"]["skills"]
        self.assertGreater(len(entries), 10)
        self.assertEqual(manifest["capabilities"]["mcpServers"], [])
        for entry in entries:
            rel = Path("ycc-rules") / entry["path"]
            data = frontmatter(self.text(rel.as_posix()))
            self.assertEqual(data["name"], entry["id"])
            self.assertEqual(rel.parent.name, entry["id"])
            self.assertLessEqual(len(str(data["description"])), gen.SKILL_DESCRIPTION_MAX)
            self.assertNotIn("rule://", self.text(rel.as_posix()))
        self.assertFalse(any(entry["id"].endswith("-trigger") for entry in entries))
        python = frontmatter(self.text("ycc-rules/rules/ycc-python-security/SKILL.md"))
        self.assertIn("**/*.py", str(python["description"]))

    def test_worktree_root_is_muse(self) -> None:
        self.assertIn(".muse/worktrees", self.text("ycc/ycc-shared/scripts/worktree-paths.sh"))

    def test_agents_use_projectable_tools_and_no_color(self) -> None:
        agents = [rel for rel in self.tree if rel.parts[:2] == ("ycc", "agents")]
        self.assertGreater(len(agents), 10)
        for rel in agents:
            data = frontmatter(self.text(rel.as_posix()))
            self.assertLessEqual(set(data), set(gen.AGENT_KEYS))
            self.assertRegex(str(data["name"]), gen.AGENT_NAME)
            tools = data["tools"]
            assert isinstance(tools, list)
            self.assertLessEqual(set(tools), gen.MUSE_TOOLS)
            # Muse only spawns agents whose tools use its native names (Claude names validate
            # but are refused at spawn time as agent_definition_unavailable).
            self.assertFalse(set(tools) & set(gen.TOOL_MAP), tools)
        finder = frontmatter(self.text("ycc/agents/code-finder.md"))
        self.assertEqual(finder["tools"], ["read_file", "search", "web_fetch", "web_search"])

    def test_tool_map_fails_closed(self) -> None:
        with self.assertRaises(ValueError):
            gen.map_tools(["Teleport"], "demo")
        self.assertEqual(
            gen.map_tools(["Bash(git:*)", "Bash", "Glob", "Grep", "mcp__x__y"], "demo"), ["bash", "search"]
        )

    def test_invalid_agent_name_fails(self) -> None:
        with self.assertRaises(ValueError):
            gen.transform_agent("---\nname: agent2\ndescription: x\n---\nB\n", {}, {"inherit": "inherit"})

    def test_mcp_translation(self) -> None:
        servers = {
            s["id"]: s for s in json.loads(self.text("ycc-mcp/.muse-plugin/plugin.json"))["capabilities"]["mcpServers"]
        }
        self.assertEqual(
            servers["context7"], {"id": "context7", "transport": "http", "url": "https://mcp.context7.com/mcp"}
        )
        self.assertIn("openai-developer-docs", servers)
        playwright = servers["playwright"]
        self.assertEqual(playwright["command"], ["sh", "mcp/playwright.sh"])
        launcher = self.tree[Path("ycc-mcp/mcp/playwright.sh")]
        self.assertTrue(launcher.executable)
        self.assertIn("exec npx -y @playwright/mcp@latest", launcher.content.decode("utf-8"))
        # npx resolves node_modules/.bin from its cwd; Muse starts servers in the workspace,
        # so every launcher first leaves it for its own (trusted) plugin directory.
        for rel, payload in self.tree.items():
            if rel.parts[:2] == ("ycc-mcp", "mcp"):
                body = payload.content.decode("utf-8")
                self.assertIn('cd -- "$(dirname -- "$0")" || exit 1', body, rel)
                self.assertLess(body.index("cd -- "), body.index("exec "), rel)
        self.assertEqual(servers["xero"]["env"]["XERO_CLIENT_ID"], "${XERO_CLIENT_ID}")
        for entry in servers.values():
            for arg in entry.get("command", [])[1:]:
                self.assertTrue((Path("ycc-mcp") / arg) in self.tree, arg)  # every '/' arg is a plugin file
        self.assertEqual(gen.server_id("openaiDeveloperDocs"), "openai-developer-docs")
        with self.assertRaises(ValueError):
            gen.translate_server("s", {"type": "sse", "url": "https://example.invalid"})


class LiveValidateTests(unittest.TestCase):
    """`muse plugins validate` must report every capability supported with no diagnostics."""

    def setUp(self) -> None:
        self.muse = os.environ.get("YCC_MUSE_BIN") or shutil.which("muse")
        if not self.muse:
            self.skipTest("muse not on PATH")

    def validate(self, package: str) -> dict[str, Any]:
        with tempfile.TemporaryDirectory() as tmp:
            env = {**os.environ, "XDG_CONFIG_HOME": f"{tmp}/config", "XDG_DATA_HOME": f"{tmp}/data"}
            result = subprocess.run(
                [str(self.muse), "plugins", "validate", str(gen.OUTPUT_ROOT / package), "--json"],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )
        payload = json.loads(result.stdout)
        assert isinstance(payload, dict)
        return payload

    def test_packages_validate_clean(self) -> None:
        for package, family in (("ycc", "claude-compatible"), ("ycc-mcp", "native"), ("ycc-rules", "native")):
            with self.subTest(package=package):
                payload = self.validate(package)
                self.assertNotIn("error", payload)
                self.assertTrue(payload["valid"])
                self.assertEqual(payload["diagnostics"], [])
                plugin = payload["plugin"]
                assert isinstance(plugin, dict)
                self.assertEqual(plugin["manifest_family"], family)
                declarations = plugin["compatibility"]["declarations"]
                unsupported = [d["id"] for d in declarations if d["classification"] != "supported"]
                self.assertEqual(unsupported, [])
        agents = sum(1 for rel in gen.build() if rel.parts[:2] == ("ycc", "agents"))
        declared = [d for d in self.validate("ycc")["plugin"]["compatibility"]["declarations"] if d["kind"] == "agent"]
        self.assertEqual(len(declared), agents)


if __name__ == "__main__":
    unittest.main()
