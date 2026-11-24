#!/usr/bin/env python3
"""Fixture tests for package-model parity with native trees and catalogs."""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_codex_plugin as codex  # noqa: E402
import generate_cursor_packages as cursor  # noqa: E402
import validate_packages as validator  # noqa: E402
from package_model import (  # noqa: E402
    REPO_ROOT,
    Package,
    PackageModel,
    RuntimePackage,
    load_package_model,
)

CURSOR_GATE = ".cursor-plugin/marketplace.json must not exist when no Cursor packages are listed"


def runtime(
    runtime_name: str,
    *,
    components: tuple[str, ...] = (),
    status: str = "included",
    listed: bool = False,
    mechanism: str = "native",
    requires: tuple[str, ...] = (),
) -> RuntimePackage:
    return RuntimePackage(
        runtime=runtime_name,
        status=status,
        listed=listed,
        mechanism=mechanism,
        components=components,
        requires=requires,
        target_release="v6.0.0",
        experimental=False,
        opt_in=False,
        evidence=(),
        gates=(),
        notes="",
    )


def package(key: str, *runtimes: RuntimePackage) -> Package:
    return Package(key, "fixture package", "lockstep", tuple(runtimes))


def repo_model() -> PackageModel:
    """A miniature of the real package model covering every row shape the validator reads."""
    return PackageModel(
        1,
        "ycc/.claude-plugin/plugin.json",
        (
            package(
                "ycc",
                runtime("claude", components=("skills", "agents", "shared"), listed=True),
                runtime("codex", components=("skills", "shared")),
                runtime("cursor", components=("skills", "agents", "commands", "shared")),
                runtime("antigravity", components=("skills", "agents", "shared")),
            ),
            package(
                "ycc-mcp",
                runtime("claude", components=("mcp",)),
                runtime("codex", components=("mcp",)),
                runtime("cursor", components=("mcp",)),
                runtime("antigravity", components=("mcp",)),
            ),
            package(
                "ycc-hooks",
                runtime("claude", components=("hooks",)),
                runtime("codex", components=("hooks",), status="excluded"),
                runtime("cursor", components=("hooks",)),
            ),
            package("ycc-all", runtime("claude", requires=("ycc", "ycc-mcp", "ycc-hooks"))),
            package(
                "ycc-rules", runtime("cursor", components=("rules",)), runtime("antigravity", components=("rules",))
            ),
            package("installer-fallback", runtime("cursor", mechanism="file-copy")),
        ),
    )


def with_listed(model: PackageModel, key: str, runtimes: set[str]) -> PackageModel:
    packages = tuple(
        (
            replace(
                entry_package,
                runtimes=tuple(
                    replace(row, listed=True) if row.runtime in runtimes else row for row in entry_package.runtimes
                ),
            )
            if entry_package.key == key
            else entry_package
        )
        for entry_package in model.packages
    )
    return PackageModel(model.schema_version, model.version_source, packages)


class ValidatePackagesTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "repo"
        self.model = repo_model()
        self.materialize()

    # --- fixture builders ----------------------------------------------------

    def write_json(self, relative: Path, payload: object) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return path

    def materialize(self) -> None:
        """Build the repo-shaped tree the model describes, catalogs included."""
        listed: list[dict[str, str]] = []
        for entry_package in self.model.packages:
            for row in entry_package.runtimes:
                if row.runtime not in validator.ROOTS or row.mechanism != "native" or row.status != "included":
                    continue
                root = validator.package_root(entry_package.key, row.runtime)
                self.write_json(root / validator.MANIFESTS[row.runtime], {"name": entry_package.key})
                for component in row.components:
                    target = self.root / root / validator.component_path(component, row.runtime)
                    if component == "mcp":
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_text('{"mcpServers": {}}\n', encoding="utf-8")
                    else:
                        target.mkdir(parents=True, exist_ok=True)
                if row.runtime == "claude" and row.listed:
                    listed.append({"name": entry_package.key, "source": f"./{root}"})
        self.write_json(validator.CLAUDE_CATALOG, {"name": "ycc", "plugins": listed})
        self.write_json(codex.NATIVE_MARKETPLACE, codex.build_repository_marketplace(self.model.packages))

    def errors(self, model: PackageModel | None = None) -> list[str]:
        return validator.validate(self.root, model if model is not None else self.model)

    def rewrite(self, relative: Path, change) -> None:
        path = self.root / relative
        payload = json.loads(path.read_text(encoding="utf-8"))
        change(payload)
        path.write_text(json.dumps(payload), encoding="utf-8")

    def assert_has_error(self, errors: list[str], expected: str) -> None:
        self.assertTrue(any(expected in error for error in errors), f"expected {expected!r} in {errors!r}")

    # --- parity ---------------------------------------------------------------

    def test_repo_shaped_fixture_passes(self) -> None:
        # installer-fallback is file-copy: its tree exists without a native manifest.
        (self.root / "packages/cursor/installer-fallback/config").mkdir(parents=True)
        self.assertEqual(self.errors(), [])

    def test_existing_repo_matches_its_model(self) -> None:
        self.assertEqual(validator.validate(REPO_ROOT, load_package_model()), [])

    def test_package_roots_follow_each_runtime(self) -> None:
        self.assertEqual(validator.package_root("ycc", "claude"), Path("ycc"))
        self.assertEqual(validator.package_root("ycc-mcp", "claude"), Path("packages/claude/ycc-mcp"))
        self.assertEqual(validator.package_root("ycc", "codex"), Path(".codex-plugin/ycc"))
        self.assertEqual(validator.package_root("ycc", "cursor"), Path("packages/cursor/ycc"))

    def test_component_paths_follow_each_runtime_layout(self) -> None:
        self.assertEqual(validator.component_path("mcp", "cursor"), "mcp.json")
        self.assertEqual(validator.component_path("mcp", "claude"), ".mcp.json")
        self.assertEqual(validator.component_path("shared", "claude"), "skills/_shared")
        self.assertEqual(validator.component_path("shared", "codex"), "shared")
        self.assertEqual(validator.component_path("rules", "cursor"), "rules")

    # --- negatives: manifests and components -----------------------------------

    def test_missing_native_manifest(self) -> None:
        (self.root / "packages/claude/ycc-mcp/.claude-plugin/plugin.json").unlink()
        self.assert_has_error(
            self.errors(),
            "packages/claude/ycc-mcp/.claude-plugin/plugin.json: missing included native manifest",
        )

    def test_missing_native_root_for_every_runtime(self) -> None:
        shutil.rmtree(self.root / "packages/cursor/ycc-rules")
        shutil.rmtree(self.root / ".codex-plugin/ycc")
        errors = self.errors()
        self.assert_has_error(errors, "packages/cursor/ycc-rules/.cursor-plugin/plugin.json: missing")
        self.assert_has_error(errors, ".codex-plugin/ycc/.codex-plugin/plugin.json: missing")

    def test_antigravity_manifest_at_plugin_root(self) -> None:
        (self.root / "packages/antigravity/ycc-mcp/plugin.json").unlink()
        self.assert_has_error(self.errors(), "packages/antigravity/ycc-mcp/plugin.json: missing")
        self.assertEqual(validator.component_path("mcp", "antigravity"), "mcp_config.json")
        self.assertEqual(validator.component_path("shared", "antigravity"), "ycc-shared")

    def test_missing_component_tree(self) -> None:
        shutil.rmtree(self.root / "packages/cursor/ycc/skills")
        self.assert_has_error(self.errors(), "packages/cursor/ycc: missing modeled skills component")

    def test_unmodeled_component_tree_for_every_runtime(self) -> None:
        for runtime_name in validator.ROOTS:
            with self.subTest(runtime=runtime_name):
                relative = validator.package_root("ycc-mcp", runtime_name) / "agents"
                (self.root / relative).mkdir()
                self.assert_has_error(self.errors(), f"{relative.parent}: unmodeled agents component present")

    def test_unmodeled_mcp_component_is_rejected(self) -> None:
        # Drop the modeled mcp component from ycc-mcp: its on-disk file is now extra.
        for runtime_name in validator.ROOTS:
            with self.subTest(runtime=runtime_name):
                packages = tuple(
                    (
                        replace(
                            item,
                            runtimes=tuple(
                                replace(row, components=()) if row.runtime == runtime_name else row
                                for row in item.runtimes
                            ),
                        )
                        if item.key == "ycc-mcp"
                        else item
                    )
                    for item in self.model.packages
                )
                relative = validator.package_root("ycc-mcp", runtime_name)
                self.assert_has_error(
                    self.errors(replace(self.model, packages=packages)),
                    f"{relative}: unmodeled mcp component present",
                )

    def test_canonical_source_and_legacy_codex_component_exceptions(self) -> None:
        (self.root / "ycc/rules").mkdir()
        (self.root / "ycc/settings").mkdir()
        self.write_json(Path(".codex-plugin/ycc/.mcp.json"), {"mcpServers": {}})
        self.assertEqual(self.errors(), [])

        listed_model = with_listed(with_listed(self.model, "ycc", {"codex"}), "ycc-mcp", {"codex"})
        self.write_json(codex.NATIVE_MARKETPLACE, codex.build_repository_marketplace(listed_model.packages))
        self.assert_has_error(self.errors(listed_model), ".codex-plugin/ycc: unmodeled mcp component present")

    def test_component_exceptions_do_not_apply_to_addons(self) -> None:
        (self.root / "packages/claude/ycc-mcp/rules").mkdir()
        (self.root / "packages/claude/ycc-mcp/settings").mkdir()
        errors = self.errors()
        self.assert_has_error(errors, "packages/claude/ycc-mcp: unmodeled rules component present")
        self.assert_has_error(errors, "packages/claude/ycc-mcp: unmodeled settings component present")

    def test_components_of_the_wrong_type_are_rejected(self) -> None:
        mcp = self.root / "packages/cursor/ycc-mcp/mcp.json"
        mcp.unlink()
        mcp.mkdir()
        self.assert_has_error(self.errors(), "packages/cursor/ycc-mcp: missing modeled mcp component")

        agents = self.root / "ycc/agents"
        shutil.rmtree(agents)
        agents.write_text("not a directory\n", encoding="utf-8")
        self.assert_has_error(self.errors(), "ycc: missing modeled agents component")

    def test_unexpected_manifest_for_excluded_package(self) -> None:
        self.write_json(Path(".codex-plugin/ycc-hooks/.codex-plugin/plugin.json"), {"name": "ycc-hooks"})
        self.assert_has_error(self.errors(), ".codex-plugin/ycc-hooks/.codex-plugin/plugin.json: unexpected")

    def test_unexpected_manifest_for_non_native_mechanism(self) -> None:
        self.write_json(
            Path("packages/cursor/installer-fallback/.cursor-plugin/plugin.json"),
            {"name": "installer-fallback"},
        )
        self.assert_has_error(self.errors(), "installer-fallback/.cursor-plugin/plugin.json: unexpected")

    def test_manifest_name_must_match_the_package_key(self) -> None:
        self.rewrite(
            Path("packages/claude/ycc-hooks/.claude-plugin/plugin.json"),
            lambda payload: payload.update(name="wrong-name"),
        )
        self.assert_has_error(
            self.errors(),
            "packages/claude/ycc-hooks: manifest name must match package key 'ycc-hooks'",
        )

    def test_malformed_manifest_is_a_diagnostic(self) -> None:
        (self.root / "packages/cursor/ycc-rules/.cursor-plugin/plugin.json").write_text("{", encoding="utf-8")
        self.assert_has_error(self.errors(), "unreadable or malformed JSON")

    # --- negatives: catalogs -----------------------------------------------------

    def test_claude_listing_must_name_exactly_the_listed_packages(self) -> None:
        self.rewrite(
            validator.CLAUDE_CATALOG,
            lambda payload: payload["plugins"].append({"name": "ycc-mcp", "source": "./packages/claude/ycc-mcp"}),
        )
        self.assert_has_error(self.errors(), "expected exactly listed Claude packages ['ycc']")

    def test_claude_listing_source_must_point_at_the_modeled_root(self) -> None:
        self.rewrite(
            validator.CLAUDE_CATALOG,
            lambda payload: payload["plugins"][0].update(source="./packages/claude/ycc"),
        )
        self.assert_has_error(self.errors(), "ycc: source must point at its modeled package root")

    def test_claude_listing_entry_shape_and_json_are_diagnostics(self) -> None:
        self.rewrite(validator.CLAUDE_CATALOG, lambda payload: payload.update(plugins=["ycc"]))
        self.assert_has_error(self.errors(), "expected a plugins array of objects")

        (self.root / validator.CLAUDE_CATALOG).write_text("{", encoding="utf-8")
        self.assert_has_error(self.errors(), "unreadable or malformed JSON")

        (self.root / validator.CLAUDE_CATALOG).unlink()
        self.assert_has_error(self.errors(), "unreadable or malformed JSON")

    def test_cursor_marketplace_absence_gate(self) -> None:
        self.write_json(validator.CURSOR_CATALOG, {"name": "ycc"})
        self.assertIn(CURSOR_GATE, self.errors())

    def test_listed_cursor_and_codex_catalogs_are_validated(self) -> None:
        listed = with_listed(
            with_listed(with_listed(self.model, "ycc", {"cursor", "codex"}), "ycc-mcp", {"cursor"}),
            "ycc-mcp",
            {"codex"},
        )
        errors = self.errors(listed)
        self.assert_has_error(errors, "marketplace.json: unreadable or malformed JSON")
        self.assert_has_error(errors, "catalog must match the Codex package listing state")

        self.write_json(codex.NATIVE_MARKETPLACE, codex.build_repository_marketplace(listed.packages))
        self.write_json(validator.CURSOR_CATALOG, cursor.build_marketplace(listed.packages))
        self.assertEqual(self.errors(listed), [])

        self.rewrite(
            validator.CURSOR_CATALOG,
            lambda payload: payload["plugins"].append(dict(payload["plugins"][0], name="duplicate")),
        )
        self.assert_has_error(self.errors(listed), "catalog must match exactly the listed Cursor packages")

    def test_partial_codex_listing_is_rejected(self) -> None:
        for key in ("ycc", "ycc-mcp"):
            with self.subTest(listed=key):
                partial = with_listed(self.model, key, {"codex"})
                # Partial listing keeps the legacy catalog, so only the listing error appears.
                self.assertEqual(
                    self.errors(partial),
                    [codex.partial_codex_listing_error(partial.packages)],
                )
                self.assert_has_error(self.errors(partial), "partial Codex listing is not allowed")

    def test_cursor_catalog_symlinks_are_rejected_before_parity(self) -> None:
        listed = with_listed(self.model, "ycc", {"cursor"})
        self.write_json(Path("outside.json"), cursor.build_marketplace(listed.packages))
        link = self.root / validator.CURSOR_CATALOG
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(self.root / "outside.json")
        self.assert_has_error(self.errors(listed), "managed-path symlink is not allowed")
        self.assert_has_error(self.errors(), "managed-path symlink is not allowed")
        link.unlink()
        link.parent.rmdir()
        (self.root / "elsewhere").mkdir()
        link.parent.symlink_to(self.root / "elsewhere", target_is_directory=True)
        self.assert_has_error(self.errors(), "managed-path symlink is not allowed")

    def test_codex_catalog_drift(self) -> None:
        self.rewrite(codex.NATIVE_MARKETPLACE, lambda payload: payload["plugins"][0].update(name="renamed"))
        self.assert_has_error(self.errors(), "catalog must match the Codex package listing state")

    def test_missing_codex_catalog_is_a_diagnostic(self) -> None:
        (self.root / codex.NATIVE_MARKETPLACE).unlink()
        self.assert_has_error(self.errors(), "unreadable or malformed JSON")

    # --- main --------------------------------------------------------------------

    def test_main_returns_exit_codes_for_a_fixture_root(self) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(validator.main(self.root, self.model), 0)
        self.assertEqual(stderr.getvalue(), "")

        (self.root / "packages/claude/ycc-mcp/.claude-plugin/plugin.json").unlink()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(validator.main(self.root, self.model), 1)
        self.assertIn("validate_packages:", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
