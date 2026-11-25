#!/usr/bin/env python3
"""Repository-shaped unittest fixtures for Claude native namespace and preload policy."""

from __future__ import annotations

import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from typing import Any

from package_model import Package, PackageModel, RuntimePackage
from validate_claude_native import load_agent_skills, validate

VERSION = "1.2.3"


def package(key: str, *components: str, requires: tuple[str, ...] = (), listed: bool = False) -> Package:
    runtime = RuntimePackage(
        runtime="claude",
        status="included",
        listed=listed,
        mechanism="native",
        components=tuple(components),
        requires=requires,
        target_release="v6.0.0",
        experimental=False,
        opt_in=False,
        evidence=(),
        gates=(),
        notes="fixture",
    )
    return Package(key, "fixture", "lockstep", (runtime,))


class ClaudeNativeValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.write_json("version.json", {"version": VERSION})
        self.packages: list[Package] = []
        self.entries: list[dict[str, Any]] = []
        self.write_json(".claude-plugin/marketplace.json", {"name": "fixture", "plugins": self.entries})

    def write_json(self, relative: str | Path, payload: Any) -> Path:
        return self.write_text(relative, json.dumps(payload) + "\n")

    def write_text(self, relative: str | Path, text: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    @staticmethod
    def package_root(key: str) -> Path:
        return Path("ycc") if key == "ycc" else Path("packages/claude") / key

    def add_package(self, key: str, *components: str, requires: tuple[str, ...] = (), listed: bool = False) -> Path:
        self.packages.append(package(key, *components, requires=requires, listed=listed))
        root = self.package_root(key)
        manifest: dict[str, Any] = {"name": key, "version": VERSION}
        if requires:
            manifest["dependencies"] = list(requires)
        self.write_json(root / ".claude-plugin/plugin.json", manifest)
        for component in ("skills", "agents"):
            if component in components:
                (self.root / root / component).mkdir(parents=True, exist_ok=True)
        if "mcp" in components:
            self.write_json(root / ".mcp.json", {"mcpServers": {}})
        if "hooks" in components:
            self.write_json(root / "hooks/hooks.json", {"hooks": {}})
        if listed:
            self.entries.append({"name": key, "source": "./" + root.as_posix(), "version": VERSION})
            self.write_json(".claude-plugin/marketplace.json", {"name": "fixture", "plugins": self.entries})
        return root

    def add_skill(self, key: str, name: str) -> Path:
        return self.write_text(self.package_root(key) / "skills" / name / "SKILL.md", f"# {name}\n")

    def add_agent(self, key: str, skills: str, name: str = "worker") -> Path:
        return self.write_text(
            self.package_root(key) / "agents" / f"{name}.md",
            f"---\nname: {name}\nskills: {skills}\n---\nAgent body.\n",
        )

    def errors(self) -> list[str]:
        return validate(self.root, PackageModel(1, "version.json", tuple(self.packages)))

    def assert_error(self, fragment: str) -> None:
        errors = self.errors()
        self.assertTrue(any(fragment in error for error in errors), f"expected {fragment!r} in {errors!r}")

    def test_current_layout_canonical_and_hidden_addons_are_valid(self) -> None:
        self.add_package("ycc", "skills", "agents", "shared", listed=True)
        self.add_skill("ycc", "plan")
        self.add_agent("ycc", "[plan, 'ycc:plan']")
        self.add_package("ycc-mcp", "mcp")
        self.add_package("ycc-hooks", "hooks")
        self.add_package("ycc-all", requires=("ycc", "ycc-mcp", "ycc-hooks"))
        self.assertEqual(self.errors(), [])
        self.assertFalse((self.root / "packages/claude/ycc").exists())

    def test_manifest_name_reuse_of_canonical_is_rejected(self) -> None:
        self.add_package("ycc", listed=True)
        addon = self.add_package("ycc-extra")
        self.write_json(addon / ".claude-plugin/plugin.json", {"name": "ycc", "version": VERSION})
        self.assert_error("duplicate manifest name 'ycc'")
        self.assert_error("must match package key 'ycc-extra'")

    def test_manifest_wrong_or_malformed_name_is_diagnostic_not_type_error(self) -> None:
        addon = self.add_package("ycc-extra")
        names: tuple[object, ...] = ("wrong", [], None)
        for name in names:
            with self.subTest(name=name):
                self.write_json(addon / ".claude-plugin/plugin.json", {"name": name, "version": VERSION})
                self.assertTrue(self.errors())

    def test_marketplace_name_and_source_manifest_must_match(self) -> None:
        self.add_package("ycc", listed=True)
        self.entries[0]["name"] = "wrong"
        self.write_json(".claude-plugin/marketplace.json", {"name": "fixture", "plugins": self.entries})
        self.assert_error("does not match source manifest/package 'ycc'")

    def test_marketplace_cannot_point_at_another_package_or_outside_root(self) -> None:
        self.add_package("ycc", listed=True)
        self.add_package("ycc-other")
        for source in ("./packages/claude/ycc-other", "../outside"):
            with self.subTest(source=source):
                self.entries[0]["source"] = source
                self.write_json(".claude-plugin/marketplace.json", {"name": "fixture", "plugins": self.entries})
                self.assertTrue(self.errors())

    def test_versions_and_dependencies_follow_model(self) -> None:
        self.add_package("ycc", listed=True)
        addon = self.add_package("ycc-extra", requires=("ycc",))
        self.write_json(
            addon / ".claude-plugin/plugin.json",
            {"name": "ycc-extra", "version": "9.9.9", "dependencies": ["ycc@^1"]},
        )
        self.assert_error("manifest version must match")
        self.assert_error("dependencies must match modeled requires ['ycc']")
        self.entries[0]["version"] = "9.9.9"
        self.write_json(".claude-plugin/marketplace.json", {"name": "fixture", "plugins": self.entries})
        self.assert_error("marketplace version must match")

    def test_unknown_or_nonincluded_requires_target_is_rejected(self) -> None:
        self.add_package("ycc-agents", "agents", requires=("missing",))
        self.assert_error("dependency 'missing' is not an included native Claude package")
        deferred = package("missing", "skills")
        self.packages.append(replace(deferred, runtimes=(replace(deferred.runtimes[0], status="deferred"),)))
        self.assert_error("dependency 'missing' is not an included native Claude package")

    def test_future_agents_and_skills_packages_resolve_transitive_preload(self) -> None:
        self.add_package("ycc-skills", "skills")
        self.add_skill("ycc-skills", "plan")
        self.add_package("ycc-meta", requires=("ycc-skills",))
        self.add_package("ycc-agents", "agents", requires=("ycc-meta",))
        self.add_agent("ycc-agents", "\n  - 'ycc-skills:plan' # inline YAML comment")
        self.assertEqual(self.errors(), [])

    def test_bare_cross_package_preload_requires_qualification(self) -> None:
        self.add_package("ycc", "skills", listed=True)
        self.add_skill("ycc", "plan")
        self.add_package("ycc-agents", "agents", requires=("ycc",))
        self.add_agent("ycc-agents", "plan")
        self.assert_error("unqualified cross-package agent skill 'plan'")

    def test_bare_same_package_preload_wins_even_when_dependency_has_same_skill(self) -> None:
        self.add_package("ycc", "skills", listed=True)
        self.add_skill("ycc", "plan")
        self.add_package("ycc-extra", "agents", "skills", requires=("ycc",))
        self.add_skill("ycc-extra", "plan")
        self.add_agent("ycc-extra", "plan")
        self.assertEqual(self.errors(), [])

    def test_preload_cannot_target_an_unrelated_existing_package(self) -> None:
        self.add_package("ycc-skills", "skills")
        self.add_skill("ycc-skills", "plan")
        self.add_package("ycc-agents", "agents")
        self.add_agent("ycc-agents", "'ycc-skills:plan'")
        self.assert_error("outside its requires closure")

    def test_missing_skill_not_satisfied_by_agent_name_or_component_label(self) -> None:
        self.add_package("ycc-agents", "agents", "skills")
        for reference in ("worker", "skills", "'ycc-agents:absent'"):
            with self.subTest(reference=reference):
                self.add_agent("ycc-agents", reference)
                self.assert_error("missing agent skill")

    def test_nested_agent_preloads_are_scanned_recursively(self) -> None:
        self.add_package("ycc-agents", "agents", "skills")
        self.add_skill("ycc-agents", "plan")
        self.write_text(
            self.package_root("ycc-agents") / "agents/team/review/worker.md",
            "---\nname: worker\nskills: [absent]\n---\nNested agent body.\n",
        )
        self.assert_error("agents/team/review/worker.md")
        self.assert_error("missing agent skill 'absent'")

    def test_malformed_preload_yaml_and_types_fail(self) -> None:
        self.add_package("ycc-agents", "agents")
        for value in ("[", "[3]", "{plan: yes}", "true", "['']"):
            with self.subTest(value=value):
                self.add_agent("ycc-agents", value)
                self.assertTrue(self.errors())

    def test_yaml_parser_ignores_body_and_handles_scalar_or_list(self) -> None:
        self.assertEqual(load_agent_skills("---\nskills: 'ycc:plan'\n---\nskills: missing\n"), ["ycc:plan"])
        self.assertEqual(load_agent_skills("---\nskills: [plan, 'ycc:review']\n---\n"), ["plan", "ycc:review"])
        self.assertEqual(load_agent_skills("---\nskills:\n  - plan\n  - ycc:review\n---\n"), ["plan", "ycc:review"])

    def test_requires_cycle_is_diagnostic(self) -> None:
        self.add_package("a", requires=("b",))
        self.add_package("b", requires=("a",))
        self.assert_error("requires cycle")

    def test_unreadable_json_and_missing_modeled_payload_are_diagnostic(self) -> None:
        addon = self.add_package("ycc-extra", "mcp")
        self.write_text(addon / ".claude-plugin/plugin.json", "[]")
        (self.root / addon / ".mcp.json").unlink()
        self.assert_error("expected a JSON object")
        self.assert_error("missing modeled mcp payload")


if __name__ == "__main__":
    unittest.main()
