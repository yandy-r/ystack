#!/usr/bin/env python3
"""Checked-in package-model tests plus negative, CLI, and import-path coverage."""

from __future__ import annotations

import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
sys.path.insert(0, str(SCRIPTS_DIR))

from package_model import (  # noqa: E402
    DEFAULT_MANIFEST_PATH,
    DEFAULT_SCHEMA_PATH,
    PackageModelError,
    load_package_model,
    load_package_schema,
    validate_package_model,
)

MANIFEST = json.loads(DEFAULT_MANIFEST_PATH.read_text(encoding="utf-8"))
SCHEMA = json.loads(DEFAULT_SCHEMA_PATH.read_text(encoding="utf-8"))
RUNTIME = ("claude", "codex", "cursor", "opencode", "agents", "omp", "pi")


def clone() -> dict:
    return copy.deepcopy(MANIFEST)


class CheckedInModelTests(unittest.TestCase):
    def test_manifest_and_schema_load_cleanly(self) -> None:
        load_package_schema()
        model = load_package_model()
        self.assertEqual(model.schema_version, 1)
        self.assertEqual(model.version_source, "ycc/.claude-plugin/plugin.json")
        self.assertEqual(validate_package_model(MANIFEST, repo_root=REPO_ROOT, schema=SCHEMA), [])

    def test_all_runtimes_covered(self) -> None:
        covered = {r.runtime for p in load_package_model().packages for r in p.runtimes}
        self.assertEqual(covered, set(RUNTIME))

    def test_listed_rows_are_included_native_packages(self) -> None:
        for package in load_package_model().packages:
            for entry in package.runtimes:
                if entry.listed:
                    self.assertEqual((entry.status, entry.mechanism), ("included", "native"))

    def test_codex_and_cursor_listing_is_a_data_change(self) -> None:
        data = clone()
        for package in data["packages"].values():
            for name, entry in package["runtimes"].items():
                if name in {"codex", "cursor"} and entry["status"] == "included" and entry["mechanism"] == "native":
                    entry["listed"] = True
        self.assertEqual(validate_package_model(data, repo_root=REPO_ROOT, schema=SCHEMA), [])

    def test_codex_ycc_hooks_excluded(self) -> None:
        entry = load_package_model().lookup("ycc-hooks", "codex")
        assert entry is not None
        self.assertEqual(entry.status, "excluded")
        self.assertFalse(entry.listed)

    def test_omp_ycc_hooks_excluded(self) -> None:
        entry = load_package_model().lookup("ycc-hooks", "omp")
        assert entry is not None
        self.assertEqual(entry.status, "excluded")
        self.assertFalse(entry.listed)
        self.assertEqual(entry.gates, ())

    def test_omp_native_rows_listed(self) -> None:
        model = load_package_model()
        for key, components in (
            ("ycc", ("skills", "agents", "commands", "shared")),
            ("ycc-mcp", ("mcp",)),
            ("ycc-rules", ("rules",)),
        ):
            entry = model.lookup(key, "omp")
            assert entry is not None
            self.assertEqual((entry.status, entry.listed, entry.mechanism), ("included", True, "native"), key)
            self.assertEqual(tuple(entry.components), components, key)
            self.assertEqual(entry.gates, (), key)
        fallback = model.lookup("installer-fallback", "omp")
        assert fallback is not None
        self.assertEqual((fallback.status, fallback.listed), ("included", False))
        self.assertEqual(tuple(fallback.components), ("instructions", "settings"))
        self.assertEqual(fallback.gates, ())

    def test_pi_rows_modeled_but_not_shipping(self) -> None:
        # ADR 0003 package matrix: adapters deferred, ycc-hooks and ycc-all excluded, no ycc-agents.
        model = load_package_model()
        releases: set[str] = set()
        expected = {
            "ycc": "deferred",
            "ycc-mcp": "deferred",
            "ycc-rules": "deferred",
            "installer-fallback": "deferred",
            "ycc-hooks": "excluded",
            "ycc-all": "excluded",
        }
        for package in model.packages:
            entry = model.lookup(package.key, "pi")
            with self.subTest(package=package.key):
                if package.key not in expected:
                    self.assertIsNone(entry)
                    continue
                assert entry is not None
                self.assertEqual(entry.status, expected[package.key])
                self.assertFalse(entry.listed)
                releases.add(entry.target_release)
        # One shared later release for every pi row; the literal lives in packages.json only.
        self.assertEqual(len(releases), 1, releases)
        self.assertNotIn("v6.0.0", releases)

    def test_claude_ycc_agents_deferred_to_v7(self) -> None:
        entry = load_package_model().lookup("ycc-agents", "claude")
        assert entry is not None
        self.assertEqual(entry.status, "deferred")
        self.assertEqual(entry.target_release, "v7.0.0")
        self.assertFalse(entry.listed)

    def test_no_claude_ycc_rules(self) -> None:
        self.assertIsNone(load_package_model().lookup("ycc-rules", "claude"))

    def test_ycc_all_requires_workflow(self) -> None:
        entry = load_package_model().lookup("ycc-all", "claude")
        assert entry is not None
        self.assertEqual(tuple(sorted(entry.requires)), ("ycc", "ycc-hooks", "ycc-mcp"))

    def test_opencode_npm_is_the_primary_route(self) -> None:
        entry = load_package_model().lookup("@yandy-r/ycc-opencode", "opencode")
        assert entry is not None
        self.assertEqual(entry.mechanism, "npm")
        self.assertFalse(entry.experimental)
        self.assertFalse(entry.opt_in)

    def test_installer_fallback_file_copy_unlisted(self) -> None:
        package = next(p for p in load_package_model().packages if p.key == "installer-fallback")
        self.assertEqual(len(package.runtimes), 7)
        for entry in package.runtimes:
            self.assertEqual(entry.mechanism, "file-copy")
            self.assertFalse(entry.listed)
            self.assertFalse(entry.experimental or entry.opt_in)


