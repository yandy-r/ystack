#!/usr/bin/env python3
"""Regressions for the opencode file-copy skill generator's home-path rewrite."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_opencode_skills as skills  # noqa: E402

FORGE_PRIMARY = 'FORGE_LIB="${SCRIPT_DIR}/../../../shared/scripts/lib/forge.sh"'
FORGE_FALLBACK = '[[ -f "$FORGE_LIB" ]] || FORGE_LIB="${HOME}/.config/opencode/shared/scripts/lib/forge.sh"'


class HomePathTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.written = skills.write_tree(cls.root, dry_run=False)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def read(self, rel: str) -> str:
        return (self.root / rel).read_text(encoding="utf-8")

    def test_double_quoted_home_paths_use_an_expandable_home(self) -> None:
        # A quoted `~` is never expanded by bash, in scripts or in Markdown snippets.
        script = self.read("skills/research-to-issues/scripts/validate-prerequisites.sh")
        self.assertIn(FORGE_PRIMARY + "\n" + FORGE_FALLBACK + "\n", script)
        self.assertIn(
            'if [[ -f "${HOME}/.config/opencode/skills/orchestrate/scripts/validate-agents.sh" ]]; then',
            self.read("skills/orchestrate/SKILL.md"),
        )
        for rel in sorted(self.written):
            if rel.suffix in {".sh", ".bash", ".md"}:
                with self.subTest(path=rel):
                    self.assertNotIn('"~/.config/opencode/', self.read(rel.as_posix()))

    def test_unquoted_references_keep_the_home_shorthand(self) -> None:
        skill = self.read("skills/research-to-issues/SKILL.md")
        self.assertIn("\n~/.config/opencode/skills/research-to-issues/scripts/validate-prerequisites.sh ", skill)
        script = self.read("shared/scripts/pr-guard.sh")
        self.assertIn("#   ~/.config/opencode/shared/references/branching-model.md#rules", script)


if __name__ == "__main__":
    unittest.main()
