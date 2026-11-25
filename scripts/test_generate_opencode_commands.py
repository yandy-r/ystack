#!/usr/bin/env python3
"""Focused checks for skill-derived OpenCode commands."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import generate_opencode_commands as commands
from description_budget import DESCRIPTION_LIMIT, DESCRIPTION_TOTAL_CAP
from generate_opencode_common import OPENCODE_COMMANDS_DIR, parse_frontmatter


class SkillCommandsTest(unittest.TestCase):
    def test_discovery_and_pruning(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, dest = root / "skills", root / "commands"
            for name, metadata in (
                ("public", ""),
                ("model-hidden", "disable-model-invocation: true\n"),
                ("hidden", "user-invocable: false\n"),
                ("_private", ""),
            ):
                path = source / name / "SKILL.md"
                path.parent.mkdir(parents=True)
                path.write_text(f"---\nname: {name}\n{metadata}description: Example\n---\nStale body", encoding="utf-8")
            (source / "incomplete").mkdir()
            self.assertEqual([p.parent.name for p in commands.discover_skills(source)], ["model-hidden", "public"])
            dest.mkdir()
            (dest / "orphan.md").write_text("old", encoding="utf-8")
            with patch.object(commands, "SRC_SKILLS_DIR", source):
                commands.write_all(dest, dry_run=False)
            self.assertEqual(sorted(p.name for p in dest.iterdir()), ["model-hidden.md", "public.md"])

    def test_thin_dispatch_and_frontmatter(self) -> None:
        raw = "---\ndescription: Example\nargument-hint: '[path] [--dry-run]'\nmodel: fast\n---\nDo not copy me\n"
        rendered = commands.transform_command("example", raw, {}, {"fast": "provider/model"})
        frontmatter, body = parse_frontmatter(rendered)
        self.assertEqual(frontmatter["description"], "Example")
        self.assertEqual(frontmatter["model"], "provider/model")
        self.assertIn("skill tool to load the `example` skill", body)
        self.assertIn("$ARGUMENTS", body)
        self.assertNotIn("/example", body)
        self.assertNotIn("Do not copy me", body)

    def test_argument_hint_never_enters_description(self) -> None:
        long_hint = "[--flag-1] [--flag-2] " * 20
        raw = f"---\ndescription: Short description\nargument-hint: '{long_hint}'\n---\nBody"
        rendered = commands.transform_command("example", raw, {}, {})
        frontmatter, _ = parse_frontmatter(rendered)
        self.assertEqual(frontmatter["description"], "Short description")
        self.assertNotIn("Usage:", rendered)
        self.assertNotIn("--flag-1", rendered)

    def _write_commands(self, root: Path, lengths: list[int]) -> None:
        for index, length in enumerate(lengths):
            (root / f"cmd-{index}.md").write_text(f"---\ndescription: {'x' * length}\n---\nbody\n", encoding="utf-8")

    def test_budget_accepts_commands_within_caps(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_commands(root, [DESCRIPTION_LIMIT, 10])
            self.assertEqual(commands.description_budget_errors(root), [])

    def test_budget_rejects_over_cap_description(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_commands(root, [DESCRIPTION_LIMIT + 1])
            errors = commands.description_budget_errors(root)
            self.assertEqual(len(errors), 1)
            self.assertIn("listing cap", errors[0])
            self.assertIn("SKILL.md", errors[0])

    def test_budget_accepts_exact_aggregate_cap(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            full_files = DESCRIPTION_TOTAL_CAP // DESCRIPTION_LIMIT
            self._write_commands(root, [DESCRIPTION_LIMIT] * full_files)
            self.assertEqual(commands.description_budget_errors(root), [])

    def test_budget_rejects_one_char_over_aggregate_cap(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            full_files = DESCRIPTION_TOTAL_CAP // DESCRIPTION_LIMIT
            lengths = [DESCRIPTION_LIMIT] * full_files + [1]
            self._write_commands(root, lengths)
            self.assertEqual(sum(lengths), DESCRIPTION_TOTAL_CAP + 1)
            errors = commands.description_budget_errors(root)
            self.assertEqual(len(errors), 1)
            self.assertIn("listing budget", errors[0])

    def test_generated_commands_fit_budget(self) -> None:
        self.assertEqual(commands.description_budget_errors(OPENCODE_COMMANDS_DIR), [])

    def test_absent_hint_has_no_usage(self) -> None:
        for hint in ("", "argument-hint: null\n"):
            raw = f"---\ndescription: Example\n{hint}---\n"
            rendered = commands.transform_command("example", raw, {}, {})
            self.assertNotIn("Usage:", rendered)


if __name__ == "__main__":
    unittest.main()
