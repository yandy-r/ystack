#!/usr/bin/env python3
"""Golden tests for scripts/generate_omp_commands.py."""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_omp_commands as omp  # noqa: E402
from generate_codex_common import SRC_SKILLS_DIR, parse_frontmatter  # noqa: E402
from generate_omp_skills import OmpGenerationError  # noqa: E402

DEMO_SKILL = """\
---
name: demo
description: Demo skill; chain into /ycc:helper when done.
argument-hint: '[--dry-run] <target>'
allowed-tools: Read
---

# Demo
"""

HELPER_SKILL = """\
---
name: helper
description: Helper skill.
---

# Helper
"""

DEMO_COMMAND = """\
---
description: Demo skill; chain into /skill:helper when done.
argument-hint: '[--dry-run] <target>'
---

Read `skill://demo` and follow its instructions with these arguments:

$ARGUMENTS
"""

HELPER_COMMAND = """\
---
description: Helper skill.
---

Read `skill://helper` and follow its instructions with these arguments:

$ARGUMENTS
"""


def skill(name: str, extra: str = "") -> str:
    return f"---\nname: {name}\ndescription: {name.title()} skill.\n{extra}---\n\n# {name}\n"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


class FixtureTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.src = self.root / "skills"
        self.dest = self.root / "out"
        write(self.src / "demo/SKILL.md", DEMO_SKILL)
        write(self.src / "helper/SKILL.md", HELPER_SKILL)
        write(self.src / "_shared/references/note.md", "Shared note.\n")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def generate(
        self,
        dest: Path | None = None,
        namespace: str = omp.COMMAND_NAMESPACE,
        reserved: frozenset[str] = omp.OMP_BUILTIN_COMMANDS,
    ) -> set[Path]:
        target = self.dest if dest is None else dest
        return omp.write_tree(target, dry_run=False, src_root=self.src, namespace=namespace, reserved=reserved)

    def text(self, name: str) -> str:
        return (self.dest / f"{name}.md").read_text(encoding="utf-8")

    def assert_fails(
        self,
        *needles: str,
        namespace: str = omp.COMMAND_NAMESPACE,
        reserved: frozenset[str] = omp.OMP_BUILTIN_COMMANDS,
    ) -> None:
        with self.assertRaises(OmpGenerationError) as caught:
            self.generate(namespace=namespace, reserved=reserved)
        for needle in needles:
            self.assertIn(needle, str(caught.exception))
        self.assertFalse(self.dest.exists())


class WrapperTest(FixtureTestCase):
    def test_wrapper_shape_hint_kept_and_description_rewritten(self) -> None:
        self.assertEqual(self.generate(), {Path("demo.md"), Path("helper.md")})
        self.assertEqual(self.text("demo"), DEMO_COMMAND)

    def test_hint_omitted_when_source_has_none(self) -> None:
        self.generate()
        self.assertEqual(self.text("helper"), HELPER_COMMAND)
        self.assertNotIn("argument-hint", parse_frontmatter(self.text("helper"))[0])

    def test_frontmatter_round_trips_yaml_special_characters(self) -> None:
        description = 'Say "hi" \\ to C:\\tmp: then # not a comment, café ✓.'
        hint = "[--name \"x\"] <'y'> [--tag #1]"
        write(
            self.src / "helper/SKILL.md",
            skill("helper", 'argument-hint: "[--name \\"x\\"] <\'y\'> [--tag #1]"\n').replace(
                "description: Helper skill.",
                'description: "Say \\"hi\\" \\\\ to C:\\\\tmp: then # not a comment, café ✓."',
            ),
        )
        self.generate()
        frontmatter, _ = parse_frontmatter(self.text("helper"))
        self.assertEqual(frontmatter, {"description": description, "argument-hint": hint})


class PolicyTest(FixtureTestCase):
    def test_manual_only_skill_gets_a_command(self) -> None:
        write(self.src / "manual/SKILL.md", skill("manual", "disable-model-invocation: true\n"))
        self.generate()
        self.assertIn("Read `skill://manual`", self.text("manual"))

    def test_user_invocable_false_is_skipped(self) -> None:
        write(self.src / "hidden/SKILL.md", skill("hidden", "user-invocable: false\n"))
        self.assertEqual(self.generate(), {Path("demo.md"), Path("helper.md")})

    def test_shared_is_skipped(self) -> None:
        write(self.src / "_shared/SKILL.md", skill("shared"))
        self.assertEqual(self.generate(), {Path("demo.md"), Path("helper.md")})