class NegativeTests(unittest.TestCase):
    def expect(self, data: dict, fragment: str) -> None:
        errors = validate_package_model(data, repo_root=REPO_ROOT, schema=SCHEMA)
        self.assertTrue(errors, "expected errors but got none")
        self.assertTrue(any(fragment in e for e in errors), f"{fragment!r} not in {errors}")

    def test_duplicate_json_keys(self) -> None:
        with self.assertRaises(PackageModelError):
            load_package_model(
                self.write('{"$schema": 1, "$schema": 2}'),
            )

    def test_bool_as_int_schema_version(self) -> None:
        data = clone()
        data["schema_version"] = True
        self.expect(data, "expected integer")

    def test_unknown_root_and_package_keys(self) -> None:
        data = clone()
        data["packages"]["bogus"] = clone()["packages"]["ycc"]
        data["packages"]["ycc"]["runtimes"]["claude"]["nope"] = 1
        self.expect(data, "bogus")

    def test_bad_status_enum(self) -> None:
        data = clone()
        data["packages"]["ycc"]["runtimes"]["claude"]["status"] = "shipping"
        self.expect(data, "status")

    def test_unknown_and_stale_runtime_keys_rejected(self) -> None:
        for name in ("omp2", "pie"):
            with self.subTest(runtime=name):
                data = clone()
                runtimes = data["packages"]["ycc"]["runtimes"]
                runtimes[name] = runtimes.pop("omp")
                errors = validate_package_model(data, repo_root=REPO_ROOT, schema=SCHEMA)
                self.assertTrue(any(name in e for e in errors), errors)
                self.assertNotEqual(validate_package_model(data), [])

    def test_independent_version_policy_rejected(self) -> None:
        data = clone()
        data["packages"]["ycc"]["version_policy"] = "independent"
        self.expect(data, "version_policy: expected one of ['lockstep']")

    def test_listed_on_excluded(self) -> None:
        data = clone()
        data["packages"]["ycc-hooks"]["runtimes"]["codex"]["listed"] = True
        self.expect(data, "listed=true requires included native")

    def test_listed_on_deferred(self) -> None:
        data = clone()
        data["packages"]["ycc-agents"]["runtimes"]["claude"]["listed"] = True
        self.expect(data, "listed=true requires included native")

    def test_listed_on_npm(self) -> None:
        data = clone()
        data["packages"]["@yandy-r/ycc-opencode"]["runtimes"]["opencode"]["listed"] = True
        self.expect(data, "listed=true requires included native")

    def test_listed_on_file_copy(self) -> None:
        data = clone()
        data["packages"]["installer-fallback"]["runtimes"]["claude"] = dict(
            data["packages"]["installer-fallback"]["runtimes"]["claude"],
            listed=True,
        )
        self.expect(data, "file-copy")

    def test_requires_on_non_claude(self) -> None:
        data = clone()
        data["packages"]["ycc"]["runtimes"]["codex"]["requires"] = ["ycc-mcp"]
        self.expect(data, "only allowed for claude native")

    def test_requires_missing_target(self) -> None:
        data = clone()
        data["packages"]["ycc-all"]["runtimes"]["claude"]["requires"] = ["ycc-rules"]
        self.expect(data, "must exist as an included native claude")

    def test_requires_excluded_target(self) -> None:
        data = clone()
        data["packages"]["ycc-all"]["runtimes"]["claude"]["requires"] = ["ycc-agents"]
        self.expect(data, "must exist as an included native claude")

    def test_requires_self(self) -> None:
        data = clone()
        data["packages"]["ycc-all"]["runtimes"]["claude"]["requires"] = ["ycc-all"]
        self.expect(data, "self-dependency")

    def test_duplicate_components_and_requires(self) -> None:
        data = clone()
        data["packages"]["ycc-all"]["runtimes"]["claude"]["requires"] = ["ycc", "ycc"]
        self.expect(data, "duplicate")

    def test_empty_components_without_requires(self) -> None:
        data = clone()
        data["packages"]["ycc-mcp"]["runtimes"]["claude"]["components"] = []
        self.expect(data, "non-empty unless requires")

    def test_empty_notes_gates_evidence(self) -> None:
        data = clone()
        data["packages"]["ycc"]["runtimes"]["claude"]["notes"] = ""
        self.expect(data, "non-empty string")

    def test_unsafe_evidence_paths(self) -> None:
        for bad in ("/etc/hostname", "../outside.md", "a\\b.md", "a/../b.md"):
            data = clone()
            data["packages"]["ycc"]["runtimes"]["claude"]["evidence"] = [bad]
            self.expect(data, "unsafe evidence path")

    def test_missing_evidence_file(self) -> None:
        data = clone()
        data["packages"]["ycc"]["runtimes"]["claude"]["evidence"] = ["docs/no-such-file.md"]
        self.expect(data, "does not exist")

    def test_missing_required_runtime_field(self) -> None:
        data = clone()
        del data["packages"]["ycc"]["runtimes"]["claude"]["notes"]
        self.expect(data, "missing required field")

    def test_malformed_json(self) -> None:
        with self.assertRaises(PackageModelError):
            load_package_model(self.write("{not json"))

    def test_invalid_schema_detected(self) -> None:
        self.assertIn("invalid package schema", validate_package_model(MANIFEST, schema={"type": "bogus"})[0])

    def test_permissive_schema_fails_closed(self) -> None:
        data = clone()
        data["packages"]["ycc"] = "not-a-dict"
        errors = validate_package_model(data, repo_root=REPO_ROOT, schema={"type": "object"})
        self.assertTrue(errors)

    def test_permissive_schema_malformed_values_return_errors(self) -> None:
        permissive = {"type": "object"}
        cases = [
            {"packages": {"ycc": "not-a-dict"}},
            {"packages": {"ycc": {"runtimes": {"claude": "not-a-dict"}}}},
            {"packages": "nope"},
            {},
            {
                "packages": {
                    "ycc": "not-a-dict",
                    "ycc-all": {
                        "runtimes": {
                            "claude": {
                                "requires": ["ycc"],
                                "components": [],
                                "mechanism": "native",
                                "listed": False,
                                "status": "included",
                                "target_release": "v6.0.0",
                                "experimental": False,
                                "opt_in": False,
                                "evidence": [],
                                "gates": [],
                                "notes": "meta",
                            }
                        }
                    },
                }
            },
        ]
        for data in cases:
            with self.subTest(data=data):
                errors = validate_package_model(data, repo_root=REPO_ROOT, schema=permissive)
                self.assertTrue(errors)

    def test_custom_schema_dropping_required_field_still_rejects_bad_target(self) -> None:
        schema = copy.deepcopy(SCHEMA)
        schema["$defs"]["Package"] = {"type": "object"}
        data = clone()
        data["packages"]["ycc"] = "not-a-dict"
        errors = validate_package_model(data, schema=schema)
        self.assertTrue(errors)
        self.assertTrue(any("packages.ycc: expected object" in e for e in errors), errors)

    def test_deferred_must_not_target_v6(self) -> None:
        data = clone()
        data["packages"]["ycc-agents"]["runtimes"]["claude"]["target_release"] = "v6.0.0"
        self.expect(data, "must target a later release")

    def write(self, text: str) -> Path:
        path = Path(tempfile.mkdtemp()) / "packages.json"
        path.write_text(text, encoding="utf-8")
        self.addCleanup(lambda: path.unlink(missing_ok=True))
        return path


