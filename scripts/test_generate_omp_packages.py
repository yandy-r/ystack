#!/usr/bin/env python3
"""Tests for scripts/generate_omp_packages.py and scripts/validate_omp_native.py (YAN-1171, YAN-1173, YAN-1175)."""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import unittest
from collections.abc import Callable
from dataclasses import replace
from pathlib import Path
from typing import Any
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_omp_packages as gen  # noqa: E402
import validate_omp_native as policy  # noqa: E402
from package_model import PackageModel, load_package_model  # noqa: E402

VERSION = "9.8.7"
AUTHOR = {"name": "fixture-owner"}
YCC = gen.COMPONENT_ROOT
MCP = gen.OUTPUT_ROOT / "ycc-mcp"
RULES = gen.OUTPUT_ROOT / "ycc-rules"
# A two-file rules fixture: security ships, hooks.md is skipped by the flattener.
RULE_FIXTURES = ("common/security.md", "common/hooks.md")
SENTINEL = "SENTINEL-must-never-be-materialized"


def fake_components(root: Path) -> dict[Path, gen.Payload]:
    """A two-skill, one-agent, one-command tree with an executable helper."""
    skill = "---\nname: {0}\ndescription: d\n---\nSee skill://ycc-shared/references/x.md#part.\n"
    return {
        root / "skills/alpha/SKILL.md": gen.Payload(skill.format("alpha").encode()),
        root / "skills/alpha/scripts/run.sh": gen.Payload(b"#!/bin/sh\n", mode=0o755),
        root / "skills/_shared/SKILL.md": gen.Payload(b"---\nname: ycc-shared\ndescription: d\n---\n"),
        root / "skills/_shared/references/x.md": gen.Payload(b"# x\n"),
        root / "agents/planner.md": gen.Payload(b"---\nname: planner\ndescription: d\nmodel: '@slow'\n---\n"),
        root / "commands/alpha.md": gen.Payload(b"---\ndescription: d\n---\nRead `skill://alpha`.\n$ARGUMENTS\n"),
    }


def with_omp(model: PackageModel, key: str, **changes: Any) -> PackageModel:
    packages = tuple(
        (
            replace(
                package,
                runtimes=tuple(replace(row, **changes) if row.runtime == "omp" else row for row in package.runtimes),
            )
            if package.key == key
            else package
        )
        for package in model.packages
    )
    return replace(model, packages=packages)


def omp_rows(model: PackageModel) -> dict[str, str]:
    return {package.key: row.status for package in model.packages for row in package.runtimes if row.runtime == "omp"}


class GenerateOmpPackagesTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "repo"
        self.root.mkdir()
        # An unlisted baseline: each test lists exactly the rows it needs, whatever the shipped model says.
        self.model = with_omp(load_package_model(), "ycc", status="included")
        for key in omp_rows(self.model):
            self.model = with_omp(self.model, key, listed=False)
        self.write_source()

    def write_source(self) -> None:
        """The source inputs validate_omp_native reads (version source, skills, agents, MCP config)."""
        plugin = self.root / gen.SOURCE_PLUGIN_PATH
        plugin.parent.mkdir(parents=True)
        plugin.write_text(json.dumps({"name": "ycc", "version": VERSION, "author": AUTHOR}), encoding="utf-8")
        for rel in ("ycc/skills/alpha/SKILL.md", "ycc/skills/_shared/references/x.md", "ycc/agents/planner.md"):
            (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.root / rel).write_text("x\n", encoding="utf-8")
        self.write_mcp((gen.REPO_ROOT / gen.SOURCE_MCP_PATH).read_bytes())
        for rel in RULE_FIXTURES:
            target = self.root / gen.SOURCE_RULES_PATH / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((gen.REPO_ROOT / gen.SOURCE_RULES_PATH / rel).read_bytes())

    def write_mcp(self, content: bytes) -> None:
        source = self.root / gen.SOURCE_MCP_PATH
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(content)

    def write_mcp_servers(self, servers: dict[str, Any]) -> bytes:
        content = (json.dumps({"mcpServers": servers}, indent=2) + "\n").encode()
        self.write_mcp(content)
        return content

    def output(
        self, model: PackageModel | None = None, *, include_unlisted: bool = False
    ) -> tuple[dict[Path, gen.Payload], tuple[Path, ...]]:
        return gen.build_output(
            model or self.model,
            VERSION,
            AUTHOR,
            components=fake_components,
            repo_root=self.root,
            include_unlisted=include_unlisted,
        )

    def generate(self, model: PackageModel | None = None, *, include_unlisted: bool = False) -> set[Path]:
        output, roots = self.output(model, include_unlisted=include_unlisted)
        return gen.write_payloads(self.root, output, roots, dry_run=False)

    def read(self, rel: Path) -> Any:
        return json.loads((self.root / rel).read_text(encoding="utf-8"))

    def errors(self, model: PackageModel | None = None, *, export: bool = False) -> list[str]:
        return policy.validate(self.root, model or self.model, export=export)

    def assert_has(self, errors: list[str], expected: str) -> None:
        self.assertTrue(any(expected in error for error in errors), f"expected {expected!r} in {errors!r}")

    # --- listed gate ------------------------------------------------------------

    def test_unlisted_included_package_ships_without_a_catalog(self) -> None:
        written = self.generate()
        self.assertNotIn(gen.MARKETPLACE_PATH, written)
        self.assertFalse((self.root / gen.MARKETPLACE_PATH).exists())
        for manifest in gen.MANIFESTS:
            self.assertTrue((self.root / YCC / manifest).is_file(), manifest)
        self.assertEqual(self.errors(), [])

    def test_ycc_ships_the_scope_guard_declared_in_package_json(self) -> None:
        self.generate()
        self.assertEqual(self.read(YCC / gen.PACKAGE_JSON)["omp"], {"extensions": gen.EXTENSION_ENTRIES})
        self.assertEqual(
            (self.root / YCC / gen.SCOPE_GUARD).read_bytes(), (gen.REPO_ROOT / gen.SCOPE_GUARD_TEMPLATE).read_bytes()
        )
        scopes = self.read(YCC / gen.AGENT_SCOPES)
        self.assertEqual(scopes["mcpNamespaces"], ["ycc-mcp"])
        self.assertEqual(scopes["agents"]["git-cleanup"], {"bash": ["git", "gh", "glab"], "mcp": []})
        for manifest in (MCP, RULES):
            self.assertNotIn("omp", self.read(manifest / gen.PACKAGE_JSON))

    def test_listed_package_catalog_holds_exactly_the_listed_rows(self) -> None:
        listed = with_omp(self.model, "ycc", listed=True)
        self.generate(listed)
        catalog = self.read(gen.MARKETPLACE_PATH)
        self.assertEqual(catalog["name"], "ycc")
        self.assertEqual(catalog["owner"], AUTHOR)
        self.assertEqual(
            catalog["plugins"],
            [
                {
                    "name": "ycc",
                    "source": "./packages/omp/ycc",
                    "description": catalog["plugins"][0]["description"],
                    "version": VERSION,
                }
            ],
        )
        self.assertEqual(self.errors(listed), [])

    def test_export_catalog_includes_unlisted_included_rows(self) -> None:
        self.generate(include_unlisted=True)
        self.assertEqual(
            [entry["name"] for entry in self.read(gen.MARKETPLACE_PATH)["plugins"]], ["ycc", "ycc-mcp", "ycc-rules"]
        )
        self.assertEqual(self.errors(export=True), [])
        self.assert_has(self.errors(), "must not exist when no OMP package is listed")

    def test_unlisting_removes_a_stale_catalog_and_its_directory(self) -> None:
        self.generate(with_omp(self.model, "ycc", listed=True))
        self.assertTrue((self.root / gen.MARKETPLACE_PATH).is_file())
        self.generate()
        self.assertFalse((self.root / gen.CATALOG_DIR).exists())

    def test_validator_rejects_a_catalog_that_differs_from_the_listed_set(self) -> None:
        listed = with_omp(self.model, "ycc", listed=True)
        self.generate(listed)
        self.assert_has(self.errors(), "must not exist when no OMP package is listed")
        catalog = self.read(gen.MARKETPLACE_PATH)
        catalog["plugins"].append(dict(catalog["plugins"][0], name="ycc-extra", source="./packages/omp/ycc-extra"))
        (self.root / gen.MARKETPLACE_PATH).write_text(json.dumps(catalog), encoding="utf-8")
        self.assert_has(self.errors(listed), "plugins must be exactly the listed OMP packages ['ycc']")

    def test_validator_rejects_non_relative_or_unresolved_sources(self) -> None:
        listed = with_omp(self.model, "ycc", listed=True)
        self.generate(listed)
        catalog = self.read(gen.MARKETPLACE_PATH)
        catalog["plugins"][0]["source"] = {"source": "github", "repo": "yandy-r/ystack"}
        (self.root / gen.MARKETPLACE_PATH).write_text(json.dumps(catalog), encoding="utf-8")
        self.assert_has(self.errors(listed), "source must be the relative string './packages/omp/ycc'")

    # --- lockstep -----------------------------------------------------------------

    def test_lockstep_version_is_stamped_everywhere_omp_reads_one(self) -> None:
        listed = with_omp(self.model, "ycc", listed=True)
        self.generate(listed)
        for manifest in gen.MANIFESTS:
            payload = self.read(YCC / manifest)
            self.assertEqual((payload["name"], payload["version"]), ("ycc", VERSION), manifest)
        catalog = self.read(gen.MARKETPLACE_PATH)
        self.assertEqual(catalog["metadata"]["version"], VERSION)
        self.assertEqual(catalog["plugins"][0]["version"], VERSION)

    def test_validator_rejects_a_version_skew_in_any_manifest(self) -> None:
        self.generate()
        for manifest in gen.MANIFESTS:
            with self.subTest(manifest=str(manifest)):
                path = self.root / YCC / manifest
                original = path.read_bytes()
                path.write_text(json.dumps(dict(json.loads(original), version="0.0.1")), encoding="utf-8")
                self.assert_has(self.errors(), f"{YCC / manifest}: version must be the lockstep version {VERSION}")
                path.write_bytes(original)

    # --- fail closed ----------------------------------------------------------------

    def test_included_rows_without_an_emitter_fail_closed(self) -> None:
        with self.assertRaisesRegex(
            ValueError,
            r"packages\.ycc-hooks\.runtimes\.omp: no OMP emitter.*herdr integration install omp.*WorktreeCreate",
        ):
            self.output(with_omp(self.model, "ycc-hooks", status="included"))
        with self.assertRaises(ValueError) as caught:
            self.output(with_omp(self.model, "ycc-hooks", status="included"))
        self.assertNotIn("YAN-1174 extension", str(caught.exception))
        self.assertFalse((self.root / "packages").exists())

    # --- rules package (YAN-1175) -----------------------------------------------------

    def test_rules_package_ships_manifests_and_flat_rules(self) -> None:
        model = with_omp(self.model, "ycc-rules", status="included")
        self.generate(model)
        files = {
            path.relative_to(self.root / RULES).as_posix() for path in (self.root / RULES).rglob("*") if path.is_file()
        }
        self.assertEqual(
            files,
            {".omp-plugin/plugin.json", ".claude-plugin/plugin.json", "package.json", "rules/ycc-common-security.md"},
        )
        for manifest in gen.MANIFESTS:
            payload = self.read(RULES / manifest)
            self.assertEqual((payload["name"], payload["version"]), ("ycc-rules", VERSION), manifest)
        self.assertFalse(any("hooks" in name for name in files))
        self.assertEqual(self.errors(model), [])

    def test_mixed_rules_components_still_fail_closed(self) -> None:
        model = with_omp(self.model, "ycc-rules", status="included", components=("rules", "skills"))
        with self.assertRaisesRegex(ValueError, r"packages\.ycc-rules\.runtimes\.omp: no OMP emitter"):
            self.output(model)
        self.assertFalse((self.root / "packages").exists())

    def test_validator_rejects_rules_nesting_stray_entries_and_drift(self) -> None:
        model = with_omp(self.model, "ycc-rules", status="included")
        rule = self.root / RULES / "rules/ycc-common-security.md"
        cases: dict[str, tuple[Callable[[], object], str]] = {
            "nested": (lambda: (self.root / RULES / "rules/x").mkdir(), "no subdirectories or symlinks"),
            "extra root entry": (
                lambda: (self.root / RULES / "README.md").write_text("x\n", encoding="utf-8"),
                f"{RULES / 'README.md'}: unexpected entry",
            ),
            "drift": (
                lambda: rule.write_bytes(rule.read_bytes() + b"x\n"),
                f"{RULES / 'rules/ycc-common-security.md'}: drifted",
            ),
        }
        for label, (mutate, expected) in cases.items():
            with self.subTest(label=label):
                self.generate(model)
                self.assertEqual(self.errors(model), [])
                mutate()
                self.assert_has(self.errors(model), expected)
                for stray in (self.root / RULES / "rules/x", self.root / RULES / "README.md"):
                    if stray.is_dir():
                        stray.rmdir()
                    elif stray.exists():
                        stray.unlink()

    def test_listed_deferred_row_fails_closed(self) -> None:
        for status in ("deferred", "excluded"):
            with self.subTest(status=status):
                with self.assertRaisesRegex(ValueError, r"packages\.ycc-hooks\.runtimes\.omp: listed=true requires"):
                    self.output(with_omp(self.model, "ycc-hooks", status=status, listed=True))

    def test_deferred_and_excluded_rows_emit_nothing(self) -> None:
        output, roots = self.output()
        self.assertEqual(
            {rel.parts[2] for rel in output if rel.parts[:2] == ("packages", "omp")}, {"ycc", "ycc-mcp", "ycc-rules"}
        )
        self.assertIn(Path("packages/omp/ycc-hooks"), roots)
        self.assertNotIn(Path("packages/omp/ycc-all"), {rel.parent for rel in output})
        self.assertEqual(omp_rows(self.model)["ycc-all"], "excluded")

    def test_excluded_hooks_row_emits_nothing_and_prunes_its_root(self) -> None:
        model = with_omp(self.model, "ycc-hooks", status="excluded")
        stale = self.root / "packages/omp/ycc-hooks/package.json"
        stale.parent.mkdir(parents=True)
        stale.write_text(json.dumps({"omp": {"extensions": ["./x.ts"]}}), encoding="utf-8")
        output, roots = self.output(model)
        self.assertIn(Path("packages/omp/ycc-hooks"), roots)
        self.assertFalse(any(rel.parts[:3] == ("packages", "omp", "ycc-hooks") for rel in output))
        gen.write_payloads(self.root, output, roots, dry_run=False)
        self.assertFalse((self.root / "packages/omp/ycc-hooks").exists())

    # --- MCP package (YAN-1173) -------------------------------------------------------

    def test_mcp_package_ships_the_omp_rendering_and_lockstep_manifests(self) -> None:
        self.generate()
        source = (self.root / gen.SOURCE_MCP_PATH).read_bytes()
        self.assertEqual((self.root / MCP / gen.MCP_CONFIG).read_bytes(), gen.omp_mcp_bytes(source))
        self.assertEqual(
            {path.relative_to(self.root / MCP).as_posix() for path in (self.root / MCP).rglob("*") if path.is_file()},
            {".omp-plugin/plugin.json", ".claude-plugin/plugin.json", "package.json", ".mcp.json"},
        )
        for manifest in gen.MANIFESTS:
            payload = self.read(MCP / manifest)
            self.assertEqual((payload["name"], payload["version"]), ("ycc-mcp", VERSION), manifest)
            self.assertNotIn("mcpServers", payload, manifest)
        self.assertFalse((self.root / MCP / "plugin.json").exists())
        self.assertEqual(self.errors(), [])

    def test_mcp_placeholders_are_kept_and_env_is_never_materialized(self) -> None:
        servers = {
            "xero": {
                "command": "npx",
                "env": {"XERO_CLIENT_ID": "${XERO_CLIENT_ID}", "XERO_CLIENT_SECRET": "${XERO_CLIENT_SECRET}"},
            },
            "remote": {
                "type": "http",
                "url": "https://example.invalid/mcp",
                "headers": {"Authorization": "Bearer ${REMOTE_TOKEN}"},
            },
        }
        content = self.write_mcp_servers(servers)
        env = {"XERO_CLIENT_ID": SENTINEL, "XERO_CLIENT_SECRET": SENTINEL, "REMOTE_TOKEN": SENTINEL}
        with mock.patch.dict(os.environ, env):
            self.generate(include_unlisted=True)
        self.assertEqual((self.root / MCP / gen.MCP_CONFIG).read_bytes(), content)
        for path in (self.root / gen.OUTPUT_ROOT).rglob("*"):
            if path.is_file():
                self.assertNotIn(SENTINEL.encode(), path.read_bytes(), path)

    def test_omp_mcp_matches_the_real_source_without_duplicate_connections(self) -> None:
        source = (gen.REPO_ROOT / gen.SOURCE_MCP_PATH).read_bytes()
        rendered = gen.omp_mcp_bytes(source)
        self.assertEqual(rendered, source)
        servers = json.loads(rendered)["mcpServers"]
        keys = {gen.mcp_connection_key(server) for server in servers.values()}
        self.assertEqual(len(keys), len(servers))

    def test_omp_mcp_keeps_unique_sources_and_existing_queries(self) -> None:
        unique = self.write_mcp_servers(
            {
                "a": {"type": "http", "url": "https://x.invalid/mcp"},
                "b": {"type": "sse", "url": "https://x.invalid/mcp"},
            }
        )
        self.assertIs(gen.omp_mcp_bytes(unique), unique)
        query = self.write_mcp_servers(
            {
                "a": {"type": "http", "url": "https://x.invalid/mcp?team=1"},
                "b": {"type": "http", "url": "https://x.invalid/mcp?team=1", "headers": {"X-Id": "${ID}"}},
                "c": {"type": "http", "url": "https://x.invalid/mcp?team=1"},
            }
        )
        servers = json.loads(gen.omp_mcp_bytes(query))["mcpServers"]
        self.assertEqual(servers["b"]["url"], "https://x.invalid/mcp?team=1")
        self.assertEqual(servers["b"]["headers"], {"X-Id": "${ID}"})
        self.assertEqual(servers["c"]["url"], "https://x.invalid/mcp?team=1&ycc-server=c")
        # omp's plugin loader drops requestIdFormat, so it never tells two connections apart.
        request_id = self.write_mcp_servers(
            {
                "a": {"type": "http", "url": "https://x.invalid/mcp"},
                "b": {"type": "http", "url": "https://x.invalid/mcp", "requestIdFormat": "string"},
            }
        )
        servers = json.loads(gen.omp_mcp_bytes(request_id))["mcpServers"]
        self.assertEqual(servers["b"]["url"], "https://x.invalid/mcp?ycc-server=b")

    def test_omp_mcp_stdio_duplicate_fails_closed(self) -> None:
        source = self.write_mcp_servers(
            {"a": {"command": "npx", "args": ["-y", "x"]}, "b": {"command": "npx", "args": ["-y", "x"]}}
        )
        with self.assertRaisesRegex(ValueError, r"^b: same stdio connection as a; OMP would shadow it$"):
            gen.omp_mcp_bytes(source)
        with self.assertRaisesRegex(ValueError, "same stdio connection"):
            self.output()

    def test_omp_mcp_disambiguation_keeps_placeholders_literal(self) -> None:
        headers = {"Authorization": "Bearer ${REMOTE_TOKEN}"}
        source = self.write_mcp_servers(
            {
                "a": {"type": "http", "url": "https://x.invalid/${TENANT}/mcp", "headers": headers},
                "b": {"type": "http", "url": "https://x.invalid/${TENANT}/mcp", "headers": headers},
            }
        )
        with mock.patch.dict(os.environ, {"TENANT": SENTINEL, "REMOTE_TOKEN": SENTINEL}):
            rendered = gen.omp_mcp_bytes(source)
        self.assertNotIn(SENTINEL.encode(), rendered)
        servers = json.loads(rendered)["mcpServers"]
        self.assertEqual(servers["b"]["url"], "https://x.invalid/${TENANT}/mcp?ycc-server=b")
        self.assertEqual(servers["b"]["headers"], headers)

    def test_secret_literals_in_the_mcp_source_fail_generation(self) -> None:
        cases: dict[str, dict[str, Any]] = {
            "env literal": {"command": "npx", "env": {"XERO_CLIENT_SECRET": "abc"}},
            "authorization literal": {"type": "http", "url": "https://x.invalid", "headers": {"Authorization": "abc"}},
            "bearer literal": {"type": "http", "url": "https://x.invalid", "headers": {"Authorization": "Bearer abc"}},
            "api key literal": {"command": "npx", "env": {"STRIPE_API_KEY": "sk_live_abc"}},
            "mixed placeholder": {"command": "npx", "env": {"API_TOKEN": "${API_TOKEN}abc"}},
            "dashed api key header": {"type": "http", "url": "https://x.invalid", "headers": {"X-API-Key": "abc"}},
            "dashed auth token header": {"type": "http", "url": "https://x.invalid", "headers": {"X-Auth-Token": "a"}},
        }
        for label, server in cases.items():
            with self.subTest(label=label):
                self.write_mcp_servers({"svc": server})
                with self.assertRaisesRegex(ValueError, r"mcp-configs/mcp\.json: .* looks like a secret literal"):
                    self.output()
        # A later duplicate placeholder must not mask an earlier literal: the strict loader rejects it.
        self.write_mcp(b'{"mcpServers": {"svc": {"env": {"API_TOKEN": "hunter2", "API_TOKEN": "${API_TOKEN}"}}}}\n')
        with self.assertRaisesRegex(ValueError, r"mcp-configs/mcp\.json: invalid JSON: duplicate JSON object key"):
            self.output()
        self.assertFalse((self.root / "packages").exists())

    def test_mcp_source_without_an_mcpservers_object_fails_generation(self) -> None:
        self.write_mcp(b'{"servers": {}}\n')
        with self.assertRaisesRegex(ValueError, r"mcp-configs/mcp\.json: missing mcpServers object"):
            self.output()

    def test_deferring_ycc_mcp_prunes_its_root(self) -> None:
        self.generate()
        self.assertTrue((self.root / MCP / gen.MCP_CONFIG).is_file())
        deferred = with_omp(self.model, "ycc-mcp", status="deferred")
        self.generate(deferred)
        self.assertFalse((self.root / MCP).exists())
        self.assertEqual(self.errors(deferred), [])

    def test_validator_rejects_mcp_drift_secrets_and_stray_entries(self) -> None:
        self.generate()
        config = self.root / MCP / gen.MCP_CONFIG
        config.write_bytes(config.read_bytes().replace(b"${XERO_CLIENT_SECRET}", b"hunter2"))
        (self.root / MCP / "skills").mkdir()
        errors = self.errors()
        self.assert_has(errors, f"{MCP / gen.MCP_CONFIG}: must equal the OMP rendering of mcp-configs/mcp.json")
        self.assert_has(errors, "XERO_CLIENT_SECRET looks like a secret literal")
        self.assert_has(errors, f"{MCP}/skills: unexpected entry outside the manifests and .mcp.json")
        config.unlink()
        self.assert_has(self.errors(), f"{MCP / gen.MCP_CONFIG}: missing MCP configuration")
        config.write_text("{not json", encoding="utf-8")
        self.assert_has(self.errors(), f"{MCP / gen.MCP_CONFIG}: invalid JSON")

    def test_validator_reports_raw_source_bytes_as_mcp_drift(self) -> None:
        source = self.write_mcp_servers(
            {
                "a": {"type": "http", "url": "https://x.invalid/mcp"},
                "b": {"type": "http", "url": "https://x.invalid/mcp"},
            }
        )
        self.generate()
        self.assertNotEqual(gen.omp_mcp_bytes(source), source)
        (self.root / MCP / gen.MCP_CONFIG).write_bytes(source)
        self.assertEqual(
            self.errors(), [f"{MCP / gen.MCP_CONFIG}: must equal the OMP rendering of mcp-configs/mcp.json"]
        )

    def test_deferring_ycc_drops_manifests_but_keeps_the_component_tree(self) -> None:
        self.generate()
        deferred = with_omp(self.model, "ycc", status="deferred")
        self.generate(deferred)
        for manifest in gen.MANIFESTS:
            self.assertFalse((self.root / YCC / manifest).exists(), manifest)
        self.assertTrue((self.root / YCC / "skills/alpha/SKILL.md").is_file())
        self.assertEqual(self.errors(deferred), [])

    # --- unique names ----------------------------------------------------------------

    def test_validator_rejects_colliding_runtime_package_names(self) -> None:
        self.generate()
        packages = gen.native_packages(self.model.packages)
        twin = replace(packages[0], key="YCC")
        (self.root / "packages/omp/YCC").mkdir()
        for manifest in gen.MANIFESTS:
            target = self.root / "packages/omp/YCC" / manifest
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps({"name": "YCC", "version": VERSION}), encoding="utf-8")
        errors = policy.manifest_errors(self.root, (*packages, twin), VERSION)
        self.assert_has(errors, "runtime package name 'YCC' collides with package 'ycc'")

    def test_validator_rejects_invalid_plugin_names(self) -> None:
        listed = with_omp(self.model, "ycc", listed=True)
        self.generate(listed)
        catalog = self.read(gen.MARKETPLACE_PATH)
        catalog["plugins"][0]["name"] = "-ycc"
        (self.root / gen.MARKETPLACE_PATH).write_text(json.dumps(catalog), encoding="utf-8")
        self.assert_has(self.errors(listed), "name must be a valid OMP name segment")

    def test_validator_reports_non_string_plugin_names_cleanly(self) -> None:
        listed = with_omp(self.model, "ycc", listed=True)
        self.generate(listed)
        catalog = self.read(gen.MARKETPLACE_PATH)
        for bad in (["ycc"], {"name": "ycc"}, 7, None):
            with self.subTest(name=bad):
                catalog["plugins"][0]["name"] = bad
                (self.root / gen.MARKETPLACE_PATH).write_text(json.dumps(catalog), encoding="utf-8")
                self.assert_has(self.errors(listed), "plugin names must be strings")

    # --- drift and closure -----------------------------------------------------------

    def test_check_reports_byte_mode_missing_and_extra_drift(self) -> None:
        output, roots = self.output()
        gen.write_payloads(self.root, output, roots, dry_run=False)
        self.assertEqual(gen.check_payloads(self.root, output, roots), [])
        (self.root / YCC / "agents/planner.md").write_text("edited\n", encoding="utf-8")
        os.chmod(self.root / YCC / "skills/alpha/scripts/run.sh", 0o644)
        (self.root / YCC / "commands/alpha.md").unlink()
        (self.root / YCC / "commands/stray.md").write_text("x\n", encoding="utf-8")
        (self.root / "packages/omp/ycc-hooks").mkdir()
        self.assertEqual(
            gen.check_payloads(self.root, output, roots),
            [
                f"drift: {YCC}/agents/planner.md",
                f"missing file: {YCC}/commands/alpha.md",
                f"executable-bit drift: {YCC}/skills/alpha/scripts/run.sh",
                f"extra in output: {YCC}/commands/stray.md",
                "extra in output: packages/omp/ycc-hooks",
            ],
        )
        gen.write_payloads(self.root, output, roots, dry_run=False)
        self.assertEqual(gen.check_payloads(self.root, output, roots), [])

    def test_component_mode_is_preserved_exactly_so_generators_agree(self) -> None:
        """A 0o700 source script (umask 077 checkout) must not be rewritten to 0o755."""
        import generate_omp_agents
        import generate_omp_commands
        import generate_omp_skills

        def skills_tree(dest: Path, dry_run: bool) -> None:
            script = dest / "alpha/scripts/run.sh"
            script.parent.mkdir(parents=True)
            script.write_bytes(b"#!/bin/sh\n")
            script.chmod(0o700)

        def empty_tree(dest: Path, dry_run: bool) -> None:
            dest.mkdir(parents=True)

        with (
            mock.patch.object(generate_omp_skills, "write_tree", skills_tree),
            mock.patch.object(generate_omp_agents, "write_tree", empty_tree),
            mock.patch.object(generate_omp_commands, "write_tree", empty_tree),
        ):
            output, roots = gen.build_output(self.model, VERSION, AUTHOR)
        script = YCC / "skills/alpha/scripts/run.sh"
        self.assertEqual(output[script].mode, 0o700)
        gen.write_payloads(self.root, output, roots, dry_run=False)
        self.assertEqual(stat.S_IMODE((self.root / script).stat().st_mode), 0o700)
        self.assertEqual(gen.check_payloads(self.root, output, roots), [])
        # The skills generator's own drift check compares every execute bit; it must agree.
        staged = self.root.parent / "staged"
        skills_tree(staged, dry_run=False)
        self.assertEqual(generate_omp_skills.compare_trees(staged, self.root / YCC / "skills"), [])
        gen.write_payloads(self.root, output, roots, dry_run=False)
        self.assertEqual(stat.S_IMODE((self.root / script).stat().st_mode), 0o700)
        os.chmod(self.root / script, 0o755)
        self.assertEqual(gen.check_payloads(self.root, output, roots), [f"executable-bit drift: {script}"])

    def test_foreign_catalog_files_are_pruned_whether_or_not_a_row_is_listed(self) -> None:
        listed = with_omp(self.model, "ycc", listed=True)
        stray = gen.CATALOG_DIR / "notes.md"
        for model in (self.model, listed):
            with self.subTest(listed=model is listed):
                (self.root / gen.CATALOG_DIR).mkdir(exist_ok=True)
                (self.root / stray).write_text("x\n", encoding="utf-8")
                output, roots = self.output(model)
                self.assertIn(f"extra in output: {stray}", gen.check_payloads(self.root, output, roots))
                gen.write_payloads(self.root, output, roots, dry_run=False)
                self.assertFalse((self.root / stray).exists())
                self.assertEqual(gen.check_payloads(self.root, output, roots), [])
        self.generate()
        self.assertFalse((self.root / gen.CATALOG_DIR).exists())

    def test_managed_symlinks_are_rejected_before_any_write(self) -> None:
        outside = self.root.parent / "outside"
        outside.mkdir()
        (self.root / "packages/omp").mkdir(parents=True)
        (self.root / YCC).symlink_to(outside, target_is_directory=True)
        output, roots = self.output()
        with self.assertRaisesRegex(ValueError, "managed-path symlink is not allowed: packages/omp/ycc"):
            gen.write_payloads(self.root, output, roots, dry_run=False)
        self.assertEqual(list(outside.iterdir()), [])

    def test_validator_reports_closure_gaps(self) -> None:
        self.generate()
        (self.root / "ycc/skills/beta").mkdir()
        (self.root / "ycc/skills/beta/SKILL.md").write_text("x\n", encoding="utf-8")
        (self.root / "ycc/agents/reviewer.md").write_text("x\n", encoding="utf-8")
        (self.root / YCC / "commands/ghost.md").write_text("x\n", encoding="utf-8")
        (self.root / YCC / "skills/empty").mkdir()
        (self.root / YCC / "notes.txt").write_text("x\n", encoding="utf-8")
        (self.root / YCC / "skills/alpha/SKILL.md").write_text("---\nname: alpha\n---\nskill://alpha/missing.md\n")
        errors = self.errors()
        for expected in (
            "skills/beta/SKILL.md: missing generated skill",
            "agents/reviewer.md: missing generated agent",
            "commands/ghost.md: no skill named 'ghost'",
            "skills/empty: skill directory has no SKILL.md",
            "notes.txt: unexpected entry",
            "skill://alpha/missing.md does not resolve inside the package",
        ):
            self.assert_has(errors, expected)

    def test_repository_output_is_in_sync_and_valid(self) -> None:
        model = load_package_model()
        self.assertEqual(gen.run_check(), 0)
        self.assertEqual(policy.validate(gen.REPO_ROOT, model), [])


if __name__ == "__main__":
    unittest.main()
