#!/usr/bin/env python3
"""Unit tests for scripts/codex_marketplace.py.

Run directly (``python3 scripts/test_codex_marketplace.py``) or through
``./scripts/validate.sh --only config``.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HELPER = REPO_ROOT / "scripts" / "codex_marketplace.py"


class CodexMarketplaceTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.dest = self.tmp / "marketplace.json"
        self.addCleanup(self._tmp.cleanup)

    def run_helper(self, *args: str, expect_success: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [sys.executable, str(HELPER), *args],
            capture_output=True,
            text=True,
        )
        if expect_success:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def merge(
        self, mode: str = "local", src: str = "./.agents/plugins/ycc", expect_success: bool = True
    ) -> subprocess.CompletedProcess[str]:
        return self.run_helper("merge", str(self.dest), mode, src, expect_success=expect_success)

    def test_merge_local_missing_file(self) -> None:
        self.merge()
        text = self.dest.read_text(encoding="utf-8")
        self.assertTrue(text.endswith("\n"))
        data = json.loads(text)
        self.assertEqual(data["name"], "local-ycc-plugins")
        self.assertEqual(data["interface"], {"displayName": "Local YCC Plugins"})
        self.assertEqual(len(data["plugins"]), 1)
        self.assertEqual(
            data["plugins"][0]["source"],
            {"source": "local", "path": "./.agents/plugins/ycc"},
        )

    def test_merge_local_rejects_non_relative_path(self) -> None:
        result = self.merge(src="/abs/ycc", expect_success=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("must start with ./", result.stderr)
        self.assertFalse(self.dest.exists())

    def test_merge_repo(self) -> None:
        self.merge("repo")
        data = json.loads(self.dest.read_text(encoding="utf-8"))
        self.assertEqual(
            data["plugins"][0]["source"],
            {
                "source": "git-subdir",
                "url": "https://github.com/yandy-r/ystack.git",
                "path": "./.codex-plugin/ycc",
                "ref": "main",
            },
        )

    def test_emitted_source_tags_are_codex_supported(self) -> None:
        # Source tags accepted by Codex's marketplace parser; see openai/codex
        # rust-v0.161.0 codex-rs/core-plugins/src/marketplace.rs.
        codex_supported_tags = {"local", "url", "git-subdir", "npm"}
        for mode, src in (("local", "./.agents/plugins/ycc"), ("repo", "")):
            with self.subTest(mode=mode):
                self.dest.unlink(missing_ok=True)
                self.merge(mode, src)
                data = json.loads(self.dest.read_text(encoding="utf-8"))
                ycc = [p for p in data["plugins"] if p["name"] == "ycc"]
                self.assertEqual(len(ycc), 1)
                self.assertIn(ycc[0]["source"]["source"], codex_supported_tags)

    def test_merge_repo_replaces_legacy_github_ycc_entry_idempotently(self) -> None:
        other = {"name": "other", "source": {"source": "github", "repo": "a/b"}}
        legacy = {
            "name": "ycc",
            "source": {"source": "github", "repo": "yandy-r/ystack", "ref": "main"},
        }
        self.dest.write_text(json.dumps({"name": "custom", "plugins": [other, legacy]}), encoding="utf-8")
        self.merge("repo")
        first = self.dest.read_bytes()
        self.merge("repo")
        self.assertEqual(self.dest.read_bytes(), first)
        data = json.loads(first.decode("utf-8"))
        self.assertEqual([p["name"] for p in data["plugins"]], ["other", "ycc"])
        self.assertEqual(data["plugins"][0], other)
        self.assertEqual(
            data["plugins"][1]["source"],
            {
                "source": "git-subdir",
                "url": "https://github.com/yandy-r/ystack.git",
                "path": "./.codex-plugin/ycc",
                "ref": "main",
            },
        )

    def test_merge_preserves_and_replaces_in_place(self) -> None:
        other = {"name": "other", "source": {"source": "github", "repo": "a/b"}}
        self.dest.write_text(
            json.dumps({"name": "custom", "interface": {"displayName": "Custom"}, "plugins": [other]}),
            encoding="utf-8",
        )
        self.merge()
        self.merge()
        data = json.loads(self.dest.read_text(encoding="utf-8"))
        self.assertEqual(data["name"], "custom")
        self.assertEqual(data["interface"], {"displayName": "Custom"})
        self.assertEqual([p["name"] for p in data["plugins"]], ["other", "ycc"])
        self.assertEqual(data["plugins"][0], other)

    def test_merge_rejects_root_array(self) -> None:
        self.dest.write_text("[]", encoding="utf-8")
        result = self.merge(expect_success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must contain a JSON object", result.stderr)

    def test_remove_keeps_other_plugins(self) -> None:
        other = {"name": "other", "source": {"source": "github", "repo": "a/b"}}
        self.dest.write_text(
            json.dumps({"name": "custom", "plugins": [other, {"name": "ycc"}]}),
            encoding="utf-8",
        )
        result = self.run_helper("remove", str(self.dest))
        self.assertIn("removed the ycc entry from", result.stdout)
        data = json.loads(self.dest.read_text(encoding="utf-8"))
        self.assertEqual(data["plugins"], [other])

    def test_remove_deletes_scaffold_only_file(self) -> None:
        self.merge()
        result = self.run_helper("remove", str(self.dest))
        self.assertIn("only the ycc entry was left", result.stdout)
        self.assertFalse(self.dest.exists())

    def test_remove_no_ycc_entry_noop(self) -> None:
        original = '{"name":"custom","plugins":[{"name":"other"}]}\n'
        self.dest.write_text(original, encoding="utf-8")
        result = self.run_helper("remove", str(self.dest))
        self.assertIn("nothing to remove", result.stdout)
        self.assertEqual(self.dest.read_text(encoding="utf-8"), original)

    def test_remove_dry_run_previews_entry_removal_without_writes(self) -> None:
        other = {"name": "other", "source": {"source": "github", "repo": "a/b"}}
        original = json.dumps({"name": "custom", "plugins": [other, {"name": "ycc"}]})
        self.dest.write_text(original, encoding="utf-8")
        result = self.run_helper("remove", "--dry-run", str(self.dest))
        self.assertEqual(result.stdout, f"[dry-run] would remove marketplace entry ycc from {self.dest}\n")
        self.assertEqual(self.dest.read_text(encoding="utf-8"), original)

    def test_remove_dry_run_previews_scaffold_only_deletion_without_writes(self) -> None:
        self.merge()
        original = self.dest.read_text(encoding="utf-8")
        result = self.run_helper("remove", "--dry-run", str(self.dest))
        self.assertEqual(result.stdout, f"[dry-run] would remove {self.dest} (only the ycc entry was left)\n")
        self.assertEqual(self.dest.read_text(encoding="utf-8"), original)

    def test_remove_dry_run_no_ycc_entry_noop(self) -> None:
        self.dest.write_text('{"name":"custom","plugins":[{"name":"other"}]}\n', encoding="utf-8")
        result = self.run_helper("remove", "--dry-run", str(self.dest))
        self.assertIn("nothing to remove", result.stdout)


if __name__ == "__main__":
    unittest.main()
