#!/usr/bin/env python3
"""Unit tests for the README Purpose summaries built by scripts/generate_inventory.py.

Run directly (``python3 scripts/test_generate_inventory.py``) or through
``./scripts/validate.sh --only inventory``.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_inventory as gi  # noqa: E402


class ShortDescriptionTestCase(unittest.TestCase):
    def test_capability_first_description_keeps_first_sentence(self) -> None:
        self.assertEqual(
            gi.short_description("Builds things. Use when building things."),
            "Builds things.",
        )

    def test_leading_trigger_is_skipped_for_capability_sentence(self) -> None:
        self.assertEqual(
            gi.short_description("Use when structuring Go packages. Guides idiomatic Go package layout."),
            "Guides idiomatic Go package layout.",
        )

    def test_trigger_match_is_case_insensitive_and_whitespace_tolerant(self) -> None:
        self.assertEqual(
            gi.short_description("  use  WHEN\nplanning.\n  Plans work.  "),
            "Plans work.",
        )

    def test_trigger_only_description_uses_body_lead(self) -> None:
        body = (
            "\n# Plan Skill\n\n**Callout first.**\n\n"
            "Create a plan before code. More detail here.\n\nLater paragraph.\n"
        )
        self.assertEqual(
            gi.short_description("Use when planning a change.", body),
            "Create a plan before code.",
        )

    def test_trigger_only_description_without_body_falls_back_to_first_sentence(self) -> None:
        self.assertEqual(
            gi.short_description("Use when planning a change."),
            "Use when planning a change.",
        )

    def test_trigger_body_lead_is_not_preferred(self) -> None:
        self.assertEqual(
            gi.short_description("Use when planning.", "Use when the body also triggers."),
            "Use when planning.",
        )

    def test_overlong_capability_sentence_is_truncated_within_limit(self) -> None:
        long_sentence = "Does " + "x" * 400 + "."
        result = gi.short_description("Use when needed. " + long_sentence)
        self.assertTrue(result.startswith("Does "))
        self.assertTrue(result.endswith("..."))
        self.assertLessEqual(len(result), gi.SHORT_DESC_LIMIT + 3)

    def test_empty_and_whitespace_descriptions_return_empty(self) -> None:
        self.assertEqual(gi.short_description(""), "")
        self.assertEqual(gi.short_description("   \n "), "")

    def test_no_terminal_punctuation_returns_whole_text(self) -> None:
        self.assertEqual(gi.short_description("Builds things"), "Builds things")


class BodyLeadTestCase(unittest.TestCase):
    def test_skips_headings_callouts_lists_and_fences(self) -> None:
        body = "# Title\n\n```\ncode line\n```\n\n- item\n> quote\n\nFirst prose\nline two.\n\nSecond.\n"
        self.assertEqual(gi.body_lead(body), "First prose line two.")

    def test_empty_body_returns_empty(self) -> None:
        self.assertEqual(gi.body_lead(""), "")


class ReadmeTableTestCase(unittest.TestCase):
    def test_no_purpose_cell_leads_with_trigger(self) -> None:
        for cmd in gi.discover_commands():
            purpose = gi.short_description(cmd["description"], gi.skill_body(cmd["name"]))
            with self.subTest(skill=cmd["name"]):
                self.assertTrue(purpose)
                self.assertFalse(purpose.lower().startswith("use when"), purpose)
                self.assertLessEqual(len(purpose), gi.SHORT_DESC_LIMIT + 3)

    def test_skill_body_missing_skill_is_empty(self) -> None:
        self.assertEqual(gi.skill_body("does-not-exist-skill"), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
