#!/usr/bin/env python3
"""Critical hidden Claude-native package boundary tests; run directly with Python's unittest."""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Callable
from dataclasses import replace
from functools import partial
from pathlib import Path
from typing import Any, cast
from unittest.mock import patch

import generate_claude_packages as generator
from package_model import Package, PackageModel, load_package_model

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "scripts/generate_claude_packages.py"
MCP_ROOT = Path("packages/claude/ycc-mcp")
HOOKS_ROOT = Path("packages/claude/ycc-hooks")
ALL_ROOT = Path("packages/claude/ycc-all")
AGENTS_ROOT = Path("packages/claude/ycc-agents")
CANONICAL_ROOT = Path("packages/claude/ycc")
HOOK_SCRIPT = Path("hooks/worktree-create.sh")
HOOK_REGISTRATIONS = Path("hooks/hooks.json")
UNREGISTERED_HOOK = Path("hooks/herdr-agent-state.sh")
MCP_CONFIG = Path(".mcp.json")
MANIFEST = Path(".claude-plugin/plugin.json")
PLUGIN_HOOK_COMMAND = 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/worktree-create.sh"'


def serialized(payload: object) -> bytes:
    return (json.dumps(payload, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def with_claude_runtime(model: PackageModel, key: str, **changes: Any) -> PackageModel:
    """Return a model whose Claude runtime entry for ``key`` has ``changes`` applied."""

    def update(package: Package) -> Package:
        if package.key != key:
            return package
        runtimes = tuple(
            replace(entry, **changes) if entry.runtime == "claude" else entry for entry in package.runtimes
        )
        return replace(package, runtimes=runtimes)

    return replace(model, packages=tuple(update(package) for package in model.packages))


class ClaudeNativePackageTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.dest = self.tmp / "export"

    @staticmethod
    def snapshot(root: Path) -> dict[Path, bytes]:
        return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}

    @staticmethod
    def json_at(root: Path, rel: Path) -> dict[str, Any]:
        return cast("dict[str, Any]", json.loads((root / rel).read_text(encoding="utf-8")))

    def patch_generator(self, name: str, value: object) -> None:
        patcher = patch.object(generator, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)

    def patch_settings(self, hooks: object) -> None:
        """Point the generator at a temp settings file with the given hook registrations."""
        source = self.tmp / "settings.json"
        source.write_text(json.dumps({"hooks": hooks}), encoding="utf-8")
        self.patch_generator("SOURCE_SETTINGS_PATH", source)

    def assert_all_modes_raise(self, dest: Path, pattern: str) -> None:
        actions: tuple[Callable[[], object], ...] = (
            lambda: generator.write_all(dest),
            lambda: generator.write_all(dest, dry_run=True),
            lambda: generator.run_check(dest),
        )
        for action in actions:
            with self.assertRaisesRegex(ValueError, pattern):
                action()

    def test_generated_tree_keeps_env_literal_and_selects_only_add_ons(self) -> None:
        with patch.dict(os.environ, {"XERO_CLIENT_ID": "SENTINEL", "XERO_CLIENT_SECRET": "SENTINEL"}):
            inventory = generator.write_all(self.dest)
        snapshot = self.snapshot(self.dest)
        self.assertEqual(set(snapshot), inventory)
        self.assertEqual({Path(*rel.parts[:3]) for rel in inventory}, {MCP_ROOT, HOOKS_ROOT, ALL_ROOT})
        self.assertFalse((self.dest / CANONICAL_ROOT).exists())
        self.assertFalse((self.dest / AGENTS_ROOT).exists())
        for content in snapshot.values():
            self.assertNotIn(b"SENTINEL", content)
        mcp_source = (REPO_ROOT / generator.SOURCE_MCP_PATH).read_bytes()
        self.assertEqual((self.dest / MCP_ROOT / MCP_CONFIG).read_bytes(), mcp_source)
        env = self.json_at(self.dest, MCP_ROOT / MCP_CONFIG)["mcpServers"]["xero"]["env"]
        self.assertEqual(env, {"XERO_CLIENT_ID": "${XERO_CLIENT_ID}", "XERO_CLIENT_SECRET": "${XERO_CLIENT_SECRET}"})

    def test_manifests_use_model_metadata_source_version_and_requires(self) -> None:
        generator.write_all(self.dest)
        model = load_package_model()
        source = generator.read_json(REPO_ROOT / model.version_source)
        for root, key in ((MCP_ROOT, "ycc-mcp"), (HOOKS_ROOT, "ycc-hooks"), (ALL_ROOT, "ycc-all")):
            manifest = self.json_at(self.dest, root / MANIFEST)
            expected = next(package for package in model.packages if package.key == key)
            self.assertEqual(manifest["name"], key)
            self.assertEqual(manifest["version"], source["version"])
            self.assertEqual(manifest["description"], expected.description)
            self.assertEqual(manifest["author"], source["author"])
            self.assertNotIn("listed", manifest)
        aggregate = self.json_at(self.dest, ALL_ROOT / MANIFEST)
        self.assertEqual(aggregate["dependencies"], ["ycc", "ycc-mcp", "ycc-hooks"])
        self.assertNotIn("dependencies", self.json_at(self.dest, MCP_ROOT / MANIFEST))
        self.assertNotIn("dependencies", self.json_at(self.dest, HOOKS_ROOT / MANIFEST))
        self.assertEqual(set(self.snapshot(self.dest / ALL_ROOT)), {MANIFEST})

    def test_dependencies_follow_requires_and_version_follows_model_source(self) -> None:
        version_source = self.tmp / "version.json"
        version_source.write_text(json.dumps({"version": "9.9.9", "author": {"name": "x"}}), encoding="utf-8")
        model = replace(load_package_model(), version_source=str(version_source))
        model = with_claude_runtime(model, "ycc-all", requires=("ycc-mcp",))
        with patch.object(generator, "load_package_model", return_value=model):
            generator.write_all(self.dest)
        for root in (MCP_ROOT, HOOKS_ROOT, ALL_ROOT):
            self.assertEqual(self.json_at(self.dest, root / MANIFEST)["version"], "9.9.9")
        self.assertEqual(self.json_at(self.dest, ALL_ROOT / MANIFEST)["dependencies"], ["ycc-mcp"])

    def test_missing_version_fails_before_any_write(self) -> None:
        version_source = self.tmp / "version.json"
        version_source.write_text('{"name": "ycc"}\n', encoding="utf-8")
        model = replace(load_package_model(), version_source=str(version_source))
        with patch.object(generator, "load_package_model", return_value=model):
            self.assert_all_modes_raise(self.dest, "missing nonempty version")
        self.assertFalse(self.dest.exists())

    def test_registered_hook_is_rewritten_and_script_copied_executable(self) -> None:
        generator.write_all(self.dest)
        registrations = self.json_at(self.dest, HOOKS_ROOT / HOOK_REGISTRATIONS)
        self.assertEqual(
            registrations,
            {"hooks": {"WorktreeCreate": [{"hooks": [{"type": "command", "command": PLUGIN_HOOK_COMMAND}]}]}},
        )
        self.assertNotIn(generator.INSTALLER_HOOK_COMMAND, (self.dest / HOOKS_ROOT / HOOK_REGISTRATIONS).read_text())
        script = self.dest / HOOKS_ROOT / HOOK_SCRIPT
        self.assertEqual(script.read_bytes(), (REPO_ROOT / generator.SOURCE_HOOK_PATH).read_bytes())
        self.assertTrue(script.stat().st_mode & 0o100)
        self.assertFalse((self.dest / HOOKS_ROOT / MANIFEST).stat().st_mode & 0o100)
        self.assertEqual(set(self.snapshot(self.dest / HOOKS_ROOT)), {MANIFEST, HOOK_REGISTRATIONS, HOOK_SCRIPT})
        self.assertFalse((self.dest / HOOKS_ROOT / UNREGISTERED_HOOK).exists())

    def test_hook_copy_mode_follows_source_and_registration_options_survive(self) -> None:
        script = self.tmp / "worktree-create.sh"
        script.write_bytes((REPO_ROOT / generator.SOURCE_HOOK_PATH).read_bytes())
        script.chmod(0o644)
        self.patch_generator("SOURCE_HOOK_PATH", script)
        installer = {"type": "command", "command": generator.INSTALLER_HOOK_COMMAND, "timeout": 300}
        self.patch_settings({"WorktreeCreate": [{"matcher": "*", "hooks": [installer]}]})
        generator.write_all(self.dest)
        expected = {
            "hooks": {
                "WorktreeCreate": [
                    {
                        "matcher": "*",
                        "hooks": [{"type": "command", "command": PLUGIN_HOOK_COMMAND, "timeout": 300}],
                    }
                ]
            }
        }
        self.assertEqual((self.dest / HOOKS_ROOT / HOOK_REGISTRATIONS).read_bytes(), serialized(expected))
        copied = self.dest / HOOKS_ROOT / HOOK_SCRIPT
        self.assertEqual(copied.read_bytes(), script.read_bytes())
        self.assertFalse(copied.stat().st_mode & 0o100)

    def test_unsupported_hook_registrations_fail_before_writes(self) -> None:
        installer = {"type": "command", "command": generator.INSTALLER_HOOK_COMMAND}
        cases = {
            "event": {"SessionStart": [{"hooks": [installer]}]},
            "command": {"WorktreeCreate": [{"hooks": [{"type": "command", "command": "bash no/such.sh"}]}]},
            "type": {"WorktreeCreate": [{"hooks": [{**installer, "type": "script"}]}]},
            "shape": {"WorktreeCreate": [{"matcher": "*"}]},
            "not-array": {"WorktreeCreate": {"hooks": [installer]}},
        }
        for label, hooks in cases.items():
            with self.subTest(label=label):
                self.patch_settings(hooks)
                self.assert_all_modes_raise(self.dest, "unsupported|must contain|must be an array")
                self.assertFalse(self.dest.exists())

    def test_unsupported_components_fail_before_writes(self) -> None:
        model = load_package_model()
        cases = {
            "combined components": with_claude_runtime(model, "ycc-mcp", components=("mcp", "hooks")),
            "skills in add-on": with_claude_runtime(model, "ycc-hooks", components=("skills",)),
            "aggregate without dependencies": with_claude_runtime(model, "ycc-all", requires=()),
        }
        for label, broken in cases.items():
            with self.subTest(label=label), patch.object(generator, "load_package_model", return_value=broken):
                self.assert_all_modes_raise(self.dest, "unsupported included native Claude components")
                self.assertFalse(self.dest.exists())

    def test_catalog_visibility_does_not_gate_and_deferred_is_not_emitted(self) -> None:
        model = load_package_model()
        listed = with_claude_runtime(with_claude_runtime(model, "ycc-mcp", listed=True), "ycc-hooks", listed=False)
        deferred = with_claude_runtime(listed, "ycc-hooks", status="deferred")
        with patch.object(generator, "load_package_model", return_value=listed):
            inventory = generator.write_all(self.dest)
        self.assertIn(HOOKS_ROOT / MANIFEST, inventory)
        self.assertIn(MCP_ROOT / MANIFEST, inventory)
        with patch.object(generator, "load_package_model", return_value=deferred):
            generator.write_all(self.dest)
        self.assertFalse((self.dest / HOOKS_ROOT).exists())
        self.assertTrue((self.dest / MCP_ROOT / MANIFEST).is_file())

    def test_prune_removes_owned_extras_and_preserves_neighbors(self) -> None:
        inventory = generator.write_all(self.dest)
        extras = (
            MCP_ROOT / "extra.json",
            MCP_ROOT / "nested/orphan.txt",
            HOOKS_ROOT / UNREGISTERED_HOOK,
            ALL_ROOT / "stale.txt",
        )
        neighbors = (
            Path("keep.txt"),
            Path("packages/other/keep.txt"),
            Path("ycc/.claude-plugin/plugin.json"),
            CANONICAL_ROOT / MANIFEST,
            Path("packages/claude/foreign/keep.txt"),
            Path("packages/claude/installer-fallback/keep.txt"),
        )
        for rel in extras + neighbors:
            path = self.dest / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"keep or prune\n")
        (self.dest / MCP_ROOT / "empty-dir").mkdir()
        generator.write_all(self.dest)
        for rel in extras:
            self.assertFalse((self.dest / rel).exists())
        self.assertFalse((self.dest / MCP_ROOT / "nested").exists())
        self.assertFalse((self.dest / MCP_ROOT / "empty-dir").exists())
        for rel in neighbors:
            self.assertEqual((self.dest / rel).read_bytes(), b"keep or prune\n")
        self.assertEqual(set(self.snapshot(self.dest)), inventory | set(neighbors))

    def test_stale_deferred_root_is_removed_including_empty_root(self) -> None:
        generator.write_all(self.dest)
        neighbor = self.dest / "packages/claude/foreign/keep.txt"
        neighbor.parent.mkdir(parents=True)
        neighbor.write_bytes(b"neighbor\n")
        stale_root = self.dest / AGENTS_ROOT
        for populated in (False, True):
            with self.subTest(populated=populated):
                stale_root.mkdir()
                if populated:
                    (stale_root / "stale.json").write_bytes(b"stale deferred\n")
                before = self.snapshot(self.dest)
                with contextlib.redirect_stderr(io.StringIO()) as errors:
                    self.assertEqual(generator.run_check(self.dest), 1)
                self.assertIn(f"extra in output: {AGENTS_ROOT}", errors.getvalue())
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    generator.write_all(self.dest, dry_run=True)
                self.assertIn(f"Would remove {AGENTS_ROOT}", output.getvalue())
                self.assertTrue(stale_root.exists())
                self.assertEqual(self.snapshot(self.dest), before)
                generator.write_all(self.dest)
                self.assertFalse(stale_root.exists())
                self.assertEqual(neighbor.read_bytes(), b"neighbor\n")

    def test_managed_symlinks_are_rejected_without_mutation(self) -> None:
        target = self.tmp / "outside"
        target.mkdir()
        (target / "keep").write_bytes(b"untouched\n")
        managed = (
            Path("packages"),
            Path("packages/claude"),
            MCP_ROOT,
            MCP_ROOT / "nested-link",
            MCP_ROOT / MCP_CONFIG,
            HOOKS_ROOT / HOOK_SCRIPT,
            AGENTS_ROOT,
        )
        for index, rel in enumerate(managed):
            with self.subTest(rel=rel):
                dest = self.tmp / f"symlink-case-{index}"
                link = dest / rel
                link.parent.mkdir(parents=True)
                link.symlink_to(target, target_is_directory=True)
                before = self.snapshot(dest)
                self.assert_all_modes_raise(dest, "symlink")
                self.assertEqual(self.snapshot(dest), before)
                self.assertTrue(link.is_symlink())
                self.assertEqual(self.snapshot(target), {Path("keep"): b"untouched\n"})

    def test_regular_file_at_any_owned_root_is_rejected_without_mutation(self) -> None:
        neighbor = Path("packages/claude/foreign/keep.txt")
        for index, rel in enumerate((MCP_ROOT, HOOKS_ROOT, ALL_ROOT, AGENTS_ROOT)):
            with self.subTest(root=rel):
                dest = self.tmp / f"file-root-case-{index}"
                (dest / neighbor).parent.mkdir(parents=True)
                (dest / neighbor).write_bytes(b"neighbor\n")
                (dest / rel).write_bytes(b"not a directory\n")
                before = self.snapshot(dest)
                actions: dict[str, Callable[[], object]] = {
                    "write": partial(generator.write_all, dest),
                    "dry-run": partial(generator.write_all, dest, dry_run=True),
                    "check": partial(generator.run_check, dest),
                }
                for mode, action in actions.items():
                    with self.subTest(mode=mode):
                        with self.assertRaisesRegex(ValueError, "not a directory"):
                            action()
                        self.assertEqual(self.snapshot(dest), before)
                        self.assertTrue((dest / rel).is_file())

    def test_check_reports_missing_changed_extra_and_executable_drift_without_mutation(self) -> None:
        generator.write_all(self.dest)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(generator.run_check(self.dest), 0)
        (self.dest / MCP_ROOT / MANIFEST).write_text("drift\n", encoding="utf-8")
        (self.dest / MCP_ROOT / MCP_CONFIG).unlink()
        (self.dest / HOOKS_ROOT / UNREGISTERED_HOOK).write_bytes(b"stale\n")
        script = self.dest / HOOKS_ROOT / HOOK_SCRIPT
        script.chmod(script.stat().st_mode & ~0o100)
        changed_mode = script.stat().st_mode
        before = self.snapshot(self.dest)
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(generator.run_check(self.dest), 1)
        details = errors.getvalue()
        self.assertIn(f"missing file: {MCP_ROOT / MCP_CONFIG}", details)
        self.assertIn(f"drift: {MCP_ROOT / MANIFEST}", details)
        self.assertIn(f"executable-bit drift: {HOOKS_ROOT / HOOK_SCRIPT}", details)
        self.assertIn(f"extra in output: {HOOKS_ROOT / UNREGISTERED_HOOK}", details)
        self.assertIn("generate-claude-packages.sh", details)
        self.assertEqual(self.snapshot(self.dest), before)
        self.assertEqual(script.stat().st_mode, changed_mode)
        self.assertFalse((self.dest / MCP_ROOT / MCP_CONFIG).exists())
        generator.write_all(self.dest)
        self.assertTrue(script.stat().st_mode & 0o100)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(generator.run_check(self.dest), 0)

    def test_check_on_missing_destination_does_not_create_it(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(generator.run_check(self.dest), 1)
        self.assertIn("missing file", errors.getvalue())
        self.assertFalse(self.dest.exists())

    def test_dry_run_mutates_nothing_and_cli_modes_are_exclusive(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()) as output:
            inventory = generator.write_all(self.dest, dry_run=True)
        self.assertIn(f"Would write {MCP_ROOT / MANIFEST}", output.getvalue())
        self.assertEqual(len(inventory), 6)
        self.assertFalse(self.dest.exists())
        generator.write_all(self.dest)
        (self.dest / MCP_ROOT / "stale.json").write_bytes(b"stale\n")
        (self.dest / HOOKS_ROOT / MANIFEST).write_text("drift\n", encoding="utf-8")
        before = self.snapshot(self.dest)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            generator.write_all(self.dest, dry_run=True)
        self.assertIn(f"Would remove {MCP_ROOT / 'stale.json'}", output.getvalue())
        self.assertEqual(self.snapshot(self.dest), before)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--dry-run", "--check"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
