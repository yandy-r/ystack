#!/usr/bin/env python3
"""Unit tests for scripts/merge_managed_config.py.

Run directly (``python3 scripts/test_merge_managed_config.py``) or through
``./scripts/validate.sh --only config``.
"""

from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

import yaml
from merge_managed_config import (
    ADDED_ITEMS_KEY,
    PROFILES,
    PROJECT_GROUP,
    PROJECT_IGNORED_KEYS,
    check_project_ignored_keys,
    project_subset,
    value_hash,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
HELPER = REPO_ROOT / "scripts" / "merge_managed_config.py"


class MergeBase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.state = self.tmp / "state.json"
        self.addCleanup(self._tmp.cleanup)

    def run_merge(
        self,
        profile: str,
        source: Path,
        destination: Path,
        groups: str,
        *,
        force: bool = False,
        expect_success: bool = True,
        extra: tuple[str, ...] = (),
    ) -> subprocess.CompletedProcess[str]:
        env = {**os.environ, "YCC_MANAGED_CONFIG_STATE": str(self.state)}
        argv = [
            sys.executable,
            str(HELPER),
            "--profile",
            profile,
            "--source",
            str(source),
            "--destination",
            str(destination),
            "--groups",
            groups,
        ]
        if force:
            argv.append("--force")
        argv.extend(extra)
        result = subprocess.run(argv, capture_output=True, text=True, env=env)
        if expect_success:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def write_json(self, path: Path, payload: dict) -> Path:
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return path


class MergeHelperTestCase(MergeBase):
    # -- JSON merge ------------------------------------------------------

    def test_creates_missing_destination(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"model": "claude-fable-5-1"})
        destination = self.tmp / "dest.json"

        self.run_merge("claude-settings", source, destination, "settings")

        self.assertEqual(json.loads(destination.read_text())["model"], "claude-fable-5-1")

    def test_preserves_unknown_destination_keys(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"model": "claude-fable-5-1"})
        destination = self.write_json(
            self.tmp / "dest.json",
            {"userOnlyKey": {"nested": True}, "tui": "fullscreen"},
        )

        self.run_merge("claude-settings", source, destination, "settings")

        merged = json.loads(destination.read_text())
        self.assertEqual(merged["userOnlyKey"], {"nested": True})
        self.assertEqual(merged["tui"], "fullscreen")
        self.assertEqual(merged["model"], "claude-fable-5-1")

    def test_object_policy_preserves_sibling_leaves(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"env": {"FORCE_AUTOUPDATE_PLUGINS": "1"}})
        destination = self.write_json(self.tmp / "dest.json", {"env": {"USER_TOKEN": "secret"}})

        self.run_merge("claude-settings", source, destination, "settings")

        env = json.loads(destination.read_text())["env"]
        self.assertEqual(env["USER_TOKEN"], "secret")
        self.assertEqual(env["FORCE_AUTOUPDATE_PLUGINS"], "1")

    def test_map_entries_preserve_unknown_entries(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"mcpServers": {"github": {"url": "https://example"}}})
        destination = self.write_json(self.tmp / "dest.json", {"mcpServers": {"private": {"url": "https://local"}}})

        self.run_merge("claude-mcp", source, destination, "mcp")

        servers = json.loads(destination.read_text())["mcpServers"]
        self.assertIn("private", servers)
        self.assertIn("github", servers)

    def test_list_union_preserves_user_entries(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"plugins": ["@repo/plugin"]})
        destination = self.write_json(self.tmp / "dest.json", {"plugins": ["@user/plugin"]})

        self.run_merge("opencode-config", source, destination, "plugins")

        self.assertEqual(json.loads(destination.read_text())["plugins"], ["@user/plugin", "@repo/plugin"])

    def test_local_edit_wins_without_force(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"model": "claude-fable-5-1"})
        destination = self.write_json(self.tmp / "dest.json", {"model": "opus[1m]"})

        result = self.run_merge("claude-settings", source, destination, "settings")

        self.assertEqual(json.loads(destination.read_text())["model"], "opus[1m]")
        self.assertIn("kept your local value", result.stdout)

    def test_force_overrides_local_edit(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"model": "claude-fable-5-1"})
        destination = self.write_json(self.tmp / "dest.json", {"model": "opus[1m]"})

        self.run_merge("claude-settings", source, destination, "settings", force=True)

        self.assertEqual(json.loads(destination.read_text())["model"], "claude-fable-5-1")

    def test_repo_update_applies_when_user_never_edited(self) -> None:
        source = self.tmp / "src.json"
        destination = self.tmp / "dest.json"
        self.write_json(source, {"model": "claude-fable-5-1"})

        self.run_merge("claude-settings", source, destination, "settings")
        self.write_json(source, {"model": "claude-fable-6"})
        self.run_merge("claude-settings", source, destination, "settings")

        self.assertEqual(json.loads(destination.read_text())["model"], "claude-fable-6")

    def test_repo_update_defers_to_later_user_edit(self) -> None:
        source = self.tmp / "src.json"
        destination = self.tmp / "dest.json"
        self.write_json(source, {"model": "claude-fable-5-1"})

        self.run_merge("claude-settings", source, destination, "settings")
        self.write_json(destination, {"model": "user-choice"})
        self.write_json(source, {"model": "claude-fable-6"})
        self.run_merge("claude-settings", source, destination, "settings")

        self.assertEqual(json.loads(destination.read_text())["model"], "user-choice")

    def test_idempotent(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"model": "claude-fable-5-1"})
        destination = self.tmp / "dest.json"

        self.run_merge("claude-settings", source, destination, "settings")
        first = destination.read_text()
        result = self.run_merge("claude-settings", source, destination, "settings")

        self.assertEqual(destination.read_text(), first)
        self.assertIn("up-to-date", result.stdout)

    def test_symlink_destination_becomes_real_file(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"model": "claude-fable-5-1"})
        target = self.write_json(self.tmp / "repo-owned.json", {"tui": "fullscreen"})
        destination = self.tmp / "dest.json"
        destination.symlink_to(target)

        self.run_merge("claude-settings", source, destination, "settings")

        self.assertFalse(destination.is_symlink())
        self.assertEqual(json.loads(target.read_text()), {"tui": "fullscreen"})
        self.assertEqual(json.loads(destination.read_text())["model"], "claude-fable-5-1")

    def test_invalid_destination_json_fails_without_mutation(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"model": "claude-fable-5-1"})
        destination = self.tmp / "dest.json"
        destination.write_text("{ not json", encoding="utf-8")

        result = self.run_merge("claude-settings", source, destination, "settings", expect_success=False)

        self.assertEqual(result.returncode, 1)
        self.assertEqual(destination.read_text(), "{ not json")

    def test_state_file_stores_hashes_only(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"env": {"TOKEN": "super-secret-value"}})
        destination = self.tmp / "dest.json"

        self.run_merge("claude-settings", source, destination, "settings")

        self.assertNotIn("super-secret-value", self.state.read_text())
        self.assertIn("last_applied_sha256", self.state.read_text())

    def test_unknown_group_fails(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"model": "x"})
        destination = self.tmp / "dest.json"

        result = self.run_merge("claude-settings", source, destination, "nope", expect_success=False)

        self.assertEqual(result.returncode, 1)
        self.assertFalse(destination.exists())

    # -- TOML merge ------------------------------------------------------

    def test_toml_preserves_comments_and_unmanaged_tables(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text('model = "gpt-6-astra"\n', encoding="utf-8")
        destination = self.tmp / "dest.toml"
        destination.write_text(
            '# my machine\nmodel = "gpt-5.6-sol"\n\n[projects."/home/me/work"]\ntrust_level = "trusted"\n',
            encoding="utf-8",
        )

        self.run_merge("codex-config", source, destination, "settings", force=True)

        text = destination.read_text()
        self.assertIn("# my machine", text)
        self.assertIn('[projects."/home/me/work"]', text)
        self.assertEqual(tomllib.loads(text)["model"], "gpt-6-astra")
        self.assertEqual(tomllib.loads(text)["projects"]["/home/me/work"]["trust_level"], "trusted")

    def test_toml_adds_missing_table(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text('[agents]\ndefault_subagent_model = "gpt-5.6-sol"\n', encoding="utf-8")
        destination = self.tmp / "dest.toml"
        destination.write_text('model = "gpt-6-astra"\n', encoding="utf-8")

        self.run_merge("codex-config", source, destination, "settings")

        parsed = tomllib.loads(destination.read_text())
        self.assertEqual(parsed["agents"]["default_subagent_model"], "gpt-5.6-sol")
        self.assertEqual(parsed["model"], "gpt-6-astra")

    def test_toml_appends_to_existing_table(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text('[agents]\ndefault_subagent_reasoning_effort = "high"\n', encoding="utf-8")
        destination = self.tmp / "dest.toml"
        destination.write_text("[agents]\nenabled = true\n\n[features]\napps = true\n", encoding="utf-8")

        self.run_merge("codex-config", source, destination, "settings")

        parsed = tomllib.loads(destination.read_text())
        self.assertEqual(parsed["agents"]["default_subagent_reasoning_effort"], "high")
        self.assertTrue(parsed["agents"]["enabled"])
        self.assertTrue(parsed["features"]["apps"])

    def test_toml_multiline_array_survives(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text('model = "gpt-6-astra"\n', encoding="utf-8")
        destination = self.tmp / "dest.toml"
        destination.write_text(
            'model = "old"\n\n[tui]\nstatus_line = [\n  "model-with-reasoning",\n  "git-branch",\n]\n',
            encoding="utf-8",
        )

        self.run_merge("codex-config", source, destination, "settings", force=True)

        parsed = tomllib.loads(destination.read_text())
        self.assertEqual(parsed["tui"]["status_line"], ["model-with-reasoning", "git-branch"])
        self.assertEqual(parsed["model"], "gpt-6-astra")

    def test_toml_root_key_inserted_above_tables(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text('model = "gpt-6-astra"\n', encoding="utf-8")
        destination = self.tmp / "dest.toml"
        destination.write_text("[features]\napps = true\n", encoding="utf-8")

        self.run_merge("codex-config", source, destination, "settings")

        parsed = tomllib.loads(destination.read_text())
        self.assertEqual(parsed["model"], "gpt-6-astra")
        self.assertTrue(parsed["features"]["apps"])

    def test_toml_updates_existing_nested_table_leaf(self) -> None:
        """Regression: nested managed tables must patch leaf-wise, not append."""
        source = self.tmp / "src.toml"
        source.write_text('[mcp_servers.github]\nurl = "https://api.githubcopilot.com/mcp"\n', encoding="utf-8")
        destination = self.tmp / "dest.toml"
        destination.write_text(
            '[mcp_servers.github]\nurl = "https://old"\nbearer_token_env_var = "MY_TOKEN"\n',
            encoding="utf-8",
        )

        self.run_merge("codex-config", source, destination, "mcp", force=True)

        parsed = tomllib.loads(destination.read_text())
        self.assertEqual(parsed["mcp_servers"]["github"]["url"], "https://api.githubcopilot.com/mcp")
        self.assertEqual(parsed["mcp_servers"]["github"]["bearer_token_env_var"], "MY_TOKEN")

    def test_toml_updates_existing_quoted_plugin_table(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text('[plugins."ycc@local-ycc-plugins"]\nenabled = true\n', encoding="utf-8")
        destination = self.tmp / "dest.toml"
        destination.write_text('[plugins."ycc@local-ycc-plugins"]\nenabled = false\n', encoding="utf-8")

        self.run_merge("codex-config", source, destination, "plugins", force=True)

        parsed = tomllib.loads(destination.read_text())
        self.assertTrue(parsed["plugins"]["ycc@local-ycc-plugins"]["enabled"])

    def test_toml_agents_table_update_is_not_duplicated(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text('[agents]\ndefault_subagent_model = "gpt-5.6-sol"\n', encoding="utf-8")
        destination = self.tmp / "dest.toml"
        destination.write_text('[agents]\ndefault_subagent_model = "old-model"\n', encoding="utf-8")

        self.run_merge("codex-config", source, destination, "settings", force=True)

        text = destination.read_text()
        self.assertEqual(text.count("[agents]"), 1)
        self.assertEqual(tomllib.loads(text)["agents"]["default_subagent_model"], "gpt-5.6-sol")

    def test_force_repairs_duplicate_managed_toml(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text(
            'approval_policy = "on-request"\n'
            'approvals_reviewer = "auto_review"\n'
            'sandbox_mode = "workspace-write"\n\n'
            "[sandbox_workspace_write]\n"
            "network_access = true\n",
            encoding="utf-8",
        )
        destination = self.tmp / "dest.toml"
        original = (
            'approvals_reviewer = "user"\n'
            'approvals_reviewer = "auto_review"\n\n'
            "[sandbox_workspace_write]\n"
            "network_access = false\n\n"
            '[projects."/home/me/work"]\n'
            'trust_level = "trusted"\n\n'
            "[sandbox_workspace_write]\n"
            "network_access = true\n"
        )
        destination.write_text(original, encoding="utf-8")

        failed = self.run_merge("codex-config", source, destination, "settings", force=False, expect_success=False)
        self.assertEqual(failed.returncode, 1)
        self.assertEqual(destination.read_text(), original)

        self.run_merge("codex-config", source, destination, "settings", force=True)

        text = destination.read_text()
        parsed = tomllib.loads(text)
        self.assertEqual(text.count("approvals_reviewer ="), 1)
        self.assertEqual(text.count("[sandbox_workspace_write]"), 1)
        self.assertEqual(parsed["approval_policy"], "on-request")
        self.assertEqual(parsed["approvals_reviewer"], "auto_review")
        self.assertEqual(parsed["sandbox_mode"], "workspace-write")
        self.assertTrue(parsed["sandbox_workspace_write"]["network_access"])
        self.assertEqual(parsed["projects"]["/home/me/work"]["trust_level"], "trusted")

    def test_force_rejects_unrelated_invalid_toml_without_mutation(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text('model = "gpt-6-astra"\n', encoding="utf-8")
        destination = self.tmp / "dest.toml"
        original = '[user_config]\nvalue = "first"\nvalue = "second"\n'
        destination.write_text(original, encoding="utf-8")

        result = self.run_merge("codex-config", source, destination, "settings", force=True, expect_success=False)

        self.assertEqual(result.returncode, 1)
        self.assertEqual(destination.read_text(), original)

    def test_real_codex_config_merges_into_existing_config(self) -> None:
        """End-to-end guard against the committed Codex source shape."""
        source = REPO_ROOT / ".codex-plugin" / "config" / "config.toml"
        destination = self.tmp / "config.toml"
        destination.write_text(
            '# local\nmodel = "gpt-5.6-sol"\n\n'
            '[mcp_servers.github]\nurl = "https://old"\n\n'
            '[projects."/home/me/work"]\ntrust_level = "trusted"\n',
            encoding="utf-8",
        )

        self.run_merge("codex-config", source, destination, "settings,mcp,plugins", force=True)

        parsed = tomllib.loads(destination.read_text())
        self.assertEqual(parsed["model"], "gpt-6-astra")
        self.assertEqual(parsed["agents"]["default_subagent_reasoning_effort"], "high")
        self.assertEqual(
            parsed["mcp_servers"]["github"]["command"],
            "sh",
        )
        self.assertIn("mcp-remote https://api.githubcopilot.com/mcp/", parsed["mcp_servers"]["github"]["args"][1])
        self.assertEqual(parsed["projects"]["/home/me/work"]["trust_level"], "trusted")

    def test_provider_credentials_survive_model_variant_merge(self) -> None:
        """Regression: deep merge must add variants without dropping apiKey."""
        source = REPO_ROOT / ".opencode-plugin" / "opencode.json"
        destination = self.tmp / "opencode.json"
        self.write_json(
            destination,
            {
                "providers": {
                    "openai": {"settings": {"apiKey": "{env:MY_KEY}", "baseURL": "https://proxy.local/v1"}},
                    "9router": {"options": {"apiKey": "sk-private"}},
                }
            },
        )

        self.run_merge("opencode-config", source, destination, "settings")

        providers = json.loads(destination.read_text())["providers"]
        self.assertEqual(providers["openai"]["settings"]["apiKey"], "{env:MY_KEY}")
        self.assertEqual(providers["openai"]["settings"]["baseURL"], "https://proxy.local/v1")
        self.assertEqual(providers["9router"]["options"]["apiKey"], "sk-private")
        main_model = json.loads((REPO_ROOT / "ycc/settings/models.json").read_text(encoding="utf-8"))["targets"][
            "opencode"
        ]["main"]["model"].split("/", 1)[1]
        self.assertEqual(providers["openai"]["models"][main_model]["variants"][0]["id"], "subagent")

    def test_opencode_clean_install_sets_subagent_depth(self) -> None:
        source = REPO_ROOT / ".opencode-plugin" / "opencode.json"
        destination = self.tmp / "opencode.json"

        self.run_merge("opencode-config", source, destination, "settings")

        self.assertEqual(json.loads(destination.read_text())["experimental"]["subagent_depth"], 2)

    def test_opencode_depth_merge_preserves_unrelated_experimental_settings(self) -> None:
        source = self.write_json(
            self.tmp / "source.json", {"experimental": {"subagent_depth": 2, "other_toggle": False}}
        )
        destination = self.write_json(self.tmp / "opencode.json", {"experimental": {"other_toggle": True}})

        self.run_merge("opencode-config", source, destination, "settings", force=True)

        self.assertEqual(
            json.loads(destination.read_text())["experimental"],
            {"subagent_depth": 2, "other_toggle": True},
        )
        self.assertNotIn("/experimental/other_toggle", self.state.read_text())

    def test_opencode_depth_updates_follow_managed_ownership(self) -> None:
        source = self.write_json(self.tmp / "source.json", {"experimental": {"subagent_depth": 1}})
        destination = self.tmp / "opencode.json"
        self.run_merge("opencode-config", source, destination, "settings")

        # Previously managed, unchanged value follows the new bundle default.
        self.write_json(source, {"experimental": {"subagent_depth": 2}})
        self.run_merge("opencode-config", source, destination, "settings")
        self.assertEqual(json.loads(destination.read_text())["experimental"]["subagent_depth"], 2)

        # A later local edit wins unless force was explicitly requested.
        self.write_json(destination, {"experimental": {"subagent_depth": 4, "other_toggle": True}})
        self.run_merge("opencode-config", source, destination, "settings")
        self.assertEqual(json.loads(destination.read_text())["experimental"]["subagent_depth"], 4)
        self.run_merge("opencode-config", source, destination, "settings", force=True)
        self.assertEqual(
            json.loads(destination.read_text())["experimental"],
            {"subagent_depth": 2, "other_toggle": True},
        )

    def test_opencode_existing_unmanaged_depth_is_preserved(self) -> None:
        source = REPO_ROOT / ".opencode-plugin" / "opencode.json"
        destination = self.write_json(self.tmp / "opencode.json", {"experimental": {"subagent_depth": 3}})

        self.run_merge("opencode-config", source, destination, "settings")

        self.assertEqual(json.loads(destination.read_text())["experimental"]["subagent_depth"], 3)

    def test_opencode_mcp_servers_merge_under_servers_key(self) -> None:
        source = REPO_ROOT / ".opencode-plugin" / "opencode.json"
        destination = self.tmp / "opencode.json"
        self.write_json(destination, {"mcp": {"servers": {"private": {"type": "remote", "url": "https://internal"}}}})

        self.run_merge("opencode-config", source, destination, "mcp")

        servers = json.loads(destination.read_text())["mcp"]["servers"]
        self.assertIn("private", servers)
        self.assertIn("github", servers)

    def test_opencode_accepts_jsonc_destination(self) -> None:
        source = REPO_ROOT / ".opencode-plugin" / "opencode.json"
        destination = self.tmp / "opencode.json"
        destination.write_text(
            '{\n  // mine\n  "mcp": {\n    "servers": {\n'
            '      "private": { "type": "remote", "url": "https://x/a,}//b" },\n'
            "    }, /* block */\n  },\n}\n",
            encoding="utf-8",
        )

        result = self.run_merge("opencode-config", source, destination, "mcp")

        self.assertIn("JSONC", result.stdout)
        servers = json.loads(destination.read_text())["mcp"]["servers"]
        self.assertEqual(servers["private"]["url"], "https://x/a,}//b")
        self.assertIn("github", servers)

    def test_strict_json_profiles_reject_trailing_commas(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"model": "claude-fable-5-1"})
        destination = self.tmp / "dest.json"
        destination.write_text('{"tui": "fullscreen",}\n', encoding="utf-8")

        result = self.run_merge("claude-settings", source, destination, "settings", expect_success=False)

        self.assertNotEqual(result.returncode, 0)

    def test_dry_run_does_not_touch_symlink(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"model": "claude-fable-5-1"})
        target = self.write_json(self.tmp / "target.json", {"tui": "fullscreen"})
        destination = self.tmp / "dest.json"
        destination.symlink_to(target)

        env = {**os.environ, "YCC_MANAGED_CONFIG_STATE": str(self.state)}
        subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--profile",
                "claude-settings",
                "--source",
                str(source),
                "--destination",
                str(destination),
                "--groups",
                "settings",
                "--dry-run",
            ],
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )

        self.assertTrue(destination.is_symlink())

    def test_invalid_source_leaves_symlink_intact(self) -> None:
        source = self.tmp / "src.json"
        source.write_text("{ broken", encoding="utf-8")
        target = self.write_json(self.tmp / "target.json", {"tui": "fullscreen"})
        destination = self.tmp / "dest.json"
        destination.symlink_to(target)

        self.run_merge("claude-settings", source, destination, "settings", expect_success=False)

        self.assertTrue(destination.is_symlink())

    def test_symlink_replacement_preserves_restrictive_mode(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"model": "claude-fable-5-1"})
        target = self.write_json(self.tmp / "target.json", {"tui": "fullscreen"})
        target.chmod(0o600)
        destination = self.tmp / "dest.json"
        destination.symlink_to(target)

        self.run_merge("claude-settings", source, destination, "settings")

        self.assertFalse(destination.is_symlink())
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)

    def test_first_run_equal_values_are_adopted_for_future_updates(self) -> None:
        """Regression: an already-matching config must still become tool-owned."""
        source = self.tmp / "src.json"
        destination = self.tmp / "dest.json"
        self.write_json(source, {"model": "claude-fable-5-1"})
        self.write_json(destination, {"model": "claude-fable-5-1"})

        self.run_merge("claude-settings", source, destination, "settings")
        self.write_json(source, {"model": "claude-fable-6"})
        self.run_merge("claude-settings", source, destination, "settings")

        self.assertEqual(json.loads(destination.read_text())["model"], "claude-fable-6")

    def test_state_write_failure_rolls_back_config(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"model": "claude-fable-5-1"})
        destination = self.write_json(self.tmp / "dest.json", {"tui": "fullscreen"})
        blocked_state = self.tmp / "blocked"
        blocked_state.write_text("not a directory", encoding="utf-8")

        env = {**os.environ, "YCC_MANAGED_CONFIG_STATE": str(blocked_state / "state.json")}
        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--profile",
                "claude-settings",
                "--source",
                str(source),
                "--destination",
                str(destination),
                "--groups",
                "settings",
            ],
            capture_output=True,
            text=True,
            env=env,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(destination.read_text()), {"tui": "fullscreen"})

    def test_cursor_fresh_install_writes_required_permission_keys(self) -> None:
        source = REPO_ROOT / "packages/cursor/installer-fallback/config/cli-config.json"
        destination = self.tmp / "cli-config.json"

        self.run_merge("cursor-cli", source, destination, "settings")

        merged = json.loads(destination.read_text())
        self.assertEqual(merged["permissions"]["allow"], [])
        self.assertEqual(merged["permissions"]["deny"], [])
        self.assertEqual(merged["model"]["modelId"], "claude-fable-5-1")

    def test_cursor_hooks_merge_appends_and_preserves_foreign(self) -> None:
        source = REPO_ROOT / "packages/cursor/ycc-hooks/hooks/hooks.json"
        destination = self.write_json(
            self.tmp / "hooks.json",
            {
                "version": 1,
                "hooks": {
                    "sessionStart": [{"command": "echo foreign"}],
                    "afterShellExecution": [{"command": "echo other"}],
                },
                "custom": True,
            },
        )

        self.run_merge("cursor-hooks", source, destination, "hooks")

        merged = json.loads(destination.read_text())
        self.assertEqual(merged["version"], 1)
        self.assertEqual(merged["custom"], True)
        self.assertEqual(merged["hooks"]["sessionStart"][0]["command"], "echo foreign")
        self.assertEqual(merged["hooks"]["afterShellExecution"], [{"command": "echo other"}])
        ycc = merged["hooks"]["sessionStart"][1]["command"]
        self.assertEqual(ycc, f"bash {shlex.quote(str(Path.home() / '.cursor/hooks/herdr-session-start.sh'))} session")

    def test_cursor_hooks_merge_is_idempotent(self) -> None:
        source = REPO_ROOT / "packages/cursor/ycc-hooks/hooks/hooks.json"
        destination = self.tmp / "hooks.json"

        self.run_merge("cursor-hooks", source, destination, "hooks")
        self.run_merge("cursor-hooks", source, destination, "hooks")

        merged = json.loads(destination.read_text())
        self.assertEqual(len(merged["hooks"]["sessionStart"]), 1)

    def test_cursor_hooks_command_preserves_shell_sensitive_home(self) -> None:
        source = REPO_ROOT / "packages/cursor/ycc-hooks/hooks/hooks.json"
        for name in ("josé", "space and 'quote'", "$HOME", "`echo expanded`", "$(echo expanded)"):
            with self.subTest(home=name):
                home = self.tmp / name
                script = home / ".cursor/hooks/herdr-session-start.sh"
                script.parent.mkdir(parents=True)
                script.write_text("printf '%s' \"$1\"\n", encoding="utf-8")
                destination = home / ".cursor/hooks.json"
                with patch.dict(os.environ, {"HOME": str(home)}):
                    self.run_merge("cursor-hooks", source, destination, "hooks")
                command = json.loads(destination.read_text())["hooks"]["sessionStart"][0]["command"]
                result = subprocess.run(["sh", "-c", command], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "session")

    def test_cursor_hooks_remove_rejects_unowned_registration(self) -> None:
        source = REPO_ROOT / "packages/cursor/ycc-hooks/hooks/hooks.json"
        destination = self.tmp / "hooks.json"
        self.run_merge("cursor-hooks", source, destination, "hooks")
        before = destination.read_bytes()
        self.state.unlink()

        for extra in (("--remove", "--dry-run"), ("--remove",)):
            result = self.run_merge("cursor-hooks", source, destination, "hooks", extra=extra, expect_success=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("registration still references the hook script", result.stderr)
            self.assertEqual(destination.read_bytes(), before)
            self.assertFalse(self.state.exists())

        self.run_merge("cursor-hooks", source, destination, "hooks", force=True, extra=("--remove",))
        if destination.exists():
            self.assertEqual(json.loads(destination.read_text())["hooks"]["sessionStart"], [])

    def test_cursor_hooks_remove_takes_back_only_own_entry(self) -> None:
        source = REPO_ROOT / "packages/cursor/ycc-hooks/hooks/hooks.json"
        destination = self.write_json(
            self.tmp / "hooks.json",
            {"version": 1, "hooks": {"sessionStart": [{"command": "echo foreign"}]}},
        )
        self.run_merge("cursor-hooks", source, destination, "hooks")

        self.run_merge("cursor-hooks", source, destination, "hooks", extra=("--remove",))

        merged = json.loads(destination.read_text())
        self.assertEqual(merged["hooks"]["sessionStart"], [{"command": "echo foreign"}])

    def test_cursor_hooks_invalid_destination_fails_closed(self) -> None:
        source = REPO_ROOT / "packages/cursor/ycc-hooks/hooks/hooks.json"
        destination = self.write_json(
            self.tmp / "hooks.json",
            {"version": 2, "hooks": {"sessionStart": "echo foreign"}},
        )

        result = self.run_merge("cursor-hooks", source, destination, "hooks", expect_success=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid Cursor hooks.json", result.stderr)
        self.assertEqual(json.loads(destination.read_text())["version"], 2)

    def test_cursor_hooks_foreign_herdr_collision_fails_closed(self) -> None:
        source = REPO_ROOT / "packages/cursor/ycc-hooks/hooks/hooks.json"
        destination = self.write_json(
            self.tmp / "hooks.json",
            {
                "version": 1,
                "hooks": {"sessionStart": [{"command": "bash ~/.cursor/hooks/herdr-session-start.sh other"}]},
            },
        )

        result = self.run_merge("cursor-hooks", source, destination, "hooks", expect_success=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ownership collision", result.stderr)
        self.assertEqual(len(json.loads(destination.read_text())["hooks"]["sessionStart"]), 1)

    def test_cursor_hooks_symlinked_destination_refused(self) -> None:
        source = REPO_ROOT / "packages/cursor/ycc-hooks/hooks/hooks.json"
        real = self.write_json(self.tmp / "real.json", {"version": 1, "hooks": {}})
        destination = self.tmp / "hooks.json"
        destination.symlink_to(real)

        result = self.run_merge("cursor-hooks", source, destination, "hooks", expect_success=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlinked", result.stderr)
        self.assertTrue(destination.is_symlink())

    def test_cursor_hooks_noncanonical_source_refused(self) -> None:
        source = self.write_json(
            self.tmp / "src.json",
            {"version": 1, "hooks": {"sessionStart": [{"command": "echo anything"}]}},
        )
        destination = self.tmp / "hooks.json"

        result = self.run_merge("cursor-hooks", source, destination, "hooks", expect_success=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("canonical herdr sessionStart command", result.stderr)
        self.assertFalse(destination.exists())

    def test_removed_managed_leaf_is_cleaned_up(self) -> None:
        """Repo transport changes must not leave stale managed fields behind."""
        source = self.tmp / "src.json"
        destination = self.tmp / "dest.json"
        self.write_json(source, {"mcpServers": {"svc": {"command": "npx", "args": ["-y", "old"]}}})

        self.run_merge("claude-mcp", source, destination, "mcp")
        self.write_json(source, {"mcpServers": {"svc": {"type": "http", "url": "https://example"}}})
        self.run_merge("claude-mcp", source, destination, "mcp")

        svc = json.loads(destination.read_text())["mcpServers"]["svc"]
        self.assertEqual(svc, {"type": "http", "url": "https://example"})

    def test_removal_skips_locally_edited_leaf(self) -> None:
        source = self.tmp / "src.json"
        destination = self.tmp / "dest.json"
        self.write_json(source, {"mcpServers": {"svc": {"command": "npx", "url": "https://old"}}})
        self.run_merge("claude-mcp", source, destination, "mcp")

        payload = json.loads(destination.read_text())
        payload["mcpServers"]["svc"]["command"] = "my-local-launcher"
        self.write_json(destination, payload)

        self.write_json(source, {"mcpServers": {"svc": {"url": "https://old"}}})
        self.run_merge("claude-mcp", source, destination, "mcp")

        svc = json.loads(destination.read_text())["mcpServers"]["svc"]
        self.assertEqual(svc["command"], "my-local-launcher")

    def test_removal_never_touches_unmanaged_keys(self) -> None:
        source = self.tmp / "src.json"
        destination = self.tmp / "dest.json"
        self.write_json(source, {"mcpServers": {"svc": {"url": "https://x"}}})
        self.write_json(destination, {"mcpServers": {"mine": {"url": "https://mine"}}, "other": 1})

        self.run_merge("claude-mcp", source, destination, "mcp")
        self.run_merge("claude-mcp", source, destination, "mcp")

        merged = json.loads(destination.read_text())
        self.assertEqual(merged["mcpServers"]["mine"], {"url": "https://mine"})
        self.assertEqual(merged["other"], 1)

    def test_toml_removed_managed_leaf_is_cleaned_up(self) -> None:
        source = self.tmp / "src.toml"
        destination = self.tmp / "dest.toml"
        source.write_text('[mcp_servers.svc]\ncommand = "npx"\nurl = "https://old"\n', encoding="utf-8")
        destination.write_text("# keep me\n", encoding="utf-8")

        self.run_merge("codex-config", source, destination, "mcp")
        source.write_text('[mcp_servers.svc]\nurl = "https://new"\n', encoding="utf-8")
        self.run_merge("codex-config", source, destination, "mcp", force=True)

        text = destination.read_text()
        parsed = tomllib.loads(text)
        self.assertIn("# keep me", text)
        self.assertEqual(parsed["mcp_servers"]["svc"], {"url": "https://new"})

    def test_toml_preserves_unknown_mcp_servers(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text('[mcp_servers.github]\nurl = "https://api.example/mcp"\n', encoding="utf-8")
        destination = self.tmp / "dest.toml"
        destination.write_text('[mcp_servers.private]\nurl = "https://internal"\n', encoding="utf-8")

        self.run_merge("codex-config", source, destination, "mcp")

        parsed = tomllib.loads(destination.read_text())
        self.assertIn("private", parsed["mcp_servers"])
        self.assertIn("github", parsed["mcp_servers"])

    # -- --remove ---------------------------------------------------------

    def remove(self, source: Path, destination: Path, *extra: str, **kwargs) -> subprocess.CompletedProcess[str]:
        return self.run_merge("claude-mcp", source, destination, "mcp", extra=("--remove", *extra), **kwargs)

    def mcp_source(self, servers: dict) -> Path:
        return self.write_json(self.tmp / "src.json", {"mcpServers": servers})

    def test_remove_keeps_user_servers_and_other_keys(self) -> None:
        source = self.mcp_source({"github": {"url": "https://gh"}, "svc": {"command": "x", "args": ["-y"]}})
        destination = self.write_json(
            self.tmp / "dest.json", {"projects": {"a": 1}, "mcpServers": {"mine": {"url": "https://mine"}}}
        )
        self.run_merge("claude-mcp", source, destination, "mcp")

        result = self.remove(source, destination)

        self.assertIn("removed 2 managed entries", result.stdout)
        self.assertEqual(
            json.loads(destination.read_text()), {"projects": {"a": 1}, "mcpServers": {"mine": {"url": "https://mine"}}}
        )
        state = json.loads(self.state.read_text())
        self.assertNotIn(f"claude-mcp:{destination}", state)

    def test_remove_skips_user_edited_server_unless_forced(self) -> None:
        source = self.mcp_source({"svc": {"url": "https://repo"}})
        destination = self.tmp / "dest.json"
        self.run_merge("claude-mcp", source, destination, "mcp")
        self.write_json(destination, {"mcpServers": {"svc": {"url": "https://edited"}}})

        result = self.remove(source, destination)
        self.assertIn("kept your local value at /mcpServers/svc", result.stdout)
        self.assertIn("svc", json.loads(destination.read_text())["mcpServers"])

        self.remove(source, destination, force=True)
        self.assertFalse(destination.exists())

    def test_remove_drops_server_no_longer_in_repo(self) -> None:
        destination = self.write_json(self.tmp / "dest.json", {"other": True})
        self.run_merge("claude-mcp", self.mcp_source({"old": {"url": "https://old"}}), destination, "mcp")

        self.remove(self.mcp_source({}), destination)

        self.assertEqual(json.loads(destination.read_text()), {"other": True})

    def test_remove_missing_destination_is_noop(self) -> None:
        destination = self.tmp / "dest.json"
        result = self.remove(self.mcp_source({"svc": {"url": "https://x"}}), destination)
        self.assertIn("nothing to remove", result.stdout)
        self.assertFalse(destination.exists())

    def test_remove_deletes_file_left_empty(self) -> None:
        source = self.mcp_source({"svc": {"url": "https://x"}})
        destination = self.tmp / "dest.json"
        self.run_merge("claude-mcp", source, destination, "mcp")

        result = self.remove(source, destination)

        self.assertIn("removed empty file", result.stdout)
        self.assertFalse(destination.exists())

    def test_remove_dry_run_writes_nothing(self) -> None:
        source = self.mcp_source({"svc": {"url": "https://x"}})
        destination = self.tmp / "dest.json"
        self.run_merge("claude-mcp", source, destination, "mcp")
        before = destination.read_text()

        result = self.remove(source, destination, "--dry-run")

        self.assertIn("would remove /mcpServers/svc", result.stdout)
        self.assertIn(f"would remove {destination}", result.stdout)
        self.assertEqual(destination.read_text(), before)

    def test_remove_toml_keeps_comments_and_user_tables(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text(
            '[mcp_servers.svc]\nurl = "https://x"\n\n[mcp_servers.svc.tools.a]\napproval_mode = "approve"\n',
            encoding="utf-8",
        )
        destination = self.tmp / "dest.toml"
        destination.write_text('# keep\nmodel = "m"\n\n[mcp_servers.mine]\nurl = "https://mine"\n', encoding="utf-8")
        self.run_merge("codex-config", source, destination, "mcp")

        self.run_merge("codex-config", source, destination, "mcp", extra=("--remove",))

        text = destination.read_text()
        self.assertIn("# keep", text)
        self.assertEqual(tomllib.loads(text), {"model": "m", "mcp_servers": {"mine": {"url": "https://mine"}}})

    # -- --remove: list-union ----------------------------------------------
    def test_remove_toml_noop_preserves_symlink_bytes_and_inode(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text('[mcp_servers.svc]\nurl = "https://x"\n', encoding="utf-8")
        original = self.tmp / "original.toml"
        original.write_bytes(b'# no trailing newline\n[projects."/p"]\ntrust_level = "trusted"')
        destination = self.tmp / "dest.toml"
        destination.symlink_to(original)
        before = original.read_bytes()
        inode = original.stat().st_ino

        result = self.run_merge("codex-config", source, destination, "mcp", extra=("--remove",))

        self.assertIn("nothing to remove", result.stdout)
        self.assertTrue(destination.is_symlink())
        self.assertEqual(destination.readlink(), original)
        self.assertEqual(original.read_bytes(), before)
        self.assertEqual(original.stat().st_ino, inode)

    def remove_plugins(self, source: Path, destination: Path, **kwargs) -> subprocess.CompletedProcess[str]:
        return self.run_merge("opencode-config", source, destination, "plugins", extra=("--remove",), **kwargs)

    def test_remove_list_union_takes_back_only_appended_items(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"plugins": ["repo-a", "repo-b"]})
        destination = self.write_json(self.tmp / "dest.json", {"plugins": ["mine", "repo-b"], "x": 1})
        self.run_merge("opencode-config", source, destination, "plugins")

        result = self.remove_plugins(source, destination)

        # repo-b predates the merge, so it is the user's and stays.
        self.assertEqual(json.loads(destination.read_text()), {"plugins": ["mine", "repo-b"], "x": 1})
        self.assertIn("kept your local value at /plugins", result.stdout)

    def test_remove_list_union_force_takes_repo_values(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"plugins": ["repo-a", "repo-b"]})
        destination = self.write_json(self.tmp / "dest.json", {"plugins": ["mine", "repo-b"]})
        self.run_merge("opencode-config", source, destination, "plugins")

        self.remove_plugins(source, destination, force=True)

        self.assertEqual(json.loads(destination.read_text()), {"plugins": ["mine"]})

    def test_remove_list_union_drops_list_it_created(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"plugins": ["repo-a"]})
        destination = self.write_json(self.tmp / "dest.json", {"x": 1})
        self.run_merge("opencode-config", source, destination, "plugins")

        self.remove_plugins(source, destination)

        self.assertEqual(json.loads(destination.read_text()), {"x": 1})
        self.assertNotIn(f"opencode-config:{destination}", json.loads(self.state.read_text()))

    def test_remove_keep_empty_list_survives(self) -> None:
        source = self.write_json(
            self.tmp / "src.json", {"version": 1, "permissions": {"allow": ["Shell(git)"], "deny": []}}
        )
        destination = self.write_json(self.tmp / "dest.json", {"privacyMode": 1})
        self.run_merge("cursor-cli", source, destination, "settings")

        self.run_merge("cursor-cli", source, destination, "settings", extra=("--remove",))

        self.assertEqual(
            json.loads(destination.read_text()), {"privacyMode": 1, "permissions": {"allow": [], "deny": []}}
        )

    def test_remove_keep_empty_lists_alone_count_as_empty_file(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"version": 1, "permissions": {"allow": [], "deny": []}})
        destination = self.tmp / "dest.json"
        self.run_merge("cursor-cli", source, destination, "settings")

        result = self.run_merge("cursor-cli", source, destination, "settings", extra=("--remove",))

        self.assertIn("removed empty file", result.stdout)
        self.assertFalse(destination.exists())


class OmpYamlMergeTest(MergeBase):
    ROLES = {
        "default": "anthropic/claude-fable-5-1:medium, openai/gpt-5.6-sol:high",
        "slow": "anthropic/claude-opus-5:high, openai/gpt-5.6-sol:high",
        "task": "anthropic/claude-opus-5:high, openai/gpt-5.6-sol:high",
    }

    CHAINS = {role: ["openai/gpt-5.6-sol"] for role in ("default", "slow", "task")}

    def write_source(
        self,
        roles: dict[str, str] | None = None,
        approval: str = "write",
        chains: dict[str, list[str]] | None = None,
    ) -> Path:
        source = self.tmp / "config.src.yml"
        payload: dict[str, Any] = {"modelRoles": roles or self.ROLES}
        if chains is not None:
            payload["retry"] = {"fallbackChains": chains}
        payload["tools"] = {"approvalMode": approval}
        source.write_text("# Managed by ystack\n" + yaml.safe_dump(payload, sort_keys=False), encoding="utf-8")
        return source

    def merge(self, source: Path, destination: Path, **kwargs: Any) -> subprocess.CompletedProcess[str]:
        return self.run_merge("omp-config", source, destination, "settings", **kwargs)

    def load(self, path: Path) -> Any:
        return yaml.safe_load(path.read_text(encoding="utf-8"))

    def test_m1_missing_destination_gets_only_managed_leaves(self) -> None:
        destination = self.tmp / "agent" / "config.yml"

        self.merge(self.write_source(), destination)

        self.assertEqual(self.load(destination), {"modelRoles": self.ROLES, "tools": {"approvalMode": "write"}})

    def test_m2_user_keys_survive(self) -> None:
        providers = {"ollama": {"baseUrl": "http://127.0.0.1:11434", "models": ["llama4"]}}
        user = {
            "providers": providers,
            "modelRoles": {"smol": "openai/gpt-5.6-mini", "reviewer": "@slow"},
            "tools": {"approval": {"bash": "deny"}},
        }
        destination = self.tmp / "config.yml"
        destination.write_text(yaml.safe_dump(user, sort_keys=False), encoding="utf-8")

        self.merge(self.write_source(), destination)

        merged = self.load(destination)
        self.assertEqual(merged["providers"], providers)
        self.assertEqual(merged["modelRoles"], {**user["modelRoles"], **self.ROLES})
        self.assertEqual(merged["tools"], {"approval": {"bash": "deny"}, "approvalMode": "write"})

    def test_m3_user_edit_wins_until_force(self) -> None:
        destination = self.tmp / "config.yml"
        self.merge(self.write_source(), destination)
        edited = self.load(destination)
        edited["modelRoles"]["slow"] = "openai/gpt-5.6-sol:xhigh"
        destination.write_text(yaml.safe_dump(edited, sort_keys=False), encoding="utf-8")
        updated = {**self.ROLES, "default": "anthropic/claude-fable-6:medium", "slow": "anthropic/claude-opus-6:high"}
        source = self.write_source(updated)

        result = self.merge(source, destination)

        roles = self.load(destination)["modelRoles"]
        self.assertEqual(roles["slow"], "openai/gpt-5.6-sol:xhigh")
        self.assertEqual(roles["default"], "anthropic/claude-fable-6:medium")
        self.assertIn("kept your local value at /modelRoles/slow", result.stdout)

        self.merge(source, destination, force=True)

        self.assertEqual(self.load(destination)["modelRoles"]["slow"], "anthropic/claude-opus-6:high")

    def test_m4_remove_deletes_only_owned_leaves(self) -> None:
        destination = self.tmp / "config.yml"
        destination.write_text("modelRoles:\n  smol: openai/gpt-5.6-mini\n", encoding="utf-8")
        source = self.write_source()
        self.merge(source, destination)
        edited = self.load(destination)
        edited["modelRoles"]["slow"] = "openai/gpt-5.6-sol:xhigh"
        destination.write_text(yaml.safe_dump(edited, sort_keys=False), encoding="utf-8")

        result = self.merge(source, destination, extra=("--remove",))

        self.assertEqual(
            self.load(destination),
            {"modelRoles": {"smol": "openai/gpt-5.6-mini", "slow": "openai/gpt-5.6-sol:xhigh"}},
        )
        self.assertIn("kept your local value at /modelRoles/slow", result.stdout)

    def test_m8_fallback_chains_owned_per_role(self) -> None:
        destination = self.tmp / "config.yml"
        user_retry = {"maxRetries": 5, "fallbackChains": {"smol": ["openai/gpt-5.6-mini"]}}
        destination.write_text(yaml.safe_dump({"retry": user_retry}, sort_keys=False), encoding="utf-8")
        source = self.write_source(chains=self.CHAINS)

        self.merge(source, destination)

        retry = self.load(destination)["retry"]
        self.assertEqual(retry["maxRetries"], 5)
        self.assertEqual(retry["fallbackChains"], {**user_retry["fallbackChains"], **self.CHAINS})

        edited = self.load(destination)
        edited["retry"]["fallbackChains"]["slow"] = ["anthropic/claude-fable-5-1:high", "openai/gpt-5.6-sol:high"]
        destination.write_text(yaml.safe_dump(edited, sort_keys=False), encoding="utf-8")
        updated = {**self.CHAINS, "default": ["openai/gpt-5.7"], "slow": ["openai/gpt-5.7"]}
        source = self.write_source(chains=updated)

        result = self.merge(source, destination)

        chains = self.load(destination)["retry"]["fallbackChains"]
        self.assertEqual(chains["slow"], edited["retry"]["fallbackChains"]["slow"])
        self.assertEqual(chains["default"], ["openai/gpt-5.7"])
        self.assertIn("kept your local value at /retry/fallbackChains/slow", result.stdout)

        self.merge(source, destination, force=True)
        self.assertEqual(self.load(destination)["retry"]["fallbackChains"]["slow"], ["openai/gpt-5.7"])

        self.merge(source, destination, extra=("--remove",))

        self.assertEqual(self.load(destination), {"retry": user_retry})

    def test_m5_symlinked_destination_refused_without_writes(self) -> None:
        target = self.tmp / "dotfiles-config.yml"
        target.write_text("modelRoles:\n  smol: openai/gpt-5.6-mini\n", encoding="utf-8")
        before = target.read_bytes()
        destination = self.tmp / "config.yml"
        destination.symlink_to(target)

        result = self.merge(self.write_source(), destination, expect_success=False)

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"refusing to write through symlinked {destination}; add these keys yourself:", result.stderr)
        self.assertIn("approvalMode: write", result.stderr)
        self.assertTrue(destination.is_symlink())
        self.assertEqual(os.readlink(destination), str(target))
        self.assertEqual(target.read_bytes(), before)
        self.assertFalse(self.state.exists())

    def test_m6_invalid_or_list_root_refused_without_writes(self) -> None:
        for text in ("modelRoles: [unclosed\n", "- default\n- slow\n"):
            with self.subTest(text=text):
                destination = self.tmp / "config.yml"
                destination.write_text(text, encoding="utf-8")

                result = self.merge(self.write_source(), destination, expect_success=False)

                self.assertEqual(result.returncode, 1)
                self.assertIn("not a valid OMP config", result.stderr)
                self.assertEqual(destination.read_text(encoding="utf-8"), text)
                self.assertFalse(self.state.exists())

    def test_m7_first_rewrite_backs_up_once(self) -> None:
        destination = self.tmp / "config.yml"
        original = "# my machine\nmodelRoles:\n  smol: openai/gpt-5.6-mini  # cheap\n"
        destination.write_text(original, encoding="utf-8")
        backup = self.tmp / "config.yml.ycc-backup"

        result = self.merge(self.write_source(), destination)

        self.assertEqual(backup.read_text(encoding="utf-8"), original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertIn(f"original saved to {backup}", result.stdout)
        self.assertNotIn("# my machine", destination.read_text(encoding="utf-8"))

        commented = "# second comment\n" + destination.read_text(encoding="utf-8")
        destination.write_text(commented, encoding="utf-8")
        result = self.merge(self.write_source(approval="always-ask"), destination, force=True)

        rotated = self.tmp / "config.yml.ycc-backup.1"
        self.assertEqual(backup.read_text(encoding="utf-8"), original)
        self.assertEqual(rotated.read_text(encoding="utf-8"), commented)
        self.assertEqual(rotated.stat().st_mode & 0o777, 0o600)
        self.assertIn(f"original saved to {rotated}", result.stdout)
        self.assertEqual(self.load(destination)["tools"]["approvalMode"], "always-ask")

    def test_m7_ycc_rendering_is_not_backed_up_and_later_comments_are(self) -> None:
        # Reproduces the stale-backup bug: a backup of ycc's own output used to
        # block every later backup, so user comments were lost silently.
        destination = self.tmp / "config.yml"
        source = self.write_source()
        self.merge(source, destination)
        result = self.merge(self.write_source(approval="always-ask"), destination)
        self.assertNotIn("not preserved", result.stdout)
        self.assertEqual(list(self.tmp.glob("config.yml.ycc-backup*")), [])

        self.merge(source, destination, extra=("--remove",))
        self.assertFalse(destination.exists())

        commented = "# keep me\nmodelRoles:\n  smol: openai/gpt-5.6-mini\n"
        destination.write_text(commented, encoding="utf-8")
        result = self.merge(source, destination)

        backup = self.tmp / "config.yml.ycc-backup"
        self.assertEqual(backup.read_text(encoding="utf-8"), commented)
        self.assertIn(f"comments and formatting in {destination} are not preserved", result.stdout)

    def test_m7_remove_of_emptied_file_drops_ycc_only_backup(self) -> None:
        destination = self.tmp / "config.yml"
        source = self.write_source()
        self.merge(source, destination)
        # A backup left by an older ycc that saved its own rendering.
        stale = self.tmp / "config.yml.ycc-backup"
        stale.write_bytes(destination.read_bytes())
        user = self.tmp / "config.yml.ycc-backup.1"
        user.write_text("# mine\nmodelRoles: {}\n", encoding="utf-8")

        result = self.merge(source, destination, extra=("--remove",))

        self.assertFalse(destination.exists())
        self.assertFalse(stale.exists())
        self.assertIn(f"removed ycc backup {stale}", result.stdout)
        self.assertEqual(user.read_text(encoding="utf-8"), "# mine\nmodelRoles: {}\n")

    def test_yaml_aliases_refused_without_writes(self) -> None:
        text = "base: &b\n  smol: openai/gpt-5.6-mini\nmodelRoles:\n  <<: *b\n"
        destination = self.tmp / "config.yml"
        destination.write_text(text, encoding="utf-8")

        for extra in ((), ("--remove",)):
            with self.subTest(extra=extra):
                result = self.merge(self.write_source(), destination, expect_success=False, extra=extra)

                self.assertEqual(result.returncode, 1)
                self.assertIn("YAML aliases are not supported", result.stderr)
                self.assertIn("no changes made", result.stderr)
                self.assertEqual(destination.read_text(encoding="utf-8"), text)
                self.assertEqual(list(self.tmp.glob("config.yml.ycc-backup*")), [])
                self.assertFalse(self.state.exists())

    def test_missing_pyyaml_fails_with_install_hint(self) -> None:
        shadow = self.tmp / "no-yaml"
        shadow.mkdir()
        (shadow / "yaml.py").write_text("raise ImportError('No module named yaml')\n", encoding="utf-8")
        destination = self.tmp / "config.yml"
        source = self.write_source()
        env = {**os.environ, "YCC_MANAGED_CONFIG_STATE": str(self.state), "PYTHONPATH": str(shadow)}
        argv = [sys.executable, str(HELPER), "--profile", "omp-config", "--source", str(source)]
        argv += ["--destination", str(destination), "--groups", "settings"]

        result = subprocess.run(argv, capture_output=True, text=True, env=env)

        self.assertEqual(result.returncode, 1)
        self.assertIn("PyYAML is required", result.stderr)
        self.assertIn("pip install --user pyyaml", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(destination.exists())
        self.assertFalse(self.state.exists())

    def test_m7_uncommented_formatting_is_backed_up(self) -> None:
        # No comments, but quoting and indentation the rewrite would change.
        destination = self.tmp / "config.yml"
        original = 'modelRoles:\n    smol: "openai/gpt-5.6-mini"\n'
        destination.write_text(original, encoding="utf-8")

        self.merge(self.write_source(), destination)

        self.assertEqual((self.tmp / "config.yml.ycc-backup").read_text(encoding="utf-8"), original)

    def test_yaml_1_2_scalars_stay_strings_after_merge_and_remove(self) -> None:
        # OMP reads config.yml as YAML 1.2 (Bun); PyYAML's default 1.1 schema
        # would turn these unmanaged user values into bools/ints on rewrite.
        # Expected values are what Bun.YAML.parse returns for the original file.
        destination = self.tmp / "config.yml"
        destination.write_text(
            "memory:\n  backend: off\ncompletion:\n  notify: off\nperm: 0755\nt: 12:30\nn: 1_000\non: yes\n",
            encoding="utf-8",
        )
        expected = {
            "memory": {"backend": "off"},
            "completion": {"notify": "off"},
            "perm": 755,  # YAML 1.2 decimal, as Bun reads it; 1.1 would give octal 493
            "t": "12:30",
            "n": "1_000",
            "on": "yes",
        }
        source = self.write_source()

        for extra in ((), ("--remove",)):
            with self.subTest(extra=extra):
                self.merge(source, destination, extra=extra)
                text = destination.read_text(encoding="utf-8")
                for literal in (
                    "backend: 'off'",
                    "notify: 'off'",
                    "perm: 755\n",
                    "t: '12:30'",
                    "n: '1_000'",
                    "'on': 'yes'",
                ):
                    self.assertIn(literal, text)
                bun = shutil.which("bun")
                if bun:
                    script = (
                        "if (typeof Bun.YAML?.parse !== 'function') process.exit(77);"
                        "console.log(JSON.stringify(Bun.YAML.parse(await Bun.file(process.argv[1]).text())))"
                    )
                    run = subprocess.run([bun, "-e", script, str(destination)], capture_output=True, text=True)
                    if run.returncode != 77:  # 77: this Bun has no Bun.YAML; the cross-check is optional.
                        self.assertEqual(run.returncode, 0, run.stderr)
                        parsed = json.loads(run.stdout)
                        self.assertEqual({key: parsed[key] for key in expected}, expected)
        self.assertNotIn("modelRoles", self.load(destination))


class OmpDedupeMergeTest(MergeBase):
    """The omp-config ``dedupe`` group: owned skills.ignoredSkills aliases (YAN-1176)."""

    ALIASES = ["agents/backport", "agents/plan"]

    def write_source(self, items: list[str] | None = None) -> Path:
        source = self.tmp / "dedupe.src.yml"
        payload = {"skills": {"ignoredSkills": items if items is not None else self.ALIASES}}
        source.write_text(yaml.safe_dump(payload, sort_keys=False), encoding="utf-8")
        return source

    def merge(self, source: Path, destination: Path, groups: str = "dedupe", **kwargs: Any) -> Any:
        return self.run_merge("omp-config", source, destination, groups, **kwargs)

    def load(self, path: Path) -> Any:
        return yaml.safe_load(path.read_text(encoding="utf-8"))

    def test_missing_destination_created_then_removed(self) -> None:
        destination = self.tmp / "agent" / "config.yml"
        source = self.write_source()

        self.merge(source, destination)
        self.assertEqual(self.load(destination), {"skills": {"ignoredSkills": self.ALIASES}})
        self.merge(source, destination)  # idempotent
        self.assertEqual(self.load(destination), {"skills": {"ignoredSkills": self.ALIASES}})

        self.merge(source, destination, extra=("--remove",))
        self.assertFalse(destination.exists())

    def test_user_items_kept_in_order_and_survive_remove(self) -> None:
        destination = self.tmp / "config.yml"
        destination.write_text(
            yaml.safe_dump({"skills": {"ignoredSkills": ["my-*", "agents/plan"]}, "theme": "dark"}), encoding="utf-8"
        )
        source = self.write_source()

        self.merge(source, destination)
        self.assertEqual(self.load(destination)["skills"]["ignoredSkills"], ["my-*", "agents/plan", "agents/backport"])

        self.merge(source, destination, extra=("--remove",))
        # agents/plan was the user's before ycc ran, so it stays.
        self.assertEqual(
            self.load(destination), {"skills": {"ignoredSkills": ["my-*", "agents/plan"]}, "theme": "dark"}
        )

    def test_settings_and_dedupe_groups_share_one_file(self) -> None:
        destination = self.tmp / "config.yml"
        settings = self.tmp / "settings.src.yml"
        settings.write_text(yaml.safe_dump({"tools": {"approvalMode": "write"}}), encoding="utf-8")
        source = self.write_source()

        self.merge(settings, destination, groups="settings")
        self.merge(source, destination)
        self.assertEqual(
            self.load(destination), {"tools": {"approvalMode": "write"}, "skills": {"ignoredSkills": self.ALIASES}}
        )

        self.merge(source, destination, extra=("--remove",))
        self.assertEqual(self.load(destination), {"tools": {"approvalMode": "write"}})
        self.merge(source, destination)
        self.merge(settings, destination, groups="settings", extra=("--remove",))
        self.assertEqual(self.load(destination), {"skills": {"ignoredSkills": self.ALIASES}})

    def test_symlinked_destination_refused(self) -> None:
        target = self.tmp / "dotfiles.yml"
        target.write_text("theme: dark\n", encoding="utf-8")
        destination = self.tmp / "config.yml"
        destination.symlink_to(target)

        result = self.merge(self.write_source(), destination, expect_success=False)

        self.assertEqual(result.returncode, 1)
        self.assertEqual(target.read_text(encoding="utf-8"), "theme: dark\n")
        self.assertFalse(self.state.exists())

    def test_rerun_takes_back_owned_items_the_source_dropped(self) -> None:
        destination = self.tmp / "config.yml"
        destination.write_text(yaml.safe_dump({"skills": {"ignoredSkills": ["my-*"]}}), encoding="utf-8")

        self.merge(self.write_source(), destination)
        self.merge(self.write_source(["agents/plan", "agents/clean"]), destination)
        self.assertEqual(self.load(destination)["skills"]["ignoredSkills"], ["my-*", "agents/plan", "agents/clean"])

        # agents/backport is no longer owned: re-adding it by hand survives remove.
        destination.write_text(
            yaml.safe_dump({"skills": {"ignoredSkills": ["my-*", "agents/plan", "agents/clean", "agents/backport"]}}),
            encoding="utf-8",
        )
        self.merge(self.write_source([]), destination, extra=("--remove",))
        self.assertEqual(self.load(destination), {"skills": {"ignoredSkills": ["my-*", "agents/backport"]}})

    def test_remove_owning_nothing_never_reads_the_destination(self) -> None:
        target = self.tmp / "dotfiles.yml"
        target.write_text("skills: [unclosed\n", encoding="utf-8")
        destination = self.tmp / "config.yml"
        destination.symlink_to(target)

        empty = self.tmp / "empty.src.yml"
        empty.write_text("{}\n", encoding="utf-8")
        result = self.merge(empty, destination, extra=("--remove",))

        self.assertIn("nothing to remove", result.stdout)
        self.assertTrue(destination.is_symlink())
        self.assertEqual(target.read_text(encoding="utf-8"), "skills: [unclosed\n")
        self.assertFalse(self.state.exists())

    def test_remove_with_owned_items_still_refuses_a_symlink(self) -> None:
        destination = self.tmp / "config.yml"
        self.merge(self.write_source(), destination)
        target = self.tmp / "dotfiles.yml"
        destination.rename(target)
        destination.symlink_to(target)
        before = target.read_bytes()

        result = self.merge(self.write_source([]), destination, extra=("--remove",), expect_success=False)

        self.assertEqual(result.returncode, 1)
        self.assertEqual(target.read_bytes(), before)


class HookCommandPruneTestCase(MergeBase):
    COMMAND = {"type": "command", "command": "repo-hook", "timeout": 30}
    OTHER = {"type": "command", "command": "user-hook"}
    GROUP = {"matcher": "Bash", "hooks": [COMMAND]}

    def seed(self, groups: list | None = None) -> tuple[Path, Path]:
        source = self.write_json(self.tmp / "src.json", {"hooks": {"PreToolUse": groups or [self.GROUP]}})
        destination = self.write_json(self.tmp / "dest.json", {"keep": True})
        self.run_merge("claude-settings", source, destination, "hooks")
        return source, destination

    def prune(self, source: Path, destination: Path, *extra: str) -> subprocess.CompletedProcess[str]:
        return self.run_merge(
            "claude-settings", source, destination, "hooks", extra=("--remove", "--prune-hook-commands", *extra)
        )

    def test_legacy_atomic_event_state_prunes_only_exact_commands(self) -> None:
        source, destination = self.seed()
        # The existing engine writes only the event hash, not command hashes.
        state_key = f"claude-settings:{destination}"
        ownership = json.loads(self.state.read_text())[state_key]
        self.assertEqual(set(ownership), {"/hooks/PreToolUse"})
        self.assertEqual(set(ownership["/hooks/PreToolUse"]), {"last_applied_sha256"})
        user_group = {"matcher": "Write", "hooks": [self.OTHER], "description": "mine"}
        self.write_json(
            destination,
            {
                "keep": True,
                "hooks": {
                    "PreToolUse": [{**self.GROUP, "hooks": [self.COMMAND, self.OTHER]}, user_group],
                    "Stop": [{"hooks": [self.OTHER]}],
                },
            },
        )

        self.prune(source, destination)

        self.assertEqual(
            json.loads(destination.read_text()),
            {
                "keep": True,
                "hooks": {
                    "PreToolUse": [{**self.GROUP, "hooks": [self.OTHER]}, user_group],
                    "Stop": [{"hooks": [self.OTHER]}],
                },
            },
        )
        self.assertNotIn(state_key, json.loads(self.state.read_text()))
        before = destination.read_bytes(), self.state.read_bytes()
        self.prune(source, destination)
        self.assertEqual(before, (destination.read_bytes(), self.state.read_bytes()))

    def test_prune_retains_extra_wrapper_metadata_even_when_empty(self) -> None:
        source, destination = self.seed()
        self.write_json(destination, {"hooks": {"PreToolUse": [{**self.GROUP, "description": "mine"}]}})

        self.prune(source, destination)

        self.assertEqual(
            json.loads(destination.read_text()),
            {
                "hooks": {"PreToolUse": [{"matcher": "Bash", "description": "mine", "hooks": []}]},
            },
        )

    def test_prune_drops_only_emptied_matching_groups_and_event(self) -> None:
        source, destination = self.seed()
        self.prune(source, destination)
        self.assertEqual(json.loads(destination.read_text()), {"keep": True})
        self.assertNotIn(f"claude-settings:{destination}", json.loads(self.state.read_text()))

    def test_prune_edited_command_is_kept_with_conflict_and_state(self) -> None:
        for change in ({"command": "repo-hook --local"}, {"timeout": 60}):
            with self.subTest(change=change):
                source, destination = self.seed()
                self.write_json(
                    destination,
                    {
                        "hooks": {
                            "PreToolUse": [
                                {
                                    **self.GROUP,
                                    "hooks": [{**self.COMMAND, **change}, self.OTHER],
                                }
                            ]
                        }
                    },
                )
                before = destination.read_bytes(), self.state.read_bytes()

                result = self.prune(source, destination)

                self.assertIn("kept uncertain or locally modified hook commands at /hooks/PreToolUse", result.stdout)
                self.assertEqual(before, (destination.read_bytes(), self.state.read_bytes()))

    def test_prune_keeps_edited_wrapper_and_exact_command_under_it(self) -> None:
        source, destination = self.seed()
        self.write_json(destination, {"hooks": {"PreToolUse": [{**self.GROUP, "matcher": "Write"}]}})
        before = destination.read_bytes(), self.state.read_bytes()

        result = self.prune(source, destination)

        self.assertIn("kept uncertain", result.stdout)
        self.assertEqual(before, (destination.read_bytes(), self.state.read_bytes()))

    def test_prune_removes_exact_sibling_while_retaining_modified_hook(self) -> None:
        second = {"type": "command", "command": "repo-second"}
        source, destination = self.seed([{**self.GROUP, "hooks": [self.COMMAND, second]}])
        edited = {**second, "command": "repo-second --local"}
        self.write_json(
            destination,
            {
                "hooks": {
                    "PreToolUse": [
                        {
                            **self.GROUP,
                            "hooks": [self.COMMAND, edited, self.OTHER],
                        }
                    ]
                }
            },
        )

        result = self.prune(source, destination)

        self.assertIn("kept uncertain", result.stdout)
        self.assertEqual(
            json.loads(destination.read_text()),
            {
                "hooks": {"PreToolUse": [{**self.GROUP, "hooks": [edited, self.OTHER]}]},
            },
        )
        self.assertNotIn(f"claude-settings:{destination}", json.loads(self.state.read_text()))
        before = destination.read_bytes(), self.state.read_bytes()
        self.prune(source, destination)
        self.assertEqual(before, (destination.read_bytes(), self.state.read_bytes()))

    def test_prune_duplicate_commands_in_same_wrapper_retains_one_across_repeats(self) -> None:
        source, destination = self.seed()
        self.write_json(
            destination,
            {
                "hooks": {
                    "PreToolUse": [
                        {
                            **self.GROUP,
                            "hooks": [self.COMMAND, self.COMMAND],
                        }
                    ]
                }
            },
        )
        before = destination.read_bytes(), self.state.read_bytes()

        preview = self.prune(source, destination, "--dry-run")
        self.assertIn("would remove /hooks/PreToolUse", preview.stdout)
        self.assertIn("kept uncertain", preview.stdout)
        self.assertEqual(before, (destination.read_bytes(), self.state.read_bytes()))

        result = self.prune(source, destination)

        self.assertIn("kept uncertain", result.stdout)
        self.assertEqual(json.loads(destination.read_text()), {"hooks": {"PreToolUse": [self.GROUP]}})
        self.assertNotIn(f"claude-settings:{destination}", json.loads(self.state.read_text()))
        before = destination.read_bytes(), self.state.read_bytes()
        repeat = self.prune(source, destination)
        self.assertIn("kept uncertain", repeat.stdout)
        self.assertEqual(before, (destination.read_bytes(), self.state.read_bytes()))

    def test_prune_duplicate_wrappers_retains_one_across_repeats(self) -> None:
        source, destination = self.seed()
        self.write_json(destination, {"hooks": {"PreToolUse": [self.GROUP, self.GROUP]}})

        result = self.prune(source, destination)

        self.assertIn("kept uncertain", result.stdout)
        self.assertEqual(json.loads(destination.read_text()), {"hooks": {"PreToolUse": [self.GROUP]}})
        self.assertNotIn(f"claude-settings:{destination}", json.loads(self.state.read_text()))
        before = destination.read_bytes(), self.state.read_bytes()
        repeat = self.prune(source, destination)
        self.assertIn("kept uncertain", repeat.stdout)
        self.assertEqual(before, (destination.read_bytes(), self.state.read_bytes()))

    def test_prune_without_state_does_not_adopt_matching_source(self) -> None:
        source, destination = self.seed()
        self.state.unlink()
        before = destination.read_bytes()

        result = self.prune(source, destination)

        self.assertIn("kept uncertain", result.stdout)
        self.assertEqual(destination.read_bytes(), before)
        self.assertFalse(self.state.exists())

    def test_prune_changed_source_cannot_reconstruct_historical_commands(self) -> None:
        source, destination = self.seed()
        self.write_json(source, {"hooks": {"PreToolUse": [{**self.GROUP, "hooks": [self.OTHER]}]}})
        before = destination.read_bytes(), self.state.read_bytes()

        result = self.prune(source, destination)

        self.assertIn("kept uncertain", result.stdout)
        self.assertEqual(before, (destination.read_bytes(), self.state.read_bytes()))

    def test_prune_preview_preserves_state_destination_and_symlink_target(self) -> None:
        source, destination = self.seed()
        target = destination.with_name("target.json")
        target.write_bytes(destination.read_bytes())
        destination.unlink()
        destination.symlink_to(target)
        before = target.read_bytes(), self.state.read_bytes()

        result = self.prune(source, destination, "--dry-run")

        self.assertIn("would remove /hooks/PreToolUse", result.stdout)
        self.assertTrue(destination.is_symlink())
        self.assertEqual(before, (target.read_bytes(), self.state.read_bytes()))

    def test_prune_rejects_wrong_mode_groups_profile_or_force_before_writes(self) -> None:
        source, destination = self.seed()
        before = destination.read_bytes(), self.state.read_bytes()
        cases = [
            ("claude-settings", "hooks", ("--prune-hook-commands",)),
            ("claude-settings", "settings", ("--remove", "--prune-hook-commands")),
            ("claude-settings", "hooks,settings", ("--remove", "--prune-hook-commands")),
            ("claude-mcp", "mcp", ("--remove", "--prune-hook-commands")),
            ("claude-settings", "hooks", ("--remove", "--prune-hook-commands", "--force")),
        ]
        for profile, groups, extra in cases:
            with self.subTest(profile=profile, groups=groups, extra=extra):
                result = self.run_merge(profile, source, destination, groups, extra=extra, expect_success=False)
                self.assertEqual(result.returncode, 1)
                self.assertIn("--prune-hook-commands requires", result.stderr)
                self.assertEqual(before, (destination.read_bytes(), self.state.read_bytes()))

    def test_plain_remove_retains_whole_event_after_user_adds_command(self) -> None:
        source, destination = self.seed()
        self.write_json(
            destination,
            {
                "hooks": {
                    "PreToolUse": [
                        {
                            **self.GROUP,
                            "hooks": [self.COMMAND, self.OTHER],
                        }
                    ]
                }
            },
        )
        before = destination.read_bytes(), self.state.read_bytes()

        self.run_merge("claude-settings", source, destination, "hooks", extra=("--remove",))

        self.assertEqual(before, (destination.read_bytes(), self.state.read_bytes()))


class GithubMcpMigrationTestCase(MergeBase):
    NATIVE = {"command": "github-mcp-server", "args": ["stdio"]}
    BRIDGE = json.loads((REPO_ROOT / "mcp-configs" / "mcp.json").read_text())["mcpServers"]["github"]
    AUTH_OVERRIDES = {"GITHUB_PERSONAL_ACCESS_TOKEN", "GITHUB_TOKEN", "GH_TOKEN", "GH_HOST"}
    NPM = {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-github"],
        "envFile": "${userHome}/.config/env/github-env-mcp",
        "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_API_TOKEN}", "KEEP": "1"},
        "autoApprove": ["x"],
    }
    SERVERS = {"mcpServers": {"github": BRIDGE, "linear": {"type": "http", "url": "https://l"}}}

    def test_non_bridge_source_does_not_enable_legacy_migration(self) -> None:
        for script in (
            "echo https://api.githubcopilot.com/mcp/; exec other-mcp",
            'header=x; exec npx -y mcp-remote https://ghe.example.com/mcp/ --header "$header"',
            'header=x; exec npx -y mcp-remote https://api.githubcopilot.com/mcp/ --header "$header"; echo done',
        ):
            with self.subTest(script=script):
                wanted = {"command": "sh", "args": ["-c", script]}
                source = self.write_json(self.tmp / "src.json", {"mcpServers": {"github": wanted}})
                dest = self.write_json(self.tmp / "dest.json", {"mcpServers": {"github": self.NPM}})
                self.sync("claude-mcp", source, dest)
                self.assertEqual(self.load(dest)["mcpServers"]["github"], self.NPM)

    def sync(
        self, profile: str, source: Path, dest: Path, groups: str = "mcp", **kw
    ) -> subprocess.CompletedProcess[str]:
        return self.run_merge(profile, source, dest, groups, **kw)

    def load(self, path: Path) -> dict:
        return json.loads(path.read_text())

    def claude(self, github: dict, **extra: object) -> tuple[Path, Path]:
        source = self.write_json(self.tmp / "src.json", self.SERVERS)
        dest = self.write_json(self.tmp / "dest.json", {"keep": 1, "mcpServers": {"github": github, **extra}})
        return source, dest

    def test_claude_npm_migrates_without_state_and_is_idempotent(self) -> None:
        source, dest = self.claude(self.NPM, mine={"url": "https://mine"})
        self.sync("claude-mcp", source, dest)
        data = self.load(dest)
        self.assertEqual(data["mcpServers"]["github"], {**self.BRIDGE, "env": {"KEEP": "1"}, "autoApprove": ["x"]})
        self.assertEqual(data["mcpServers"]["mine"], {"url": "https://mine"})
        self.assertEqual(data["keep"], 1)
        before = (dest.read_text(), self.state.read_text())
        result = self.sync("claude-mcp", source, dest)
        self.assertIn("up-to-date", result.stdout)
        self.assertEqual(before, (dest.read_text(), self.state.read_text()))

    def test_cursor_remote_migrates_and_drops_headers(self) -> None:
        remote = {"type": "http", "url": "https://api.githubcopilot.com/mcp/", "headers": {"Authorization": "Bearer x"}}
        source, dest = self.claude(remote)
        self.sync("cursor-mcp", source, dest)
        self.assertEqual(self.load(dest)["mcpServers"]["github"], self.BRIDGE)

    def test_legacy_native_stdio_migrates_without_state_and_is_idempotent(self) -> None:
        source, dest = self.claude(self.NATIVE, mine={"url": "https://mine"})
        self.sync("claude-mcp", source, dest)
        data = self.load(dest)
        self.assertEqual(data["mcpServers"]["github"], self.BRIDGE)
        self.assertEqual(data["mcpServers"]["mine"], {"url": "https://mine"})
        before = (dest.read_text(), self.state.read_text())
        self.assertIn("up-to-date", self.sync("claude-mcp", source, dest).stdout)
        self.assertEqual(before, (dest.read_text(), self.state.read_text()))

    def test_legacy_native_stdio_toml_migrates_and_keeps_tools(self) -> None:
        source, dest = self.toml_case(
            '[mcp_servers.github]\ncommand = "github-mcp-server"\nargs = ["stdio"]\n\n'
            '[mcp_servers.github.tools.create_pull_request]\napproval_mode = "approve"\n'
        )
        self.sync("codex-config", source, dest)
        parsed = tomllib.loads(dest.read_text())["mcp_servers"]["github"]
        self.assertEqual(parsed, {**self.BRIDGE, "tools": {"create_pull_request": {"approval_mode": "approve"}}})
        self.assertIn("up-to-date", self.sync("codex-config", source, dest).stdout)

    def test_bridge_signature_does_not_match_arbitrary_shell_commands(self) -> None:
        custom = {"command": "sh", "args": ["-c", "exec npx -y mcp-remote https://ghe.example.com/mcp/ --header x"]}
        source, dest = self.claude(custom)
        self.sync("claude-mcp", source, dest)
        self.assertEqual(self.load(dest)["mcpServers"]["github"], custom)

    def test_tracked_state_npm_migrates(self) -> None:
        old = self.write_json(
            self.tmp / "old.json",
            {"mcpServers": {"github": {k: v for k, v in self.NPM.items() if k not in ("env", "autoApprove")}}},
        )
        dest = self.tmp / "dest.json"
        self.sync("claude-mcp", old, dest)
        source = self.write_json(self.tmp / "src.json", self.SERVERS)
        self.sync("claude-mcp", source, dest)
        self.assertEqual(self.load(dest)["mcpServers"]["github"], self.BRIDGE)

    def test_custom_github_untouched_without_force_replaced_with_force(self) -> None:
        for custom in (
            {"command": "docker", "args": ["run", "ghcr.io/github/github-mcp-server"]},
            {"command": "npx", "args": ["-y", "my-github-fork"], "env": {"X": "1"}},
            {"url": "https://ghe.example.com/mcp", "headers": {"A": "b"}},
            {**GithubMcpMigrationTestCase.NATIVE, "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "t"}},
            {**GithubMcpMigrationTestCase.NATIVE, "args": ["stdio", "--read-only"]},
            {**GithubMcpMigrationTestCase.NATIVE, "env": {"GH_HOST": "ghe.example.com"}},
            {**GithubMcpMigrationTestCase.NATIVE, "env_vars": ["GITHUB_TOKEN"]},
            {**GithubMcpMigrationTestCase.BRIDGE, "env": {"GH_TOKEN": "custom"}},
        ):
            with self.subTest(custom=custom):
                source, dest = self.claude(custom)
                self.sync("claude-mcp", source, dest)
                self.assertEqual(self.load(dest)["mcpServers"]["github"], custom)
                self.sync("claude-mcp", source, dest, force=True)
                expected = dict(self.BRIDGE)
                if "env" in custom:
                    kept = {
                        k: v for k, v in custom["env"].items() if k not in GithubMcpMigrationTestCase.AUTH_OVERRIDES
                    }
                    if kept:
                        expected["env"] = kept
                if "env_vars" in custom:
                    kept = [n for n in custom["env_vars"] if n not in GithubMcpMigrationTestCase.AUTH_OVERRIDES]
                    if kept:
                        expected["env_vars"] = kept
                self.assertEqual(self.load(dest)["mcpServers"]["github"], expected)

    def test_dry_run_and_entry_selection_do_not_migrate(self) -> None:
        source, dest = self.claude(self.NPM)
        before = dest.read_text()
        result = self.sync("claude-mcp", source, dest, extra=("--dry-run",))
        self.assertIn("would remove /mcpServers/github/envFile", result.stdout)
        self.assertEqual(dest.read_text(), before)
        self.assertFalse(self.state.exists())
        self.sync("claude-mcp", source, dest, extra=("--entries", "linear"))
        self.assertEqual(self.load(dest)["mcpServers"]["github"], self.NPM)
        self.assertIn("linear", self.load(dest)["mcpServers"])

    def test_opencode_array_command_migrates(self) -> None:
        source = self.write_json(
            self.tmp / "src.json",
            {
                "mcp": {
                    "servers": {
                        "github": {
                            "type": "local",
                            "command": [self.BRIDGE["command"], *self.BRIDGE["args"]],
                        }
                    }
                }
            },
        )
        dest = self.write_json(
            self.tmp / "dest.json",
            {
                "mcp": {
                    "servers": {
                        "github": {
                            "type": "local",
                            "command": ["npx", "-y", "@modelcontextprotocol/server-github"],
                            "environment": {"GITHUB_PERSONAL_ACCESS_TOKEN": "{env:GITHUB_API_TOKEN}", "KEEP": "1"},
                        }
                    }
                }
            },
        )
        self.sync("opencode-config", source, dest)
        self.assertEqual(
            self.load(dest)["mcp"]["servers"]["github"],
            {"type": "local", "command": [self.BRIDGE["command"], *self.BRIDGE["args"]], "environment": {"KEEP": "1"}},
        )

    def test_codex_toml_remote_migrates_and_keeps_tools(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text(self.GH_TOML_SRC, encoding="utf-8")
        dest = self.tmp / "dest.toml"
        dest.write_text(
            '# keep\nmodel = "m"\n\n[mcp_servers.github]\nurl = "https://api.githubcopilot.com/mcp"\n'
            'bearer_token_env_var = "GITHUB_API_TOKEN"\n\n'
            '[mcp_servers.github.tools.create_pull_request]\napproval_mode = "approve"\n',
            encoding="utf-8",
        )
        self.sync("codex-config", source, dest)
        text = dest.read_text()
        self.assertIn("# keep", text)
        parsed = tomllib.loads(text)["mcp_servers"]["github"]
        self.assertEqual(parsed, {**self.BRIDGE, "tools": {"create_pull_request": {"approval_mode": "approve"}}})
        self.assertIn("up-to-date", self.sync("codex-config", source, dest).stdout)

    GH_TOML_SRC = f'[mcp_servers.github]\ncommand = "sh"\nargs = {json.dumps(BRIDGE["args"])}\n'

    def toml_case(self, text: str) -> tuple[Path, Path]:
        source = self.tmp / "src.toml"
        source.write_text(self.GH_TOML_SRC, encoding="utf-8")
        dest = self.tmp / "dest.toml"
        dest.write_text(text, encoding="utf-8")
        return source, dest

    def test_codex_toml_auth_subtables_removed_and_tools_kept(self) -> None:
        source, dest = self.toml_case(
            '# top\n[mcp_servers.github]\nurl = "https://api.githubcopilot.com/mcp"\n\n'
            '[mcp_servers.github.http_headers]\nAuthorization = "Bearer x"\n\n'
            '[mcp_servers.github.env_http_headers]\nA = "B"\n\n'
            '[mcp_servers.github.tools.create_pull_request]\napproval_mode = "approve"\n\n'
            '[mcp_servers.other]\nurl = "https://o"\n'
        )
        self.sync("codex-config", source, dest)
        text = dest.read_text()
        self.assertEqual(
            tomllib.loads(text)["mcp_servers"],
            {
                "github": {**self.BRIDGE, "tools": {"create_pull_request": {"approval_mode": "approve"}}},
                "other": {"url": "https://o"},
            },
        )
        self.assertIn("# top", text)
        self.assertIn("up-to-date", self.sync("codex-config", source, dest).stdout)

    def test_codex_toml_inline_auth_tables_removed(self) -> None:
        source, dest = self.toml_case(
            '[mcp_servers.github]\nurl = "https://api.githubcopilot.com/mcp"\n'
            'http_headers = { Authorization = "Bearer x" }\nenv_http_headers = { A = "B" }\n'
        )
        self.sync("codex-config", source, dest)
        self.assertEqual(tomllib.loads(dest.read_text())["mcp_servers"]["github"], self.BRIDGE)

    def test_codex_toml_inline_env_pat_leaf_keeps_siblings(self) -> None:
        source, dest = self.toml_case(
            '[mcp_servers.github]\ncommand = "npx"\nargs = ["-y", "@modelcontextprotocol/server-github"]\n'
            'env = { GITHUB_PERSONAL_ACCESS_TOKEN = "t", KEEP = "1" }\n\n'
            '[mcp_servers.github.tools.a]\napproval_mode = "approve"\n'
        )
        self.sync("codex-config", source, dest)
        parsed = tomllib.loads(dest.read_text())["mcp_servers"]["github"]
        self.assertEqual(parsed, {**self.BRIDGE, "env": {"KEEP": "1"}, "tools": {"a": {"approval_mode": "approve"}}})

    def test_codex_toml_inline_env_only_pat_drops_env(self) -> None:
        source, dest = self.toml_case(
            '[mcp_servers.github]\ncommand = "npx"\nargs = ["-y", "@modelcontextprotocol/server-github"]\n'
            'env = { GITHUB_PERSONAL_ACCESS_TOKEN = "t" }\n'
        )
        self.sync("codex-config", source, dest)
        self.assertEqual(tomllib.loads(dest.read_text())["mcp_servers"]["github"], self.BRIDGE)

    def test_filtered_env_vars_survive_repeated_state_backed_syncs(self) -> None:
        source, dest = self.toml_case(
            '[mcp_servers.github]\ncommand = "npx"\nargs = ["-y", "@modelcontextprotocol/server-github"]\n'
            'env_vars = ["GITHUB_PERSONAL_ACCESS_TOKEN", "KEEP"]\n'
        )
        for _ in range(3):
            self.sync("codex-config", source, dest)
            parsed = tomllib.loads(dest.read_text())["mcp_servers"]["github"]
            self.assertEqual(parsed, {**self.BRIDGE, "env_vars": ["KEEP"]})
        state = json.loads(self.state.read_text())
        self.assertNotIn("/mcp_servers/github/env_vars", state[f"codex-config:{dest}"])

    def test_json_filtered_env_vars_survive_repeated_syncs(self) -> None:
        source, dest = self.claude({**self.NPM, "env_vars": ["GITHUB_API_TOKEN", "KEEP"]})
        for _ in range(3):
            self.sync("claude-mcp", source, dest)
            self.assertEqual(self.load(dest)["mcpServers"]["github"]["env_vars"], ["KEEP"])

    def test_force_replaces_non_dict_github_entry(self) -> None:
        source = self.write_json(self.tmp / "src.json", self.SERVERS)
        dest = self.write_json(self.tmp / "dest.json", {"mcpServers": {"github": "weird"}})
        self.sync("claude-mcp", source, dest)
        self.assertEqual(self.load(dest)["mcpServers"]["github"], "weird")
        self.sync("claude-mcp", source, dest, force=True)
        self.assertEqual(self.load(dest)["mcpServers"]["github"], self.BRIDGE)

    def test_codex_toml_custom_untouched(self) -> None:
        source = self.tmp / "src.toml"
        source.write_text(self.GH_TOML_SRC, encoding="utf-8")
        dest = self.tmp / "dest.toml"
        custom = '[mcp_servers.github]\nurl = "https://ghe.example.com/mcp"\n'
        dest.write_text(custom, encoding="utf-8")
        self.sync("codex-config", source, dest)
        self.assertEqual(dest.read_text(), custom)


class KeyedPluginListTestCase(MergeBase):
    """opencode ``plugins`` items keyed by package name (YAN-923)."""

    def setUp(self) -> None:
        super().setUp()
        self.source = self.tmp / "src.json"
        self.dest = self.tmp / "opencode.json"

    def sync(self, plugins: list, *extra: str, force: bool = False) -> subprocess.CompletedProcess[str]:
        self.write_json(self.source, {"plugins": plugins})
        return self.run_merge("opencode-config", self.source, self.dest, "plugins", force=force, extra=extra)

    def remove(self, plugins: list, *extra: str, force: bool = False) -> subprocess.CompletedProcess[str]:
        self.write_json(self.source, {"plugins": plugins})
        return self.run_merge(
            "opencode-config", self.source, self.dest, "plugins", force=force, extra=("--remove", *extra)
        )

    def plugins(self) -> list:
        return json.loads(self.dest.read_text())["plugins"]

    def owned(self) -> list[str]:
        return json.loads(self.state.read_text())[f"opencode-config:{self.dest}"]["/plugins"][ADDED_ITEMS_KEY]

    def test_selective_sync_adds_only_the_selected_item(self) -> None:
        self.write_json(self.dest, {"plugins": ["mine"]})

        self.sync(["@s/a@1", "b@1"], "--entries", "@s/a")

        self.assertEqual(self.plugins(), ["mine", "@s/a@1"])
        self.assertEqual(self.owned(), [value_hash("@s/a@1")])

    def test_selective_sync_keeps_ownership_of_unselected_items(self) -> None:
        self.sync(["a@1", "b@1"])

        self.sync(["a@2", "b@1"], "--entries", "a")

        self.assertEqual(self.plugins(), ["a@2", "b@1"])
        self.assertEqual(self.owned(), sorted([value_hash("a@2"), value_hash("b@1")]))

    def test_selective_remove_takes_one_item_and_its_hash_only(self) -> None:
        self.write_json(self.dest, {"plugins": ["mine"], "x": 1})
        self.sync(["a@1", "b@1"])

        result = self.remove(["a@1", "b@1"], "--entries", "a")

        self.assertNotIn("kept your local value", result.stdout)
        self.assertEqual(json.loads(self.dest.read_text()), {"plugins": ["mine", "b@1"], "x": 1})
        self.assertEqual(self.owned(), [value_hash("b@1")])

        self.remove(["a@1", "b@1"], "--entries", "b")

        self.assertEqual(json.loads(self.dest.read_text()), {"plugins": ["mine"], "x": 1})
        self.assertNotIn(f"opencode-config:{self.dest}", json.loads(self.state.read_text()))

    def test_version_bump_replaces_owned_item_in_place(self) -> None:
        self.write_json(self.dest, {"plugins": ["first", "last"]})
        self.sync(["pkg@1"])
        self.write_json(self.dest, {"plugins": ["first", "pkg@1", "last"]})

        result = self.sync(["pkg@2"])

        self.assertNotIn("kept your local value", result.stdout)
        self.assertEqual(self.plugins(), ["first", "pkg@2", "last"])
        self.assertEqual(self.owned(), [value_hash("pkg@2")])

    def test_owned_duplicates_from_old_unions_collapse(self) -> None:
        self.write_json(self.dest, {"plugins": ["pkg@1", "mine", "pkg@1.5"]})
        self.state.write_text(
            json.dumps(
                {
                    f"opencode-config:{self.dest}": {
                        "/plugins": {
                            "last_applied_sha256": "stale",
                            ADDED_ITEMS_KEY: [value_hash("pkg@1"), value_hash("pkg@1.5")],
                        }
                    }
                }
            )
        )

        self.sync(["pkg@2"])

        self.assertEqual(self.plugins(), ["pkg@2", "mine"])
        self.assertEqual(self.owned(), [value_hash("pkg@2")])

    def test_user_written_same_key_item_is_kept_with_warning(self) -> None:
        self.write_json(self.dest, {"plugins": ["pkg@0"]})

        result = self.sync(["pkg@1"])

        self.assertEqual(self.plugins(), ["pkg@0"])
        self.assertIn("kept your local value at /plugins[pkg] (re-run with --force", result.stdout)

    def test_force_takes_user_written_same_key_item(self) -> None:
        self.write_json(self.dest, {"plugins": ["mine", "pkg@0"]})

        self.sync(["pkg@1"], force=True)

        self.assertEqual(self.plugins(), ["mine", "pkg@1"])
        self.assertEqual(self.owned(), [value_hash("pkg@1")])

    def test_force_takes_every_user_written_same_key_item(self) -> None:
        self.write_json(self.dest, {"plugins": ["pkg@0", "mine", {"package": "pkg@0.5"}]})

        self.sync(["pkg@1"], force=True)

        self.assertEqual(self.plugins(), ["pkg@1", "mine"])
        self.assertEqual(self.owned(), [value_hash("pkg@1")])

    def test_npm_alias_version_bump_replaces_owned_item(self) -> None:
        self.sync(["npm:@s/x@1"])

        self.sync(["npm:@s/x@2"])

        self.assertEqual(self.plugins(), ["npm:@s/x@2"])
        self.assertEqual(self.owned(), [value_hash("npm:@s/x@2")])

    def test_git_ref_bump_replaces_owned_item(self) -> None:
        self.sync(["git+https://example.com/x.git#v1"])

        self.sync(["git+https://example.com/x.git#v2"])

        self.assertEqual(self.plugins(), ["git+https://example.com/x.git#v2"])

    def test_object_items_are_keyed_by_package(self) -> None:
        self.sync(["@s/p@1"])
        item = {"package": "@s/p@2", "options": {"level": 1}}

        self.sync([item])

        self.assertEqual(self.plugins(), [item])
        self.assertEqual(self.owned(), [value_hash(item)])

    def test_remove_keeps_user_same_key_item_unless_forced(self) -> None:
        self.write_json(self.dest, {"plugins": ["pkg@0"], "x": 1})

        result = self.remove(["pkg@1"])

        self.assertEqual(self.plugins(), ["pkg@0"])
        self.assertIn("kept your local value at /plugins[pkg] (re-run with --force to remove it)", result.stdout)

        self.remove(["pkg@1"], force=True)

        self.assertEqual(json.loads(self.dest.read_text()), {"x": 1})

    def test_selective_remove_never_reports_unselected_items(self) -> None:
        self.write_json(self.dest, {"plugins": ["b@0"], "x": 1})
        self.sync(["a@1", "b@1"], "--entries", "a")

        result = self.remove(["a@1", "b@1"], "--entries", "a")

        self.assertNotIn("kept your local value", result.stdout)
        self.assertEqual(self.plugins(), ["b@0"])


class MarketplaceRetentionTestCase(MergeBase):
    """Claude marketplaces follow their plugins and stay while still used (YAN-923)."""

    OFFICIAL = {"source": {"source": "github", "repo": "anthropics/claude-plugins-official"}}
    YCC = {"source": {"source": "github", "repo": "yandy-r/ystack"}}
    LIST_ITEM = {"name": "claude-plugins-official", "url": "https://official"}

    def setUp(self) -> None:
        super().setUp()
        self.source = self.write_json(
            self.tmp / "settings-src.json",
            {
                "enabledPlugins": {
                    "ycc@ycc": True,
                    "superpowers@claude-plugins-official": True,
                    "context7@claude-plugins-official": True,
                },
                "extraKnownMarketplaces": {"ycc": self.YCC, "claude-plugins-official": self.OFFICIAL},
                "pluginMarketplaces": [self.LIST_ITEM],
            },
        )
        self.dest = self.write_json(self.tmp / "settings.json", {"keep": True})
        self.run_merge("claude-settings", self.source, self.dest, "plugins")

    def remove(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return self.run_merge("claude-settings", self.source, self.dest, "plugins", extra=("--remove", *extra))

    def state_entry(self) -> dict:
        return json.loads(self.state.read_text()).get(f"claude-settings:{self.dest}", {})

    def test_removing_one_of_two_plugins_keeps_their_marketplace(self) -> None:
        result = self.remove("--entries", "superpowers@claude-plugins-official")

        self.assertIn(
            "[ok] kept /extraKnownMarketplaces/claude-plugins-official "
            "(still used by context7@claude-plugins-official)",
            result.stdout,
        )
        self.assertIn("[ok] kept /pluginMarketplaces[claude-plugins-official]", result.stdout)
        settings = json.loads(self.dest.read_text())
        self.assertEqual(list(settings["enabledPlugins"]), ["ycc@ycc", "context7@claude-plugins-official"])
        self.assertEqual(
            settings["extraKnownMarketplaces"], {"ycc": self.YCC, "claude-plugins-official": self.OFFICIAL}
        )
        self.assertEqual(settings["pluginMarketplaces"], [self.LIST_ITEM])
        state = self.state_entry()
        self.assertIn("/extraKnownMarketplaces/claude-plugins-official", state)
        self.assertEqual(state["/pluginMarketplaces"][ADDED_ITEMS_KEY], [value_hash(self.LIST_ITEM)])
        self.assertNotIn("/enabledPlugins/superpowers@claude-plugins-official", state)

    def test_removing_the_last_user_removes_marketplace_and_list_item(self) -> None:
        self.remove("--entries", "superpowers@claude-plugins-official")

        result = self.remove("--entries", "context7@claude-plugins-official")

        self.assertNotIn("[ok] kept", result.stdout)
        settings = json.loads(self.dest.read_text())
        self.assertEqual(
            settings,
            {"keep": True, "enabledPlugins": {"ycc@ycc": True}, "extraKnownMarketplaces": {"ycc": self.YCC}},
        )
        state = self.state_entry()
        self.assertNotIn("/pluginMarketplaces", state)
        self.assertNotIn("/extraKnownMarketplaces/claude-plugins-official", state)
        self.assertIn("/extraKnownMarketplaces/ycc", state)

    def test_user_added_plugin_keeps_marketplace_on_full_remove(self) -> None:
        settings = json.loads(self.dest.read_text())
        settings["enabledPlugins"]["mine@claude-plugins-official"] = True
        self.write_json(self.dest, settings)

        result = self.remove()

        self.assertIn("(still used by mine@claude-plugins-official)", result.stdout)
        self.assertEqual(
            json.loads(self.dest.read_text()),
            {
                "keep": True,
                "enabledPlugins": {"mine@claude-plugins-official": True},
                "extraKnownMarketplaces": {"claude-plugins-official": self.OFFICIAL},
                "pluginMarketplaces": [self.LIST_ITEM],
            },
        )
        # Ownership survives, so a later remove can still take them back.
        self.assertEqual(
            set(self.state_entry()), {"/extraKnownMarketplaces/claude-plugins-official", "/pluginMarketplaces"}
        )

    def test_selected_plugin_kept_as_conflict_keeps_its_marketplace(self) -> None:
        settings = json.loads(self.dest.read_text())
        settings["enabledPlugins"]["context7@claude-plugins-official"] = False
        self.write_json(self.dest, settings)

        result = self.remove("--entries", "superpowers@claude-plugins-official,context7@claude-plugins-official")

        self.assertIn("kept your local value at /enabledPlugins/context7@claude-plugins-official", result.stdout)
        self.assertIn("(still used by context7@claude-plugins-official)", result.stdout)
        self.assertIn("claude-plugins-official", json.loads(self.dest.read_text())["extraKnownMarketplaces"])


class ProjectSettingsGroupTestCase(MergeBase):
    """``settings-project``: fail-closed allowlists for project-scope settings (YAN-218)."""

    PROJECT_PROFILES = ("claude-settings", "codex-config", "opencode-config")
    CLAUDE_SOURCE = REPO_ROOT / "ycc" / "settings" / "settings.json"
    CODEX_SOURCE = REPO_ROOT / ".codex-plugin" / "config" / "config.toml"
    OPENCODE_SOURCE = REPO_ROOT / ".opencode-plugin" / "opencode.json"

    def project_paths(self, profile: str) -> set[tuple[str, ...]]:
        return {tuple(rule["path"]) for rule in PROFILES[profile]["groups"][PROJECT_GROUP]}

    def has_state(self, destination: Path, *extra: str, profile: str = "claude-settings") -> int:
        env = {**os.environ, "YCC_MANAGED_CONFIG_STATE": str(self.state)}
        argv = [sys.executable, str(HELPER), "--profile", profile, "--destination", str(destination), "--has-state"]
        return subprocess.run([*argv, *extra], capture_output=True, text=True, env=env).returncode

    # -- allowlists -------------------------------------------------------

    def test_only_three_profiles_have_a_project_group(self) -> None:
        self.assertEqual(
            sorted(name for name, profile in PROFILES.items() if PROJECT_GROUP in profile["groups"]),
            sorted(self.PROJECT_PROFILES),
        )

    def test_claude_project_allowlist_is_preference_only(self) -> None:
        self.assertEqual(
            self.project_paths("claude-settings"),
            {("env",), ("attribution",), ("model",), ("modelSettings",), ("alwaysThinkingEnabled",), ("effortLevel",)},
        )
        for key in (
            "statusLine",
            "permissions",
            "skipAutoPermissionPrompt",
            "skipDangerousModePermissionPrompt",
            "hooks",
            "enabledPlugins",
            "extraKnownMarketplaces",
            "pluginMarketplaces",
        ):
            self.assertNotIn((key,), self.project_paths("claude-settings"))

    def test_codex_project_allowlist_excludes_ignored_and_posture_keys(self) -> None:
        top_level = {path[0] for path in self.project_paths("codex-config")}
        self.assertEqual(top_level & PROJECT_IGNORED_KEYS["codex-config"], set())
        for key in ("approval_policy", "approvals_reviewer", "sandbox_mode", "sandbox_workspace_write", "plugins"):
            self.assertNotIn(key, top_level)
        self.assertIn("model", top_level)

    def test_drift_guard_rejects_unknown_allowlisted_path(self) -> None:
        rules = [{"path": ["model"], "policy": "scalar"}]
        self.assertEqual(project_subset(rules, (("model",),), "probe"), rules)
        with self.assertRaisesRegex(ValueError, "probe: settings-project allowlist .*: statusLine"):
            project_subset(rules, (("model",), ("statusLine",)), "probe")

    def test_ignored_keys_guard_rejects_leaked_key(self) -> None:
        profiles = {"codex-config": {"groups": {PROJECT_GROUP: [{"path": ["notify"], "policy": "scalar"}]}}}
        with self.assertRaisesRegex(ValueError, "codex-config: .*ignored at project level: notify"):
            check_project_ignored_keys(profiles, PROJECT_IGNORED_KEYS)

    # -- merge / remove ---------------------------------------------------

    def test_claude_project_merge_writes_only_allowlisted_keys(self) -> None:
        destination = self.write_json(self.tmp / "settings.json", {"editorMode": "vim", "env": {"MINE": "1"}})

        self.run_merge("claude-settings", self.CLAUDE_SOURCE, destination, PROJECT_GROUP)

        merged = json.loads(destination.read_text())
        self.assertEqual(
            set(merged),
            {"editorMode", "env", "attribution", "model", "modelSettings", "alwaysThinkingEnabled", "effortLevel"},
        )
        self.assertEqual(merged["env"]["MINE"], "1")
        self.assertIn("CLAUDE_CODE_SUBAGENT_MODEL", merged["env"])

    def test_claude_project_remove_strips_only_owned_managed_keys(self) -> None:
        status_line = json.loads(self.CLAUDE_SOURCE.read_text())["statusLine"]
        destination = self.write_json(
            self.tmp / "settings.json", {"editorMode": "vim", "env": {"MINE": "1"}, "statusLine": status_line}
        )
        self.run_merge("claude-settings", self.CLAUDE_SOURCE, destination, PROJECT_GROUP)
        edited = json.loads(destination.read_text())
        edited["model"] = "opus[1m]"
        self.write_json(destination, edited)

        result = self.run_merge("claude-settings", self.CLAUDE_SOURCE, destination, PROJECT_GROUP, extra=("--remove",))

        self.assertIn("kept your local value at /model", result.stdout)
        # statusLine equals the repo value but is outside the project group: untouched.
        self.assertEqual(
            json.loads(destination.read_text()),
            {"editorMode": "vim", "env": {"MINE": "1"}, "statusLine": status_line, "model": "opus[1m]"},
        )

    def test_owned_only_remove_keeps_equal_unrecorded_keys(self) -> None:
        # The HIGH regression: a committed project file whose values match the
        # repo byte for byte must lose nothing ycc never wrote — including
        # children of object rules (here: env's leaves).
        source = json.loads(self.CLAUDE_SOURCE.read_text())
        initial = {
            "alwaysThinkingEnabled": source["alwaysThinkingEnabled"],
            "effortLevel": source["effortLevel"],
            "env": dict(source["env"]),
        }
        destination = self.write_json(self.tmp / "settings.json", initial)

        result = self.run_merge(
            "claude-settings", self.CLAUDE_SOURCE, destination, PROJECT_GROUP, extra=("--remove", "--owned-only")
        )

        self.assertIn("kept your local value at /alwaysThinkingEnabled", result.stdout)
        self.assertIn("kept your local value at /env/FORCE_AUTOUPDATE_PLUGINS", result.stdout)
        self.assertEqual(json.loads(destination.read_text()), initial)

    def test_owned_only_remove_takes_recorded_keys(self) -> None:
        # Recorded ownership still wins at project scope: a sync that wrote the
        # key lets remove take it back (equal-value shortcut stays disabled).
        destination = self.tmp / "settings.json"
        self.run_merge("claude-settings", self.CLAUDE_SOURCE, destination, PROJECT_GROUP, extra=("--owned-only",))

        self.run_merge(
            "claude-settings", self.CLAUDE_SOURCE, destination, PROJECT_GROUP, extra=("--remove", "--owned-only")
        )

        self.assertFalse(destination.exists())

    def test_owned_only_sync_adopts_nothing(self) -> None:
        # An unchanged project file (managed values already equal to the repo)
        # must not have its keys recorded as tool-owned at project scope.
        source = json.loads(self.CLAUDE_SOURCE.read_text())
        destination = self.write_json(
            self.tmp / "settings.json",
            {
                "env": dict(source["env"]),
                "attribution": dict(source["attribution"]),
                "model": source["model"],
                "modelSettings": source["modelSettings"],
                "alwaysThinkingEnabled": source["alwaysThinkingEnabled"],
                "effortLevel": source["effortLevel"],
            },
        )

        result = self.run_merge(
            "claude-settings", self.CLAUDE_SOURCE, destination, PROJECT_GROUP, extra=("--owned-only",)
        )

        self.assertIn("up-to-date", result.stdout)
        self.assertFalse(self.state.exists())
        # And the unflagged behavior is unchanged (adoption still happens).
        self.run_merge("claude-settings", self.CLAUDE_SOURCE, destination, PROJECT_GROUP)
        state = json.loads(self.state.read_text())
        self.assertTrue(state[f"claude-settings:{destination}"])

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root can read a mode-0 file")
    def test_has_state_unreadable_state_file_exits_2(self) -> None:
        # An I/O error must not read as "no state" (exit 1).
        self.state.write_text("{}", encoding="utf-8")
        self.state.chmod(0)
        try:
            self.assertEqual(self.has_state(self.tmp / "settings.json"), 2)
        finally:
            self.state.chmod(0o600)

    def test_has_state_invalid_utf8_exits_2(self) -> None:
        self.state.write_bytes(b"\xff")

        self.assertEqual(self.has_state(self.tmp / "settings.json"), 2)

    def test_codex_project_merge_and_remove_keep_comments_and_trust(self) -> None:
        destination = self.tmp / "config.toml"
        original = '# mine\n[projects."/p"]\ntrust_level = "trusted"\n'
        destination.write_text(original, encoding="utf-8")

        self.run_merge("codex-config", self.CODEX_SOURCE, destination, PROJECT_GROUP)

        text = destination.read_text()
        parsed = tomllib.loads(text)
        self.assertIn("# mine", text)
        self.assertEqual(parsed["model"], "gpt-6-astra")
        self.assertTrue(parsed["agents"]["enabled"])
        self.assertTrue(parsed["features"]["multi_agent"])
        for key in ("approval_policy", "approvals_reviewer", "sandbox_mode", "sandbox_workspace_write"):
            self.assertNotIn(key, parsed)
        for key in ("plugins", "mcp_servers", "tui", "notice", "apps"):
            self.assertNotIn(key, parsed)
        self.assertEqual(parsed["projects"], {"/p": {"trust_level": "trusted"}})

        self.run_merge("codex-config", self.CODEX_SOURCE, destination, PROJECT_GROUP, extra=("--remove",))

        text = destination.read_text()
        self.assertIn("# mine", text)
        parsed = tomllib.loads(text)
        # Object-policy tables keep an empty header after removal, as at global scope.
        self.assertEqual(
            {key: value for key, value in parsed.items() if value}, {"projects": {"/p": {"trust_level": "trusted"}}}
        )

    def test_opencode_project_merge_preserves_jsonc_and_credentials(self) -> None:
        destination = self.tmp / "opencode.json"
        destination.write_text(
            '{\n  // mine\n  "providers": { "9router": { "options": { "apiKey": "sk-private" } } },\n}\n',
            encoding="utf-8",
        )

        result = self.run_merge("opencode-config", self.OPENCODE_SOURCE, destination, PROJECT_GROUP)

        self.assertIn("JSONC", result.stdout)
        merged = json.loads(destination.read_text())
        self.assertEqual(merged["providers"]["9router"]["options"]["apiKey"], "sk-private")
        self.assertEqual(merged["experimental"]["subagent_depth"], 2)
        self.assertIn("$schema", merged)
        self.assertNotIn("plugins", merged)
        self.assertNotIn("mcp", merged)

    def test_project_and_global_state_do_not_interfere(self) -> None:
        global_dest = self.tmp / "home" / "settings.json"
        project_dest = self.tmp / "project" / ".claude" / "settings.json"
        self.run_merge("claude-settings", self.CLAUDE_SOURCE, global_dest, "settings")
        self.run_merge("claude-settings", self.CLAUDE_SOURCE, project_dest, PROJECT_GROUP)
        global_before = global_dest.read_bytes()

        self.run_merge("claude-settings", self.CLAUDE_SOURCE, project_dest, PROJECT_GROUP, extra=("--remove",))

        self.assertFalse(project_dest.exists())
        self.assertEqual(global_dest.read_bytes(), global_before)
        state = json.loads(self.state.read_text())
        self.assertIn(f"claude-settings:{global_dest}", state)
        self.assertNotIn(f"claude-settings:{project_dest}", state)
        self.assertEqual(self.has_state(global_dest), 0)
        self.assertEqual(self.has_state(project_dest), 1)

    # -- --has-state ------------------------------------------------------

    def test_has_state_without_state_file_is_false_and_writes_nothing(self) -> None:
        destination = self.tmp / "settings.json"

        self.assertEqual(self.has_state(destination), 1)
        self.assertEqual(self.has_state(destination, "--source", "/dev/null"), 1)
        self.assertFalse(self.state.exists())
        self.assertFalse(destination.exists())

    def test_has_state_exit_codes(self) -> None:
        destination = self.tmp / "settings.json"
        self.run_merge("claude-settings", self.CLAUDE_SOURCE, destination, PROJECT_GROUP)
        state_before = self.state.read_bytes()

        self.assertEqual(self.has_state(destination, "--source", "/dev/null"), 0)
        self.assertEqual(self.has_state(destination, "--groups", PROJECT_GROUP), 0)
        self.assertEqual(self.has_state(destination, "--groups", "settings"), 0)
        self.assertEqual(self.has_state(destination, "--groups", "plugins"), 1)
        self.assertEqual(self.has_state(destination, "--groups", "nope"), 2)
        self.assertEqual(self.has_state(self.tmp / "other.json"), 1)
        self.assertEqual(self.has_state(destination, profile="codex-config"), 1)
        self.assertEqual(self.has_state(destination, "--state-scope", "x"), 1)
        self.assertEqual(self.has_state(destination, "--state-scope", "bad scope"), 2)
        self.assertEqual(self.state.read_bytes(), state_before)

    def test_has_state_honours_state_scope(self) -> None:
        source = self.write_json(self.tmp / "src.json", {"plugins": ["repo-a"]})
        destination = self.tmp / "opencode.json"
        self.run_merge("opencode-catalog", source, destination, "plugins", extra=("--state-scope", "repo-a"))

        self.assertEqual(self.has_state(destination, "--state-scope", "repo-a", profile="opencode-catalog"), 0)
        self.assertEqual(self.has_state(destination, "--state-scope", "repo-b", profile="opencode-catalog"), 1)
        self.assertEqual(self.has_state(destination, profile="opencode-catalog"), 1)

    def test_merge_still_requires_source_and_groups(self) -> None:
        env = {**os.environ, "YCC_MANAGED_CONFIG_STATE": str(self.state)}
        argv = [sys.executable, str(HELPER), "--profile", "claude-settings", "--destination", str(self.tmp / "d")]
        result = subprocess.run(argv, capture_output=True, text=True, env=env)

        self.assertEqual(result.returncode, 2)
        self.assertIn("--source and --groups are required", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
