#!/usr/bin/env python3
"""Tests for scripts/validate_generated_shell_paths.py (quoted `~` and dead fallbacks)."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS_DIR))

from validate_generated_shell_paths import check_markdown, check_text, validate  # noqa: E402

CLEAN = (
    "#!/usr/bin/env bash\n"
    '# Docs may say "~/.config/opencode/shared/lib.sh" in a comment.\n'
    'LIB="${SCRIPT_DIR}/../shared/lib.sh"\n'
    '[[ -f "$LIB" ]] || LIB="${HOME}/.agents/ycc-shared/lib.sh"\n'
    'ROOT="$HOME/${raw_root#"~/"}"\n'
    'TRIMMED="${WORKTREE_ROOT%"~/"}"\n'
)

SKILL = (
    'Prose may say "~/.config/opencode/skills/a/run.sh".\n'
    "```bash\n"
    '# comment "~/x"\n'
    'bash "~/.config/opencode/shared/scripts/a.sh"\n'
    "git rebase -x '~/.config/opencode/skills/a/check.sh'\n"
    "```\n"
    "```json\n"
    '{"path": "~/.config/opencode/x"}\n'
    "```\n"
    "~~~sh\n"
    'source "~/.agents/ycc-shared/lib.sh"\n'
    "~~~\n"
)


class CheckTextTests(unittest.TestCase):
    def test_clean_script_and_strip_patterns_pass(self) -> None:
        self.assertEqual(check_text(CLEAN), [])

    def test_quoted_tilde_paths_fail(self) -> None:
        text = "LIB=\"~/.config/opencode/shared/lib.sh\"\necho '~/x'\n"
        self.assertEqual(
            check_text(text),
            [
                "line 1: quoted '~' is never expanded by the shell",
                "line 2: quoted '~' is never expanded by the shell",
            ],
        )

    def test_quoted_tilde_beside_a_strip_pattern_still_fails(self) -> None:
        self.assertEqual(
            check_text('X="${raw_root#"~/"}" Y="~/bad"\n'),
            ["line 1: quoted '~' is never expanded by the shell"],
        )

    def test_self_identical_fallback_fails(self) -> None:
        text = 'LIB="${SCRIPT_DIR}/lib.sh"\n[[ -f "$LIB" ]] || LIB="${SCRIPT_DIR}/lib.sh"\n'
        self.assertEqual(check_text(text), ["line 2: fallback for LIB repeats its primary path"])


class CheckMarkdownTests(unittest.TestCase):
    def test_only_double_quoted_tilde_in_shell_fences_fails(self) -> None:
        # Prose, comments, JSON fences and single-quoted command strings are not flagged.
        self.assertEqual(
            check_markdown(SKILL),
            [
                "line 4: quoted '~' is never expanded by the shell",
                "line 11: quoted '~' is never expanded by the shell",
            ],
        )

    def test_home_spelling_and_strip_patterns_pass(self) -> None:
        text = '```shell\nbash "${HOME}/.config/opencode/a.sh"\nX="${raw_root#"~/"}"\n```\n'
        self.assertEqual(check_markdown(text), [])


class ValidateTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def test_shell_files_and_markdown_shell_blocks_are_scanned_outside_node_modules(self) -> None:
        self.write("skills/a/SKILL.md", SKILL)
        self.write("skills/a/scripts/run.sh", CLEAN)
        self.write("skills/a/scripts/run.bash", 'X="~/bad"\n')
        self.write("node_modules/dep/run.sh", 'X="~/bad"\n')
        self.assertEqual(
            validate([self.root]),
            [
                f"{self.root / 'skills/a/SKILL.md'}: line 4: quoted '~' is never expanded by the shell",
                f"{self.root / 'skills/a/SKILL.md'}: line 11: quoted '~' is never expanded by the shell",
                f"{self.root / 'skills/a/scripts/run.bash'}: line 1: quoted '~' is never expanded by the shell",
            ],
        )

    def test_cli_reports_failures_to_stderr(self) -> None:
        self.write("run.sh", 'X="~/bad"\n')
        result = subprocess.run(
            [sys.executable, str(SCRIPTS_DIR / "validate_generated_shell_paths.py"), "--root", str(self.root)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("run.sh: line 1", result.stderr)

    def test_cli_default_roots_pass(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPTS_DIR / "validate_generated_shell_paths.py")],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
