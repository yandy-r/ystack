#!/usr/bin/env python3
"""Golden tests for scripts/generate_pi_skills.py (YAN-1184)."""

from __future__ import annotations

import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_pi_skills as pi  # noqa: E402
from generate_codex_common import parse_frontmatter  # noqa: E402

ALIASES = {"implementor": "implementor", "releaser": "releaser"}

DEMO_SKILL = """\
---
name: demo
description: Demo skill.
argument-hint: '[--flag]'
allowed-tools:
  - Read
  - 'Bash(${CLAUDE_PLUGIN_ROOT}/skills/demo/scripts/*.sh:*)'
disable-model-invocation: true
---

# Demo

Parse `$ARGUMENTS`.
Read `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/guide.md` first.
Then read `${CLAUDE_PLUGIN_ROOT}/skills/releaser/references/notes.md#cut`.
Run `${CLAUDE_PLUGIN_ROOT}/skills/demo/scripts/run.sh --x`.
Pattern `${CLAUDE_PLUGIN_ROOT}/skills/demo/scripts/<name>.sh` stays a pattern.
See [guide](../_shared/references/guide.md).
Run /ycc:releaser to cut; delegate to the `ycc:implementor` agent.
Write it with the Write tool; review read-only (Read/Grep/Glob).

<!-- ycc:verbatim-block:begin -->
Keep /ycc:releaser here.
<!-- ycc:verbatim-block:end -->
"""

DEEP_REF = (
    "Deep: [guide](../../_shared/references/guide.md) and `${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/lib.sh`.\n"
)

RUN_SH = """\
#!/usr/bin/env bash
# Rules: ${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/guide.md
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB="${SCRIPT_DIR}/../../_shared/scripts/lib.sh"
[[ -f "$LIB" ]] || LIB="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/lib.sh"
echo 'run /ycc:releaser next'
"""