class CliAndImportTests(unittest.TestCase):
    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPTS_DIR / "package_model.py"), *args],
            capture_output=True,
            text=True,
            cwd=REPO_ROOT,
        )

    def test_cli_check_passes(self) -> None:
        result = self.run_cli("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OK:", result.stdout)

    def test_cli_check_fails_on_bad_manifest(self) -> None:
        data = clone()
        data["packages"]["ycc"]["runtimes"]["claude"]["listed"] = "yes"
        path = Path(tempfile.mkdtemp()) / "packages.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        try:
            result = self.run_cli("--manifest", str(path), "--check")
        finally:
            path.unlink(missing_ok=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("package_model:", result.stderr)

    def test_cwd_independent_import_and_load(self) -> None:
        spec = importlib.util.spec_from_file_location("package_model_direct", SCRIPTS_DIR / "package_model.py")
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        sys.modules["package_model_direct"] = module
        spec.loader.exec_module(module)  # type: ignore[union-attr]
        self.assertEqual(module.DEFAULT_MANIFEST_PATH, DEFAULT_MANIFEST_PATH)
        self.assertTrue(module.load_package_model().lookup("ycc", "claude").listed)

    def test_jsonschema_cross_check_if_available(self) -> None:
        try:
            import jsonschema  # type: ignore[import-not-found]
        except ImportError:
            self.skipTest("jsonschema not installed")
        jsonschema.validate(MANIFEST, SCHEMA)

    def test_load_from_another_cwd(self) -> None:
        origin = Path.cwd()
        try:
            os.chdir(tempfile.gettempdir())
            sys.path.insert(0, str(SCRIPTS_DIR))
            spec = importlib.util.spec_from_file_location("package_model_fresh", SCRIPTS_DIR / "package_model.py")
            assert spec and spec.loader
            module = importlib.util.module_from_spec(spec)
            sys.modules["package_model_fresh"] = module
            spec.loader.exec_module(module)  # type: ignore[union-attr]
            self.assertEqual(module.DEFAULT_MANIFEST_PATH, DEFAULT_MANIFEST_PATH)
            self.assertTrue(module.load_package_model().lookup("ycc", "claude").listed)
        finally:
            os.chdir(origin)


if __name__ == "__main__":
    unittest.main()