class FailureTest(FixtureTestCase):
    def test_bad_name(self) -> None:
        write(self.src / "bad/SKILL.md", skill("Bad_Name"))
        self.assert_fails("skill 'bad'", "'Bad_Name'", "^[a-z0-9][a-z0-9-]*$")

    def test_duplicate_name(self) -> None:
        write(self.src / "helper-copy/SKILL.md", skill("helper"))
        self.assert_fails("commands/helper.md", "duplicate command name 'helper'")

    def test_reserved_collision(self) -> None:
        self.assert_fails("'ycc:demo' is an OMP built-in", reserved=frozenset({"ycc:demo"}))

    def test_namespace_must_not_be_a_builtin(self) -> None:
        self.assertNotIn(omp.COMMAND_NAMESPACE, omp.OMP_BUILTIN_COMMANDS)
        self.assert_fails("namespace 'plan' is an OMP built-in", namespace="plan")

    def test_omp_18_16_tui_builtins_are_pinned_and_rejected(self) -> None:
        # omp 18.16.0 TUI-only built-ins; RPC get_available_commands cannot report them,
        # so only the hand pin keeps the collision guard rejecting them.
        for name in ("local", "subagents"):
            with self.subTest(name=name):
                self.assertIn(name, omp.OMP_BUILTIN_COMMANDS)
                self.assert_fails(f"namespace '{name}' is an OMP built-in", namespace=name)

    def test_empty_description(self) -> None:
        write(self.src / "helper/SKILL.md", HELPER_SKILL.replace("Helper skill.", "''"))
        self.assert_fails("commands/helper.md", "non-empty string description")

    def test_non_string_hint(self) -> None:
        write(self.src / "helper/SKILL.md", skill("helper", "argument-hint: [1, 2]\n"))
        self.assert_fails("commands/helper.md", "'argument-hint' must be a string")

    def test_non_boolean_user_invocable(self) -> None:
        write(self.src / "helper/SKILL.md", skill("helper", "user-invocable: 'no'\n"))
        self.assert_fails("skill 'helper'", "'user-invocable' must be a boolean")


class TreeTest(FixtureTestCase):
    def test_idempotent_and_prunes_orphans(self) -> None:
        self.generate()
        before = {p: p.read_bytes() for p in self.dest.rglob("*")}
        write(self.dest / "stale.md", "stale\n")
        self.generate()
        self.assertEqual({p: p.read_bytes() for p in self.dest.rglob("*")}, before)


class RealTreeTest(unittest.TestCase):
    def test_inventory_parity(self) -> None:
        public = set()
        for path in SRC_SKILLS_DIR.glob("*/SKILL.md"):
            frontmatter, _ = parse_frontmatter(path.read_text(encoding="utf-8"))
            if omp.is_public(frontmatter, path.parent.name):
                public.add(path.parent.name)
        with tempfile.TemporaryDirectory() as raw:
            written = omp.write_tree(Path(raw), dry_run=False)
            files = sorted(p.name for p in Path(raw).iterdir())
        self.assertEqual(files, sorted(f"{name}.md" for name in public))
        self.assertEqual(written, {Path(f"{name}.md") for name in public})

    def test_check_detects_drift_and_orphans(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            dest = Path(raw)
            omp.write_tree(dest, dry_run=False)
            self.assertEqual(omp.run_check(dest), 0)
            drifted, removed = sorted(dest.glob("*.md"))[:2]
            drifted.write_text(drifted.read_text(encoding="utf-8") + "drift\n", encoding="utf-8")
            write(dest / "orphan.md", "orphan\n")
            removed.unlink()
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(omp.run_check(dest), 1)
            self.assertIn(f"drift: {drifted.name}", stderr.getvalue())
            self.assertIn("extra in repo: orphan.md", stderr.getvalue())
            self.assertIn(f"missing in repo: {removed.name}", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
