#!/usr/bin/env python3
"""Tests for opencode_plugin_catalog.py and the merge helper's --state-scope.

Run directly (``python3 scripts/test_opencode_plugin_catalog.py``) or through
``./scripts/validate.sh --only config``.
"""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
CLI = REPO_ROOT / "scripts" / "opencode_plugin_catalog.py"
HELPER = REPO_ROOT / "scripts" / "merge_managed_config.py"
COMPANION = b'{"preset": "openai"}\n'

ENTRY: dict[str, Any] = {
    "package": "demo-plugin@1.2.3",
    "default": False,
    "config_files": [{"source": "demo/demo.json", "destination": "demo.json"}],
    "managed_keys": {"agents": {"explore": {"disabled": True}}},
    "notes": ["Add `export DEMO=1` to your shell rc; set lsp yourself."],
}


class CatalogBase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.state = self.tmp / "state" / "managed-config-state.json"
        self.catalog = self.tmp / "settings" / "opencode-plugins.json"
        (self.tmp / "settings" / "demo").mkdir(parents=True)
        self.companion_source = self.tmp / "settings" / "demo" / "demo.json"
        self.companion_source.write_bytes(COMPANION)
        self.write_catalog({"demo-plugin": ENTRY})

    def write_catalog(self, plugins: dict[str, Any]) -> None:
        self.catalog.write_text(json.dumps({"plugins": plugins}), encoding="utf-8")

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = {**os.environ, "YCC_MANAGED_CONFIG_STATE": str(self.state)}
        argv = [sys.executable, str(CLI), *args, "--catalog", str(self.catalog)]
        return subprocess.run(argv, capture_output=True, text=True, env=env)