def write(path: Path, text: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(mode)


class PiSkillsTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.src = root / "skills"
        self.dest = root / "out"
        write(self.src / "demo/SKILL.md", DEMO_SKILL)
        write(self.src / "demo/references/deep/ref.md", DEEP_REF)
        write(self.src / "demo/scripts/run.sh", RUN_SH, 0o755)
        write(self.src / "releaser/SKILL.md", "---\nname: releaser\ndescription: Releaser.\n---\n\nBody.\n")
        write(self.src / "releaser/references/notes.md", "Notes.\n")
        write(self.src / "_shared/references/guide.md", "Guide.\n")
        write(self.src / "_shared/scripts/lib.sh", "#!/usr/bin/env bash\n", 0o755)
        write(self.src / "_shared/references/forge.md", "See [lib](../scripts/lib.sh#top) and [g](guide.md).\n")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def generate(self) -> set[Path]:
        return pi.write_tree(self.dest, dry_run=False, src_root=self.src, aliases=ALIASES)

    def read(self, rel: str) -> str:
        return (self.dest / rel).read_text(encoding="utf-8")

    def assert_fails(self, rel: str, text: str, needle: str) -> None:
        write(self.src / rel, text)
        with self.assertRaises(pi.GenerationError) as caught:
            self.generate()
        self.assertIn(needle, str(caught.exception))

    def test_inventory_parity_each_file_once_and_no_extra_skill(self) -> None:
        written = self.generate()
        source = {p.relative_to(self.src) for p in self.src.rglob("*") if p.is_file()}
        self.assertEqual(written, source)
        self.assertFalse((self.dest / "_shared/SKILL.md").exists())

    def test_path_rewriting_is_skill_directory_relative(self) -> None:
        self.generate()
        body = self.read("demo/SKILL.md")
        self.assertIn("Read `../_shared/references/guide.md` first.", body)
        self.assertIn("`../releaser/references/notes.md#cut`", body)
        self.assertIn("`../demo/scripts/run.sh --x`", body)
        self.assertIn("`../demo/scripts/<name>.sh` stays a pattern", body)
        self.assertIn("[guide](../_shared/references/guide.md)", body)
        deep = self.read("demo/references/deep/ref.md")
        self.assertEqual(deep, "Deep: [guide](../_shared/references/guide.md) and `../_shared/scripts/lib.sh`.\n")

    def test_shared_internal_links_become_skill_directory_relative(self) -> None:
        self.generate()
        self.assertEqual(
            self.read("_shared/references/forge.md"), "See [lib](../_shared/scripts/lib.sh#top) and [g](guide.md).\n"
        )

    def test_missing_shared_internal_link_fails(self) -> None:
        self.assert_fails("_shared/references/bad.md", "[x](../scripts/gone.sh)\n", "does not exist")

    def test_namespace_tools_and_verbatim_block(self) -> None:
        self.generate()
        body = self.read("demo/SKILL.md")
        self.assertIn("Run /skill:releaser to cut; delegate to the `implementor` agent.", body)
        self.assertIn("with the write tool; review read-only (read/grep/find).", body)
        self.assertIn("Keep /ycc:releaser here.", body)
        self.assertNotIn("ycc:verbatim-block", body)

    def test_frontmatter_keeps_pi_keys_and_manual_only_policy(self) -> None:
        self.generate()
        frontmatter, _ = parse_frontmatter(self.read("demo/SKILL.md"))
        self.assertEqual(frontmatter, {"name": "demo", "description": "Demo skill.", "disable-model-invocation": True})

    def test_arguments_preamble_only_where_used(self) -> None:
        self.generate()
        self.assertIn("text typed after `/skill:demo`", self.read("demo/SKILL.md"))
        self.assertNotIn("$ARGUMENTS", self.read("releaser/SKILL.md"))

    def test_script_fallback_collapses_and_helpers_stay_executable(self) -> None:
        self.generate()
        script = self.read("demo/scripts/run.sh")
        self.assertIn('LIB="${SCRIPT_DIR}/../../_shared/scripts/lib.sh"\necho', script)
        self.assertIn("# Rules: ../_shared/references/guide.md", script)
        self.assertIn("echo 'run /skill:releaser next'", script)
        self.assertNotIn("CLAUDE_PLUGIN_ROOT", script)
        for rel in ("demo/scripts/run.sh", "_shared/scripts/lib.sh"):
            self.assertTrue((self.dest / rel).stat().st_mode & stat.S_IXUSR, rel)
        self.assertFalse((self.dest / "demo/SKILL.md").stat().st_mode & stat.S_IXUSR)

    def test_missing_reference_fails(self) -> None:
        self.assert_fails(
            "demo/references/bad.md", "`${CLAUDE_PLUGIN_ROOT}/skills/_shared/gone.md`\n", "does not exist"
        )

    def test_unknown_namespace_reference_fails(self) -> None:
        self.assert_fails("demo/references/bad.md", "Run /ycc:nope.\n", "ycc:nope")

    def test_plugin_root_in_script_code_fails(self) -> None:
        self.assert_fails("demo/scripts/bad.sh", 'cd "${CLAUDE_PLUGIN_ROOT}"\n', "unsupported CLAUDE_PLUGIN_ROOT")

    def test_non_boolean_invocation_flag_fails(self) -> None:
        write(self.src / "demo/SKILL.md", "---\nname: demo\ndescription: D.\ndisable-model-invocation: 'yes'\n---\n")
        with self.assertRaisesRegex(ValueError, "must be a boolean"):
            self.generate()

    def test_discovery_traps_fail(self) -> None:
        self.assert_fails("_shared/nested/SKILL.md", "---\nname: x\ndescription: X.\n---\n", "discovered as a Pi skill")

    def test_loose_root_markdown_fails(self) -> None:
        self.assert_fails("README.md", "Loose.\n", "discovered as a Pi skill")

    def test_arguments_outside_defining_skill_fails(self) -> None:
        self.assert_fails("releaser/references/args.md", "Use `$ARGUMENTS`.\n", "does not define it")

    def test_idempotent_and_prunes_orphans(self) -> None:
        self.generate()
        first = {p: p.read_bytes() for p in self.dest.rglob("*") if p.is_file()}
        write(self.dest / "stale/old.md", "stale\n")
        self.generate()
        second = {p: p.read_bytes() for p in self.dest.rglob("*") if p.is_file()}
        self.assertEqual(first, second)


class RealTreeTest(unittest.TestCase):
    def test_real_tree_parity(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            dest = Path(raw)
            written = pi.write_tree(dest, dry_run=False)
            source = {p.relative_to(pi.SRC_DIR) for p in pi.SRC_DIR.rglob("*") if p.is_file()}
            self.assertEqual(written, source)
            skills = sorted(p.parent.name for p in dest.glob("*/SKILL.md"))
            self.assertEqual(skills, sorted(p.parent.name for p in pi.SRC_DIR.glob("*/SKILL.md")))
            manual = {
                p.parent.name
                for p in dest.glob("*/SKILL.md")
                if parse_frontmatter(p.read_text(encoding="utf-8"))[0].get("disable-model-invocation") is True
            }
            source_manual = {
                p.parent.name
                for p in pi.SRC_DIR.glob("*/SKILL.md")
                if parse_frontmatter(p.read_text(encoding="utf-8"))[0].get("disable-model-invocation") is True
            }
            self.assertEqual(manual, source_manual)
            self.assertTrue(manual)


class GeneratedHelperTest(unittest.TestCase):
    def test_generated_scaffold_helper_writes_canonical_source(self) -> None:
        """Regression: a bundle copy of scaffold-skill.sh must not scaffold inside packages/pi."""
        repo = pi.REPO_ROOT
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            for rel in ("ycc/.claude-plugin", "ycc/skills/bundle-author", "ycc/agents"):
                shutil.copytree(repo / rel, root / rel)
            pi.write_tree(root / "packages/pi/ycc/skills", dry_run=False)
            helper = root / "packages/pi/ycc/skills/bundle-author/scripts/scaffold-skill.sh"
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["bash", str(helper), "zz-probe"], cwd=root, check=True, capture_output=True)
            self.assertTrue((root / "ycc/skills/zz-probe/SKILL.md").is_file())
            self.assertFalse((root / "packages/pi/ycc/skills/zz-probe").exists())


if __name__ == "__main__":
    unittest.main()
