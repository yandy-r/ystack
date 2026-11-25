#!/usr/bin/env python3
"""Real-config guard (YAN-2454): ignore live-session churn, stay strict on settings/plugins."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS_DIR))

from claude_namespace_checks import changed_entries, snapshot  # noqa: E402


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class RealConfigGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.config = self.home / ".claude"
        self.claude_json = self.home / ".claude.json"
        write(self.config / "settings.json", '{"enabledPlugins": {}}')
        write(self.config / "plugins/installed_plugins.json", '{"version": 2, "plugins": {}}')
        write(self.config / "plugins/known_marketplaces.json", '{"mkt": {"source": {}, "lastUpdated": "t1"}}')
        write(self.config / "plugins/cache/mkt/demo/1.0.0/.claude-plugin/plugin.json", '{"name": "demo"}')
        write(self.config / "plugins/marketplaces/mkt/.claude-plugin/marketplace.json", "{}")
        write(self.config / "sessions/1.json", "{}")
        write(self.config / "backups/.claude.json.backup.1", "{}")
        write(self.config / "projects/-home/a.jsonl", "")
        write(self.config / "skills/mine/SKILL.md", "")
        self.write_claude_json(numStartups=1, projects={"/repo": {"allowedTools": [], "lastCost": 1}})
        self.before = self.snap()

    def write_claude_json(self, **data: object) -> None:
        self.claude_json.write_text(json.dumps(data))

    def snap(self) -> dict[str, object]:
        return snapshot([str(self.config), str(self.claude_json)])

    def changed(self) -> list[str]:
        return changed_entries(self.before, self.snap())

    def test_concurrent_session_churn_is_ignored(self) -> None:
        write(self.config / "sessions/2.json", "{}")
        (self.config / "sessions/1.json").unlink()
        write(self.config / "backups/.claude.json.backup.2", "{}")
        write(self.config / "projects/-home/a.jsonl", "turn\n")
        write(self.config / "policy-limits.json.stamp.json", "{}")
        write(self.config / "policy-limits.json.stamp.json.tmp.abc123", "{}")
        write(self.config / "remote-settings.json.signature.json", "{}")
        write(self.config / "plugins/cache/mkt/demo/1.0.0/.in_use", "")
        write(self.config / "plugins/synced/x/manifest.json", "{}")
        write(self.config / "skills/synced/x/SKILL.md", "")
        write(self.config / "history.jsonl", "{}\n")
        write(self.config / "mcp-needs-auth-cache.json", "{}")
        write(self.config / ".last-cleanup", "")
        write(self.config / "plugins/known_marketplaces.json", '{"mkt": {"lastUpdated": "t2", "source": {}}}')
        self.write_claude_json(
            numStartups=2, tipsHistory={"a": 1}, projects={"/repo": {"allowedTools": [], "lastCost": 2}, "/new": {}}
        )
        self.assertEqual(self.changed(), [])

    def test_settings_and_plugin_writes_still_fail(self) -> None:
        cases = {
            "settings.json": '{"enabledPlugins": {"demo@mkt": true}}',
            "settings.local.json": "{}",
            "plugins/installed_plugins.json": '{"version": 2, "plugins": {"demo@mkt": []}}',
            "plugins/known_marketplaces.json": '{"mkt": {"source": {}, "lastUpdated": "t1"}, "ns-lab": {}}',
            "plugins/cache/mkt/demo/1.0.0/.claude-plugin/plugin.json": '{"name": "evil"}',
            "plugins/cache/ns-lab/p0/1.0.0/.claude-plugin/plugin.json": "{}",
            "plugins/marketplaces/ns-lab/.claude-plugin/marketplace.json": "{}",
            "skills/mine/SKILL.md": "changed",
        }
        for relative, text in cases.items():
            with self.subTest(relative):
                self.before = self.snap()
                write(self.config / relative, text)
                self.assertIn(str(self.config / relative), self.changed())

    def test_removed_plugin_index_fails(self) -> None:
        (self.config / "plugins/known_marketplaces.json").unlink()
        self.assertEqual(self.changed(), [str(self.config / "plugins/known_marketplaces.json")])

    def test_claude_json_mcp_and_permissions_still_fail(self) -> None:
        for data in (
            {"mcpServers": {"lab": {"command": "x"}}},
            {"projects": {"/repo": {"allowedTools": ["Bash"], "lastCost": 1}}},
            {"projects": {"/lab": {"mcpServers": {"lab": {}}}}},
        ):
            with self.subTest(data):
                base: dict[str, object] = {"numStartups": 1, "projects": {"/repo": {"allowedTools": [], "lastCost": 1}}}
                self.write_claude_json(**base)
                self.before = self.snap()
                self.write_claude_json(**(base | data))
                self.assertEqual(self.changed(), [str(self.claude_json)])

    def test_config_dir_claude_json_ignores_session_counters(self) -> None:
        inner = self.config / ".claude.json"
        inner.write_text('{"numStartups": 1}')
        self.before = self.snap()
        inner.write_text('{"numStartups": 2}')
        self.assertEqual(self.changed(), [])
        inner.write_text('{"numStartups": 2, "mcpServers": {"lab": {}}}')
        self.assertEqual(self.changed(), [str(inner)])

    def test_unparseable_claude_json_fails_closed(self) -> None:
        self.claude_json.write_text("{not json")
        self.assertEqual(self.changed(), [str(self.claude_json)])


if __name__ == "__main__":
    unittest.main()