class ValidateTestCase(CatalogBase):
    def assert_invalid(self, change: dict[str, Any], needle: str, name: str = "demo-plugin") -> None:
        entry = copy.deepcopy(ENTRY)
        entry.update(change)
        self.write_catalog({name: entry})
        result = self.run_cli("validate")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(needle, result.stderr)

    def test_valid_catalog_passes(self) -> None:
        result = self.run_cli("validate")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_shipped_catalog_passes(self) -> None:
        result = subprocess.run([sys.executable, str(CLI), "validate"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unpinned_package(self) -> None:
        self.assert_invalid({"package": "demo-plugin"}, "exact version")

    def test_range_package(self) -> None:
        self.assert_invalid({"package": "demo-plugin@^1.2.3"}, "exact version")

    def test_tag_package(self) -> None:
        self.assert_invalid({"package": "demo-plugin@latest"}, "exact version")

    def test_v1_disable_key(self) -> None:
        self.assert_invalid({"managed_keys": {"agents": {"explore": {"disable": True}}}}, "disable")

    def test_default_true(self) -> None:
        self.assert_invalid({"default": True}, "default must be false")

    def test_bad_destination(self) -> None:
        for destination in ("../x.json", "sub/x.json", ""):
            with self.subTest(destination=destination):
                files = [{"source": "demo/demo.json", "destination": destination}]
                self.assert_invalid({"config_files": files}, "plain file name")

    def test_missing_source(self) -> None:
        files = [{"source": "demo/missing.json", "destination": "demo.json"}]
        self.assert_invalid({"config_files": files}, "is not a file")

    def test_name_key_mismatch(self) -> None:
        self.assert_invalid({}, "must equal the package name", name="other-name")

    def test_unknown_key_and_managed_key(self) -> None:
        self.assert_invalid({"tui": True}, "unknown key 'tui'")
        self.assert_invalid({"managed_keys": {"model": "x"}}, "managed_keys.model")

    def test_invalid_npm_name(self) -> None:
        for name in ("a/../../..", "Upper-Case", "@scope/../x", "./x", "@scope//x"):
            with self.subTest(name=name):
                self.assert_invalid({"package": f"{name}@1.0.0"}, "not a valid npm package name", name=name)

    def test_reserved_destination(self) -> None:
        reserved = ("opencode.json", "opencode.jsonc", "tui.json", "tui.jsonc", "cli.json", "AGENTS.md", ".hidden")
        units = ("skills", "agents", "commands", "shared", "ycc-sensitive-guard")
        for destination in (*reserved, *units):
            with self.subTest(destination=destination):
                files = [{"source": "demo/demo.json", "destination": destination}]
                self.assert_invalid({"config_files": files}, "is reserved")

    def test_bundle_name_collision(self) -> None:
        entry = {**ENTRY, "package": "@prevalentware/opencode-goal-plugin@1.0.0"}
        self.write_catalog({"@prevalentware/opencode-goal-plugin": entry})
        result = self.run_cli("validate")
        self.assertEqual(result.returncode, 1)
        self.assertIn("collides with a bundle plugin", result.stderr)


class CommandsTestCase(CatalogBase):
    def test_names_source_and_unknown(self) -> None:
        self.assertEqual(self.run_cli("names").stdout.split(), ["demo-plugin"])
        out = self.tmp / "source.json"
        result = self.run_cli("source", "--names", "demo-plugin", "--out", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(out.read_text(encoding="utf-8")),
            {"plugins": ["demo-plugin@1.2.3"], "agents": {"explore": {"disabled": True}}},
        )
        result = self.run_cli("notes", "--names", "demo-plugin,nope")
        self.assertEqual(result.returncode, 2)
        self.assertIn("[err] unknown catalog plugin 'nope' (catalog: demo-plugin)", result.stderr)

    def test_notes(self) -> None:
        self.assertIn("  [i] Add `export DEMO=1`", self.run_cli("notes", "--names", "demo-plugin").stdout)
        removal = self.run_cli("notes", "--names", "demo-plugin", "--remove").stdout
        self.assertIn("export DEMO=1", removal)
        self.assertIn('"lsp": true', removal)


class CompanionTestCase(CatalogBase):
    def setUp(self) -> None:
        super().setUp()
        self.dest_dir = self.tmp / "config" / "opencode"
        self.dest = self.dest_dir / "demo.json"

    def companions(self, action: str, *extra: str) -> str:
        result = self.run_cli("companions", action, "--names", "demo-plugin", "--dest-dir", str(self.dest_dir), *extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def owned(self) -> dict[str, str]:
        path = self.state.parent / "opencode-plugin-files.json"
        if not path.is_file():
            return {}
        hashes: dict[str, str] = json.loads(path.read_text(encoding="utf-8"))["sha256"]
        return hashes

    def test_fresh_write_records_hash(self) -> None:
        self.assertIn("[ok] wrote", self.companions("sync"))
        self.assertEqual(self.dest.read_bytes(), COMPANION)
        self.assertIn(str(self.dest), self.owned())

    def test_adopt_identical_file(self) -> None:
        self.dest_dir.mkdir(parents=True)
        self.dest.write_bytes(COMPANION)
        self.assertIn("up to date", self.companions("sync"))
        self.assertIn(str(self.dest), self.owned())

    def test_update_unchanged_file(self) -> None:
        self.companions("sync")
        self.companion_source.write_bytes(b'{"preset": "new"}\n')
        self.assertIn("[ok] updated", self.companions("sync"))
        self.assertEqual(self.dest.read_bytes(), b'{"preset": "new"}\n')

    def test_user_edit_kept_then_force(self) -> None:
        self.companions("sync")
        self.dest.write_bytes(b'{"preset": "mine"}\n')
        self.companion_source.write_bytes(b'{"preset": "new"}\n')
        self.assertIn("[!!] kept", self.companions("sync"))
        self.assertEqual(self.dest.read_bytes(), b'{"preset": "mine"}\n')
        self.companions("sync", "--force")
        self.assertEqual(self.dest.read_bytes(), b'{"preset": "new"}\n')

    def test_user_file_never_adopted(self) -> None:
        self.dest_dir.mkdir(parents=True)
        self.dest.write_bytes(b"{}\n")
        self.assertIn("[!!] kept", self.companions("sync"))
        self.assertEqual(self.dest.read_bytes(), b"{}\n")
        self.assertNotIn(str(self.dest), self.owned())

    def test_symlinked_destination_is_users(self) -> None:
        target = self.tmp / "elsewhere.json"
        target.write_bytes(b"{}\n")
        self.dest_dir.mkdir(parents=True)
        self.dest.symlink_to(target)
        self.assertIn("[!!] kept", self.companions("sync"))
        self.assertEqual(target.read_bytes(), b"{}\n")
        self.assertIn("[!!] kept", self.companions("remove"))
        self.assertTrue(self.dest.is_symlink())

    def test_remove_only_when_unchanged(self) -> None:
        self.companions("sync")
        self.dest.write_bytes(b'{"preset": "mine"}\n')
        self.assertIn("[!!] kept", self.companions("remove"))
        self.assertTrue(self.dest.exists())
        self.companions("remove", "--force")
        self.assertFalse(self.dest.exists())
        self.assertEqual(self.owned(), {})

    def test_remove_keeps_unrecorded_identical_file(self) -> None:
        # Equal to the shipped copy but never recorded: the plugin's own installer wrote it.
        self.dest_dir.mkdir(parents=True)
        self.dest.write_bytes(COMPANION)
        self.assertIn("[!!] kept", self.companions("remove"))
        self.assertEqual(self.dest.read_bytes(), COMPANION)

    def test_remove_owned_and_absent(self) -> None:
        self.companions("sync")
        self.companion_source.write_bytes(b'{"preset": "new"}\n')
        self.assertIn("[ok] removed", self.companions("remove"))
        self.assertFalse(self.dest.exists())
        self.assertEqual(self.owned(), {})

    def test_dry_run_sync_creates_no_destination_or_state(self) -> None:
        output = self.companions("sync", "--dry-run")
        self.assertIn(f"would copy {self.dest}", output)
        self.assertFalse(self.dest_dir.exists())
        self.assertEqual(self.owned(), {})

    def test_dry_run_does_not_adopt_identical_file(self) -> None:
        self.dest_dir.mkdir(parents=True)
        self.dest.write_bytes(COMPANION)
        self.assertIn("up to date", self.companions("sync", "--dry-run"))
        self.assertEqual(self.dest.read_bytes(), COMPANION)
        self.assertEqual(self.owned(), {})

    def test_dry_run_update_and_remove_preserve_bytes_and_state(self) -> None:
        self.companions("sync")
        state = self.state.parent / "opencode-plugin-files.json"
        before = state.read_bytes()
        self.companion_source.write_bytes(b'{"preset": "new"}\n')
        self.assertIn(f"would copy {self.dest}", self.companions("sync", "--dry-run"))
        self.assertEqual(self.dest.read_bytes(), COMPANION)
        self.assertEqual(state.read_bytes(), before)
        self.assertIn(f"would remove {self.dest}", self.companions("remove", "--dry-run"))
        self.assertEqual(self.dest.read_bytes(), COMPANION)
        self.assertEqual(state.read_bytes(), before)


class PurgeCacheTestCase(CatalogBase):
    def setUp(self) -> None:
        super().setUp()
        self.cache = self.tmp / "cache" / "opencode"
        scoped = {**ENTRY, "package": "@acme/tool@2.0.0", "config_files": [], "managed_keys": {}}
        self.write_catalog({"demo-plugin": ENTRY, "@acme/tool": scoped})

    def make(self, relative: str) -> Path:
        path = self.cache / relative
        path.mkdir(parents=True)
        (path / "index.js").write_text("x", encoding="utf-8")
        return path

    def purge(self, names: str) -> subprocess.CompletedProcess[str]:
        return self.run_cli("purge-cache", "--names", names, "--cache-dir", str(self.cache))

    def test_three_layouts_and_scoped(self) -> None:
        removed = [
            self.make("npm/demo-plugin@1.2.3"),
            self.make("npm/demo-plugin@1.0.0"),
            self.make("packages/demo-plugin@1.2.3"),
            self.make("node_modules/demo-plugin"),
            self.make("npm/@acme/tool@2.0.0"),
            self.make("packages/@acme/tool@2.0.0"),
            self.make("node_modules/@acme/tool"),
        ]
        kept = [
            self.make("npm/demo-plugin-extra@1.0.0"),
            self.make("npm/@acme/tool-other@1.0.0"),
            self.make("node_modules/other"),
        ]
        result = self.purge("demo-plugin,@acme/tool")
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in removed:
            self.assertFalse(path.exists(), path)
            self.assertIn(f"[ok] removed {path}", result.stdout)
        for path in kept:
            self.assertTrue(path.exists(), path)

    def test_nothing_cached(self) -> None:
        result = self.purge("demo-plugin")
        self.assertEqual(result.returncode, 0)
        self.assertIn("[ok] no cached copies of demo-plugin", result.stdout)

    def test_symlink_entry_unlinked_not_followed(self) -> None:
        outside = self.tmp / "outside"
        outside.mkdir()
        (outside / "keep.js").write_text("x", encoding="utf-8")
        (self.cache / "npm").mkdir(parents=True)
        link = self.cache / "npm" / "demo-plugin@1.2.3"
        link.symlink_to(outside, target_is_directory=True)
        result = self.purge("demo-plugin")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(link.is_symlink())
        self.assertTrue((outside / "keep.js").exists())

    def test_dot_segment_package_refused(self) -> None:
        # purge-cache never runs validate: the bad name reaches purge_package.
        bad = "a/../../.."
        self.write_catalog({bad: {"package": f"{bad}@1.0.0", "default": False}})
        precious = self.tmp / "cache" / "other" / "precious"
        precious.mkdir(parents=True)
        self.make("node_modules/a")
        result = self.purge(bad)
        self.assertEqual(result.returncode, 1)
        self.assertIn("[!!] refused", result.stdout)
        self.assertTrue(precious.is_dir())
        self.assertTrue((self.cache / "node_modules" / "a").is_dir())

    def test_dry_run_keeps_cached_copies(self) -> None:
        paths = [self.make("npm/demo-plugin@1.2.3"), self.make("node_modules/demo-plugin")]
        result = self.run_cli("purge-cache", "--names", "demo-plugin", "--cache-dir", str(self.cache), "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in paths:
            self.assertTrue(path.is_dir())
            self.assertIn(f"would remove {path}", result.stdout)

    def test_containment_checks_the_path_itself(self) -> None:
        sys.path.insert(0, str(CLI.parent))
        from opencode_plugin_catalog import contained

        self.make("node_modules/a")
        layout, root = self.cache / "node_modules", self.cache.resolve()
        self.assertTrue(contained(layout / "a", layout, root))
        for package in ("a/../../..", "a/..", "a/../..", "", "."):
            with self.subTest(package=package):
                self.assertFalse(contained(layout / package, layout, root))

    def test_symlink_escape_refused(self) -> None:
        outside = self.tmp / "outside"
        (outside / "demo-plugin@1.2.3").mkdir(parents=True)
        self.cache.mkdir(parents=True)
        (self.cache / "npm").symlink_to(outside, target_is_directory=True)
        (self.cache / "node_modules").mkdir()
        legacy_outside = self.tmp / "legacy"
        legacy_outside.mkdir()
        (self.cache / "node_modules" / "@acme").symlink_to(legacy_outside, target_is_directory=True)
        (legacy_outside / "tool").mkdir()
        result = self.purge("demo-plugin,@acme/tool")
        self.assertEqual(result.returncode, 1)
        self.assertIn("[!!] refused", result.stdout)
        self.assertTrue((outside / "demo-plugin@1.2.3").is_dir())
        self.assertTrue((legacy_outside / "tool").is_dir())


class LoadsAfterRemoveTestCase(CatalogBase):
    def setUp(self) -> None:
        super().setUp()
        self.destination = self.tmp / "opencode.json"
        self.source = self.tmp / "source.json"
        self.run_cli("source", "--names", "demo-plugin", "--out", str(self.source))

    def loads_after_remove(self) -> subprocess.CompletedProcess[str]:
        return self.run_cli(
            "loads-after-remove", "--destination", str(self.destination), "--name", "demo-plugin",
            "--source", str(self.source), "--profile", "opencode-catalog", "--groups", "plugins,agents",
            "--state-scope", "demo-plugin",
        )  # fmt: skip

    def test_owned_plugin_is_removed_from_projection_without_writes(self) -> None:
        env = {**os.environ, "YCC_MANAGED_CONFIG_STATE": str(self.state)}
        argv = [
            sys.executable, str(HELPER), "--profile", "opencode-catalog", "--source", str(self.source),
            "--destination", str(self.destination), "--groups", "plugins,agents", "--state-scope", "demo-plugin",
        ]  # fmt: skip
        merge = subprocess.run(argv, capture_output=True, text=True, env=env)
        self.assertEqual(merge.returncode, 0, merge.stderr)
        before = self.destination.read_bytes(), self.state.read_bytes()
        result = self.loads_after_remove()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual((self.destination.read_bytes(), self.state.read_bytes()), before)

    def test_local_plugin_or_projection_error_stays_loaded(self) -> None:
        self.destination.write_text('{"plugins": ["demo-plugin@1.2.3"]}\n', encoding="utf-8")
        result = self.loads_after_remove()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.destination.write_text("not json", encoding="utf-8")
        result = self.loads_after_remove()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_destination_does_not_load(self) -> None:
        result = self.loads_after_remove()
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_absent_entry_with_nothing_owned_does_not_load(self) -> None:
        self.destination.write_text('{"plugins": ["user-plugin"]}\n', encoding="utf-8")
        result = self.loads_after_remove()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.destination.write_text('{\n  // note\n  "plugins": ["user-plugin",],\n}\n', encoding="utf-8")
        result = self.loads_after_remove()
        self.assertEqual(result.returncode, 1, result.stderr)


class StateScopeTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.state = self.tmp / "state.json"
        self.dest = self.tmp / "opencode.json"
        self.seed = '{\n  "plugins": ["user-plugin"]\n}\n'
        self.dest.write_text(self.seed, encoding="utf-8")

    def merge(self, name: str, source: dict[str, Any], *extra: str) -> None:
        path = self.tmp / f"{name}.json"
        path.write_text(json.dumps(source), encoding="utf-8")
        env = {**os.environ, "YCC_MANAGED_CONFIG_STATE": str(self.state)}
        argv = [
            sys.executable, str(HELPER), "--profile", "opencode-catalog", "--source", str(path),
            "--destination", str(self.dest), "--groups", "plugins,agents", "--state-scope", name, *extra,
        ]  # fmt: skip
        result = subprocess.run(argv, capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def config(self) -> dict[str, Any]:
        data: dict[str, Any] = json.loads(self.dest.read_text(encoding="utf-8"))
        return data

    def test_independent_scopes(self) -> None:
        a = {"plugins": ["a-plugin@1.0.0"], "agents": {"explore": {"disabled": True}}}
        b = {"plugins": ["b-plugin@2.0.0"], "agents": {"general": {"disabled": True}}}
        self.merge("a-plugin", a)
        self.merge("b-plugin", b)
        self.assertEqual(self.config()["plugins"], ["user-plugin", "a-plugin@1.0.0", "b-plugin@2.0.0"])
        state = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertEqual(
            sorted(state),
            [f"opencode-catalog[a-plugin]:{self.dest}", f"opencode-catalog[b-plugin]:{self.dest}"],
        )
        # Re-syncing A alone never stale-deletes B's leaves.
        self.merge("a-plugin", a)
        self.merge("a-plugin", a, "--remove")
        self.assertEqual(
            self.config(),
            {"plugins": ["user-plugin", "b-plugin@2.0.0"], "agents": {"general": {"disabled": True}}},
        )
        self.merge("b-plugin", b, "--remove")
        self.assertEqual(self.config(), {"plugins": ["user-plugin"]})

    def test_catalog_owns_only_its_agent_leaves(self) -> None:
        bundle = self.tmp / "bundle.json"
        bundle.write_text(json.dumps({"agents": {"general": {"model": "m/x"}}}), encoding="utf-8")
        env = {**os.environ, "YCC_MANAGED_CONFIG_STATE": str(self.state)}
        argv = [
            sys.executable, str(HELPER), "--profile", "opencode-config", "--source", str(bundle),
            "--destination", str(self.dest), "--groups", "settings",
        ]  # fmt: skip
        self.assertEqual(subprocess.run(argv, capture_output=True, text=True, env=env).returncode, 0)
        slim = {"plugins": ["a-plugin@1.0.0"], "agents": {"general": {"disabled": True}}}
        self.merge("a-plugin", slim)
        self.assertEqual(self.config()["agents"], {"general": {"model": "m/x", "disabled": True}})
        self.merge("a-plugin", slim, "--remove")
        self.assertEqual(self.config()["agents"], {"general": {"model": "m/x"}})
        result = subprocess.run([*argv, "--remove"], capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("kept your local value", result.stdout)
        self.assertEqual(self.config(), {"plugins": ["user-plugin"]})

    def test_invalid_scope_rejected(self) -> None:
        argv = [
            sys.executable, str(HELPER), "--profile", "opencode-catalog", "--source", str(self.dest),
            "--destination", str(self.dest), "--groups", "plugins", "--state-scope", "bad scope",
        ]  # fmt: skip
        result = subprocess.run(argv, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid --state-scope", result.stderr)


if __name__ == "__main__":
    unittest.main()
