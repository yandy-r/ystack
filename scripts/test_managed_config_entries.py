#!/usr/bin/env python3
"""Tests for merge_managed_config.py entry selection (--entries / --list-entries).

Run directly (``python3 scripts/test_managed_config_entries.py``) or through
``./scripts/validate.sh --only config``.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from typing import Any

from managed_config_entries import item_key, marketplace_of

REPO_ROOT = Path(__file__).resolve().parent.parent
HELPER = REPO_ROOT / "scripts" / "merge_managed_config.py"

SERVERS = {
    "github": {"url": "https://github"},
    "linear": {"url": "https://linear"},
    "stripe": {"url": "https://stripe"},
}


class EntrySelectionTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.state = self.tmp / "state.json"
        self.addCleanup(self._tmp.cleanup)
        self.source = self.tmp / "mcp.json"
        self.source.write_text(json.dumps({"mcpServers": SERVERS}), encoding="utf-8")
        self.dest = self.tmp / "dest.json"

    def run_helper(
        self, *extra: str, profile: str = "claude-mcp", source: Path | None = None, dest: Path | None = None
    ) -> subprocess.CompletedProcess[str]:
        env = {**os.environ, "YCC_MANAGED_CONFIG_STATE": str(self.state)}
        argv = [
            sys.executable, str(HELPER), "--profile", profile,
            "--source", str(source or self.source),
            "--destination", str(dest or self.dest),
            "--groups", "mcp", *extra,
        ]  # fmt: skip
        return subprocess.run(argv, capture_output=True, text=True, env=env)

    def servers(self) -> dict[str, Any]:
        servers: dict[str, Any] = json.loads(self.dest.read_text(encoding="utf-8")).get("mcpServers", {})
        return servers

    def test_list_entries_prints_managed_names(self) -> None:
        result = self.run_helper("--list-entries")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["github", "linear", "stripe"])
        self.assertFalse(self.dest.exists())

    def test_merge_only_selected_entries(self) -> None:
        result = self.run_helper("--entries", "github,linear")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(self.servers()), ["github", "linear"])

    def test_partial_sync_does_not_prune_other_managed_entries(self) -> None:
        self.assertEqual(self.run_helper().returncode, 0)
        result = self.run_helper("--entries", "github")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(self.servers()), ["github", "linear", "stripe"])
        # Ownership of the unselected entries survives: a full remove still takes them.
        self.assertEqual(self.run_helper("--remove").returncode, 0)
        self.assertFalse(self.dest.exists())

    def test_unknown_entry_fails_without_writing(self) -> None:
        result = self.run_helper("--entries", "github,bogus")
        self.assertEqual(result.returncode, 1)
        self.assertIn("bogus", result.stderr)
        self.assertIn("managed: github, linear, stripe", result.stderr)
        self.assertFalse(self.dest.exists())

    def test_remove_only_selected_entries(self) -> None:
        self.assertEqual(self.run_helper().returncode, 0)
        result = self.run_helper("--remove", "--entries", "stripe")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(self.servers()), ["github", "linear"])

    def test_toml_selection(self) -> None:
        source = self.tmp / "config.toml"
        source.write_text(
            '[mcp_servers.github]\nurl = "https://github"\n\n[mcp_servers.playwright]\ncommand = "npx"\n',
            encoding="utf-8",
        )
        dest = self.tmp / "dest.toml"
        result = self.run_helper("--entries", "playwright", profile="codex-config", source=source, dest=dest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(tomllib.loads(dest.read_text(encoding="utf-8"))["mcp_servers"]), ["playwright"])


PACKAGE_RULE = {"path": ["plugins"], "policy": "list-union", "item_key": "package"}
NAME_RULE = {"path": ["pluginMarketplaces"], "policy": "list-union", "item_key": "name"}


class ItemKeyTestCase(unittest.TestCase):
    def test_package_keys_strip_versions_but_not_paths(self) -> None:
        cases: list[tuple[object, str | None]] = [
            ("pkg", "pkg"),
            ("pkg@1.2.3", "pkg"),
            ("@s/p", "@s/p"),
            ("@s/p@1.2.3", "@s/p"),
            ("  @s/p@1  ", "@s/p"),
            ({"package": "@s/p@1"}, "@s/p"),
            ({"package": "p", "options": {}}, "p"),
            ("./ycc-sensitive-guard/", "./ycc-sensitive-guard"),
            ("file:../x", "file:../x"),
            ("npm:alias@1", "npm:alias"),
            ("npm:@s/x@1", "npm:@s/x"),
            ("npm:@s/x", "npm:@s/x"),
            ("npm:", None),
            ("git+https://example.com/x.git#v1.2", "git+https://example.com/x.git"),
            ("https://example.com/x/#main", "https://example.com/x"),
            ("github:owner/repo#abc123", "github:owner/repo"),
            ("file:../x#frag", "file:../x#frag"),
            ("./local@1", "./local@1"),
            ("", None),
            (3, None),
            ({"options": {}}, None),
            ({"package": 3}, None),
        ]
        for item, expected in cases:
            with self.subTest(item=item):
                self.assertEqual(item_key(PACKAGE_RULE, item), expected)

    def test_name_keys_need_a_non_empty_name(self) -> None:
        self.assertEqual(item_key(NAME_RULE, {"name": "mkt", "url": "u"}), "mkt")
        for item in ({"name": ""}, {"url": "u"}, "mkt", {"name": 3}):
            with self.subTest(item=item):
                self.assertIsNone(item_key(NAME_RULE, item))

    def test_marketplace_of(self) -> None:
        self.assertEqual(marketplace_of("a@m"), "m")
        self.assertEqual(marketplace_of("a@b@m"), "m")
        self.assertIsNone(marketplace_of("a"))
        self.assertIsNone(marketplace_of("a@"))


CLAUDE_PLUGINS: dict[str, Any] = {
    "enabledPlugins": {
        "ycc@ycc": True,
        "superpowers@claude-plugins-official": True,
        "context7@claude-plugins-official": True,
    },
    "extraKnownMarketplaces": {
        "ycc": {"source": {"source": "github", "repo": "yandy-r/ystack"}},
        "yci": {"source": {"source": "github", "repo": "yandy-r/claude-infra-plugins"}},
        "claude-plugins-official": {"source": {"source": "github", "repo": "anthropics/claude-plugins-official"}},
    },
    "pluginMarketplaces": [{"name": "claude-plugins-official", "url": "https://official"}],
}


class PluginSelectionTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.state = self.tmp / "state.json"
        self.dest = self.tmp / "settings.json"
        self.source = self.tmp / "settings-src.json"
        self.source.write_text(json.dumps({"model": "m", **CLAUDE_PLUGINS}), encoding="utf-8")

    def run_helper(
        self, *extra: str, profile: str = "claude-settings", groups: str = "plugins", source: Path | None = None
    ) -> subprocess.CompletedProcess[str]:
        env = {**os.environ, "YCC_MANAGED_CONFIG_STATE": str(self.state)}
        argv = [
            sys.executable, str(HELPER), "--profile", profile,
            "--source", str(source or self.source), "--destination", str(self.dest),
            "--groups", groups, *extra,
        ]  # fmt: skip
        return subprocess.run(argv, capture_output=True, text=True, env=env)

    def dest_json(self) -> dict[str, Any]:
        payload: dict[str, Any] = json.loads(self.dest.read_text(encoding="utf-8"))
        return payload

    def state_entry(self) -> dict[str, Any]:
        entry: dict[str, Any] = json.loads(self.state.read_text(encoding="utf-8"))[f"claude-settings:{self.dest}"]
        return entry

    def test_list_entries_prints_plugins_without_marketplaces(self) -> None:
        result = self.run_helper("--list-entries")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.split(),
            ["ycc@ycc", "superpowers@claude-plugins-official", "context7@claude-plugins-official"],
        )

    def test_repo_claude_settings_list_only_enabled_plugins(self) -> None:
        source = REPO_ROOT / "ycc" / "settings" / "settings.json"
        result = self.run_helper("--list-entries", source=source)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = list(json.loads(source.read_text(encoding="utf-8"))["enabledPlugins"])
        self.assertEqual(result.stdout.split(), expected)
        self.assertNotIn("claude-plugins-official", result.stdout.split())

    def test_selecting_one_plugin_writes_it_and_its_marketplace(self) -> None:
        result = self.run_helper("--entries", "superpowers@claude-plugins-official")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.dest_json(),
            {
                "enabledPlugins": {"superpowers@claude-plugins-official": True},
                "extraKnownMarketplaces": {
                    "claude-plugins-official": CLAUDE_PLUGINS["extraKnownMarketplaces"]["claude-plugins-official"]
                },
                "pluginMarketplaces": CLAUDE_PLUGINS["pluginMarketplaces"],
            },
        )

    def test_selective_sync_leaves_other_entries_and_their_state_untouched(self) -> None:
        self.assertEqual(self.run_helper().returncode, 0)
        before = self.state_entry()
        destination = self.dest_json()
        # A newer repo value for the selected plugin; a user edit on an unselected one.
        destination["enabledPlugins"]["ycc@ycc"] = False
        self.dest.write_text(json.dumps(destination), encoding="utf-8")
        changed = json.loads(self.source.read_text(encoding="utf-8"))
        changed["enabledPlugins"]["context7@claude-plugins-official"] = False
        changed["enabledPlugins"]["superpowers@claude-plugins-official"] = False
        self.source.write_text(json.dumps(changed), encoding="utf-8")

        result = self.run_helper("--entries", "superpowers@claude-plugins-official")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("kept your local value", result.stdout)
        plugins = self.dest_json()["enabledPlugins"]
        self.assertEqual(
            plugins,
            {
                "ycc@ycc": False,
                "superpowers@claude-plugins-official": False,
                "context7@claude-plugins-official": True,
            },
        )
        after = self.state_entry()
        selected_key = "/enabledPlugins/superpowers@claude-plugins-official"
        self.assertNotEqual(after[selected_key], before[selected_key])
        self.assertEqual(
            {k: v for k, v in after.items() if k != selected_key},
            {k: v for k, v in before.items() if k != selected_key},
        )

    def test_plugin_on_own_marketplace_writes_no_marketplace_list(self) -> None:
        result = self.run_helper("--entries", "ycc@ycc")
        self.assertEqual(result.returncode, 0, result.stderr)
        destination = self.dest_json()
        self.assertEqual(list(destination), ["enabledPlugins", "extraKnownMarketplaces"])
        self.assertEqual(list(destination["extraKnownMarketplaces"]), ["ycc"])
        self.assertNotIn("/pluginMarketplaces", self.state_entry())

    def test_marketplace_name_is_not_an_entry(self) -> None:
        result = self.run_helper("--entries", "claude-plugins-official")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown entries claude-plugins-official", result.stderr)
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.state.exists())

    def test_entry_groups_must_be_a_subset_of_groups(self) -> None:
        result = self.run_helper("--entry-groups", "mcp", "--entries", "ycc@ycc")
        self.assertEqual(result.returncode, 1)
        self.assertIn("--entry-groups mcp", result.stderr)
        self.assertFalse(self.dest.exists())

    def test_entry_groups_keep_other_groups_whole(self) -> None:
        result = self.run_helper("--entry-groups", "plugins", "--entries", "ycc@ycc", groups="settings,plugins")
        self.assertEqual(result.returncode, 0, result.stderr)
        destination = self.dest_json()
        self.assertEqual(destination["model"], "m")
        self.assertEqual(destination["enabledPlugins"], {"ycc@ycc": True})

    def test_opencode_entry_groups_merge_deep_settings_whole(self) -> None:
        source = self.tmp / "opencode-src.json"
        source.write_text(
            json.dumps(
                {
                    "agents": {"a": {"model": "x"}, "b": {"model": "y"}},
                    "providers": {"p": {"npm": "n"}},
                    "plugins": ["@s/goal@1.0.0", "./guard"],
                }
            ),
            encoding="utf-8",
        )
        listed = self.run_helper(
            "--entry-groups", "plugins", "--list-entries", profile="opencode-config", groups="settings,plugins",
            source=source,
        )  # fmt: skip
        self.assertEqual(listed.stdout.split(), ["@s/goal", "./guard"])

        result = self.run_helper(
            "--entry-groups", "plugins", "--entries", "@s/goal", profile="opencode-config",
            groups="settings,plugins", source=source,
        )  # fmt: skip

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.dest_json(),
            {
                "agents": {"a": {"model": "x"}, "b": {"model": "y"}},
                "providers": {"p": {"npm": "n"}},
                "plugins": ["@s/goal@1.0.0"],
            },
        )

    def test_entries_without_entry_groups_still_filter_every_group(self) -> None:
        source = self.tmp / "opencode-src.json"
        source.write_text(json.dumps({"agents": {"a": {"model": "x"}}, "plugins": ["p"]}), encoding="utf-8")
        result = self.run_helper("--entries", "a", profile="opencode-config", groups="settings,plugins", source=source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dest_json(), {"agents": {"a": {"model": "x"}}})


if __name__ == "__main__":
    unittest.main(verbosity=2)
