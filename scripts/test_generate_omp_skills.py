#!/usr/bin/env python3
"""Golden tests for scripts/generate_omp_skills.py."""

from __future__ import annotations

import stat
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_omp_skills as omp  # noqa: E402
from generate_codex_common import VERBATIM_SKILL_FILES, parse_frontmatter  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent

# Fixture agents: file stem -> frontmatter name, as load_agent_aliases returns them.
ALIASES = {
    "implementor": "implementor",
    "code-researcher": "codebase-research-analyst",
    "codebase-research-analyst": "codebase-research-analyst",
    "releaser": "releaser",
}

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

Read `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/guide.md` first.
Then read `${CLAUDE_PLUGIN_ROOT}/skills/releaser/references/notes.md#cut`.
Run `${CLAUDE_PLUGIN_ROOT}/skills/demo/scripts/run.sh --x`.
Pattern `${CLAUDE_PLUGIN_ROOT}/skills/demo/scripts/<name>.sh` stays a pattern.
See [guide](../_shared/references/guide.md) and [deep](../../_shared/references/guide.md#top).
Run /ycc:releaser to cut, or ycc:demo for the demo.
Delegate to the `ycc:releaser` agent; dispatch `subagent_type: "ycc:code-researcher"`.
Use `subagent_type=ycc:implementor` and ycc:implementor directly.
Ask with `AskUserQuestion`, track with `TaskCreate`, `TaskUpdate`, and `TaskList`.
Use the Agent tool for one agent, or a single message with multiple `Agent` calls.
Search with WebSearch, then WebFetch.

<!-- ycc:verbatim-block:begin -->
Keep /ycc:releaser and ${CLAUDE_PLUGIN_ROOT}/skills/nowhere here.
<!-- ycc:verbatim-block:end -->
"""

RUN_SH = """\
#!/usr/bin/env bash
# Rules: ${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/guide.md#rules
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB="${SCRIPT_DIR}/../../_shared/scripts/lib.sh"
[[ -f "$LIB" ]] || LIB="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/lib.sh"
echo 'run /ycc:releaser next'
"""

VERBATIM_TEXT = "Matrix: `${CLAUDE_PLUGIN_ROOT}` and `/ycc:<name>` stay literal.\n"


def write(path: Path, text: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(mode)


def build_fixture(root: Path) -> Path:
    src = root / "skills"
    write(src / "demo/SKILL.md", DEMO_SKILL)
    write(src / "demo/scripts/run.sh", RUN_SH, 0o755)
    write(src / "releaser/SKILL.md", "---\nname: releaser\ndescription: Releaser.\n---\n\nBody.\n")
    write(src / "releaser/references/notes.md", "Notes.\n")
    write(src / "_shared/references/guide.md", "Guide.\n")
    write(src / "_shared/references/agent-team-dispatch.md", "Long team contract with TeamCreate.\n")
    write(src / "_shared/references/target-capability-matrix.md", VERBATIM_TEXT)
    write(src / "_shared/scripts/lib.sh", "#!/usr/bin/env bash\n", 0o755)
    write(
        src / "bundle-author/references/surface-map.md",
        "Author helpers as `${CLAUDE_PLUGIN_ROOT}/skills/<kebab-name>/scripts/<name>.sh`.\n",
    )
    write(src / "bundle-author/SKILL.md", "---\nname: bundle-author\ndescription: Author.\n---\n\nBody.\n")
    return src


class FixtureTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.src = build_fixture(self.root)
        self.dest = self.root / "out"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def generate(self) -> set[Path]:
        return omp.write_tree(self.dest, dry_run=False, src_root=self.src, aliases=ALIASES)

    def read(self, rel: str) -> str:
        return (self.dest / rel).read_text(encoding="utf-8")

    def assert_fails(self, rel: str, text: str, *needles: str) -> None:
        write(self.src / rel, text)
        with self.assertRaises(omp.OmpGenerationError) as caught:
            self.generate()
        for needle in (rel, *needles):
            self.assertIn(needle, str(caught.exception))


class PathRewriteTest(FixtureTestCase):
    def test_shared_sibling_and_relative_links(self) -> None:
        self.generate()
        body = self.read("demo/SKILL.md")
        self.assertIn("Read `skill://ycc-shared/references/guide.md` first.", body)
        self.assertIn("`skill://releaser/references/notes.md#cut`", body)
        self.assertIn("`skill://demo/scripts/run.sh --x`", body)
        self.assertIn("`skill://demo/scripts/<name>.sh` stays a pattern", body)
        self.assertIn(
            "[guide](skill://ycc-shared/references/guide.md) and [deep](skill://ycc-shared/references/guide.md#top)",
            body,
        )

    def test_script_fallback_collapses_to_relative_primary_and_comments_use_urls(self) -> None:
        self.generate()
        script = self.read("demo/scripts/run.sh")
        # The fallback would repeat the script-relative primary, so it is dropped as dead code.
        self.assertIn('LIB="${SCRIPT_DIR}/../../_shared/scripts/lib.sh"\necho', script)
        self.assertNotIn("|| LIB=", script)
        self.assertIn("# Rules: skill://ycc-shared/references/guide.md#rules", script)
        self.assertIn("echo 'run /skill:releaser next'", script)
        self.assertNotIn("CLAUDE_PLUGIN_ROOT", script)


class RepositoryLayoutTest(FixtureTestCase):
    def test_source_authoring_guidance_keeps_plugin_root(self) -> None:
        self.generate()
        self.assertIn("bundle-author/references/surface-map.md", omp.REPOSITORY_LAYOUT_FILES)
        self.assertEqual(
            self.read("bundle-author/references/surface-map.md"),
            "Author helpers as `${CLAUDE_PLUGIN_ROOT}/skills/<kebab-name>/scripts/<name>.sh`.\n",
        )

    def test_real_source_authoring_files_keep_plugin_root(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            dest = Path(raw)
            omp.write_tree(dest, dry_run=False)
            for rel in sorted(omp.REPOSITORY_LAYOUT_FILES):
                with self.subTest(rel=rel):
                    text = (dest / rel).read_text(encoding="utf-8")
                    self.assertIn("${CLAUDE_PLUGIN_ROOT}/skills/", text)
                    self.assertNotIn("skill://", text)


class PathSentenceTest(FixtureTestCase):
    def test_sentence_rewritten_in_listed_file(self) -> None:
        write(self.src / "demo/references/p.md", "Track via `TaskList` (Path B).\n")
        sentences = {"demo/references/p.md": (("via `TaskList` (Path B)", "via `todo` (Path B lists tasks)"),)}
        omp.write_tree(self.dest, dry_run=False, src_root=self.src, aliases=ALIASES, path_sentences=sentences)
        self.assertEqual(self.read("demo/references/p.md"), "Track via `todo` (Path B lists tasks).\n")

    def test_stale_sentence_fails(self) -> None:
        write(self.src / "demo/references/p.md", "Reworded source.\n")
        sentences = {"demo/references/p.md": (("via `TaskList` (Path B)", "x"),)}
        with self.assertRaisesRegex(omp.OmpGenerationError, r"demo/references/p\.md: PATH_TOOL_SENTENCES"):
            omp.write_tree(self.dest, dry_run=False, src_root=self.src, aliases=ALIASES, path_sentences=sentences)

    def test_missing_listed_file_fails(self) -> None:
        sentences = {"demo/references/gone.md": (("a", "b"),)}
        with self.assertRaisesRegex(omp.OmpGenerationError, r"demo/references/gone\.md: listed"):
            omp.write_tree(self.dest, dry_run=False, src_root=self.src, aliases=ALIASES, path_sentences=sentences)

    def test_real_sentences_all_match(self) -> None:
        for rel, entries in omp.PATH_TOOL_SENTENCES.items():
            text = (omp.SRC_DIR / rel).read_text(encoding="utf-8")
            for source, _ in entries:
                with self.subTest(rel=rel, source=source):
                    self.assertIn(source, text)


class NamespaceTest(FixtureTestCase):
    def test_managed_block_marker_takes_bare_name(self) -> None:
        write(self.src / "demo/scripts/m.sh", "# --- ycc:demo managed block (do not edit) ---\n")
        self.generate()
        self.assertEqual(self.read("demo/scripts/m.sh"), "# --- demo managed block (do not edit) ---\n")

    def test_unknown_managed_block_marker_fails(self) -> None:
        self.assert_fails("demo/scripts/m.sh", "# --- ycc:nope managed block ---\n", "ycc:nope")

    def test_skill_and_agent_mapping_including_overlap(self) -> None:
        self.generate()
        body = self.read("demo/SKILL.md")
        self.assertIn("Run /skill:releaser to cut, or /skill:demo for the demo.", body)
        # `releaser` is both a skill and an agent: agent context wins.
        self.assertIn("Delegate to the `releaser` agent", body)
        # Agent references resolve through frontmatter names, not file stems.
        self.assertIn('`agent: "codebase-research-analyst"`', body)
        self.assertIn("`agent=implementor` and implementor directly.", body)

    def test_protected_block_untouched_and_marker_stripped(self) -> None:
        self.generate()
        body = self.read("demo/SKILL.md")
        self.assertIn("Keep /ycc:releaser and ${CLAUDE_PLUGIN_ROOT}/skills/nowhere here.\n", body)
        self.assertNotIn("ycc:verbatim-block", body)

    def test_tool_wording(self) -> None:
        self.generate()
        body = self.read("demo/SKILL.md")
        self.assertIn("Ask with `ask`, track with `todo`.", body)
        self.assertIn("Use the `task` tool for one agent, or a single message with multiple `task` calls.", body)
        self.assertIn("Search with `web_search`, then `read` (URL).", body)

    def test_tool_wording_in_code_never_nests_backticks(self) -> None:
        source = (
            'Wire with `TaskUpdate(taskId="<id>", addBlockedBy=["<dep>"])`.\n'
            "Dispatch via `Agent` or `Agent(name=...)`.\n"
            "```text\n"
            'TaskCreate: subject="1.1", description="Agent: <type>"\n'
            'Agent(subagent_type="planner")\n'
            "```\n"
        )
        expected = (
            'Wire with `todo(taskId="<id>", addBlockedBy=["<dep>"])`.\n'
            "Dispatch via `task` or `task(name=...)`.\n"
            "```text\n"
            'todo: subject="1.1", description="Agent: <type>"\n'
            'task(subagent_type="planner")\n'
            "```\n"
        )
        self.assertEqual(omp.rewrite_tool_wording(source), expected)

    def test_task_tool_wording_in_fenced_code(self) -> None:
        source = "```\n[Single message with 3 Agent tool calls]\n```\n"
        self.assertEqual(omp.rewrite_tool_wording(source), "```\n[Single message with 3 task tool calls]\n```\n")

    def test_todo_lists_keep_their_conjunctions(self) -> None:
        cases = (
            (
                "If you lack `SendMessage`, `TaskUpdate`, or `TaskList`, ignore this.",
                "If you lack `SendMessage` or `todo`, ignore this.",
            ),
            ("Inspect with `TaskList` or `TaskGet`.", "Inspect with `todo`."),
            ("Strip the `SendMessage`/`TaskList`/`TaskUpdate` lines.", "Strip the `SendMessage`/`todo` lines."),
            ("Track with `TaskCreate`, `TaskGet`,\n`TaskList`, and `TaskUpdate`.", "Track with `todo`."),
        )
        for source, expected in cases:
            with self.subTest(source=source):
                self.assertEqual(omp.rewrite_tool_wording(source), expected)

    def test_team_dispatch_becomes_unsupported_note(self) -> None:
        self.generate()
        note = self.read("_shared/references/agent-team-dispatch.md")
        self.assertIn("`--team`", note)
        self.assertIn("unsupported", note)
        self.assertNotIn("TeamCreate", note)


class TreeTest(FixtureTestCase):
    def test_executable_bit_preserved(self) -> None:
        self.generate()
        for rel in ("demo/scripts/run.sh", "_shared/scripts/lib.sh"):
            self.assertTrue((self.dest / rel).stat().st_mode & stat.S_IXUSR, rel)
        self.assertFalse((self.dest / "demo/SKILL.md").stat().st_mode & stat.S_IXUSR)

    def test_manual_only_kept_and_allowed_tools_dropped(self) -> None:
        self.generate()
        frontmatter, _ = parse_frontmatter(self.read("demo/SKILL.md"))
        self.assertEqual(list(frontmatter), ["name", "description", "argument-hint", "disable-model-invocation"])
        self.assertIs(frontmatter["disable-model-invocation"], True)
        self.assertNotIn("disable-model-invocation", parse_frontmatter(self.read("releaser/SKILL.md"))[0])

    def test_shared_stub_shape(self) -> None:
        written = self.generate()
        self.assertIn(Path("_shared/SKILL.md"), written)
        frontmatter, body = parse_frontmatter(self.read("_shared/SKILL.md"))
        self.assertEqual(frontmatter["name"], "ycc-shared")
        self.assertIs(frontmatter["hide"], True)
        self.assertIs(frontmatter["disable-model-invocation"], True)
        self.assertTrue(frontmatter["description"])
        self.assertIn("skill://ycc-shared/", body)

    def test_source_shared_stub_rejected(self) -> None:
        self.assert_fails("_shared/SKILL.md", "---\nname: x\ndescription: x\n---\n", "ycc-shared")

    def test_verbatim_files_copied_byte_for_byte(self) -> None:
        self.generate()
        self.assertEqual(self.read("_shared/references/target-capability-matrix.md"), VERBATIM_TEXT)

    def test_idempotent_check_and_prune(self) -> None:
        self.generate()
        before = {p: p.read_bytes() for p in self.dest.rglob("*") if p.is_file()}
        write(self.dest / "stale/old.md", "stale\n")
        self.generate()
        self.assertFalse((self.dest / "stale").exists())
        self.assertEqual({p: p.read_bytes() for p in self.dest.rglob("*") if p.is_file()}, before)

    def test_compare_trees_detects_content_and_mode_drift(self) -> None:
        self.generate()
        fresh = self.root / "fresh"
        omp.write_tree(fresh, dry_run=False, src_root=self.src, aliases=ALIASES)
        self.assertEqual(omp.compare_trees(fresh, self.dest), [])
        (self.dest / "demo/scripts/run.sh").chmod(0o644)
        self.assertEqual(omp.compare_trees(fresh, self.dest), ["mode drift: demo/scripts/run.sh"])
        (self.dest / "demo/scripts/run.sh").chmod(0o755)
        (self.dest / "releaser/SKILL.md").write_text("edited\n", encoding="utf-8")
        self.assertEqual(omp.compare_trees(fresh, self.dest), ["drift: releaser/SKILL.md"])


class MissingReferenceTest(FixtureTestCase):
    def test_unknown_slash_reference(self) -> None:
        self.assert_fails("demo/references/a.md", "Run /ycc:nope now.\n", "/ycc:nope")

    def test_unknown_bare_reference(self) -> None:
        self.assert_fails("demo/references/a.md", "Run ycc:nope now.\n", "ycc:nope")

    def test_unknown_subagent_reference(self) -> None:
        self.assert_fails("demo/references/a.md", '`subagent_type: "ycc:demo"`\n', "ycc:demo")

    def test_missing_plugin_path(self) -> None:
        ref = "${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/missing.md"
        self.assert_fails("demo/references/a.md", f"Read `{ref}`.\n", ref)

    def test_plugin_path_outside_skills(self) -> None:
        ref = "${CLAUDE_PLUGIN_ROOT}/skills/nowhere/x.md"
        self.assert_fails("demo/references/a.md", f"Read `{ref}`.\n", ref)

    def test_missing_relative_shared_link(self) -> None:
        self.assert_fails("demo/references/a.md", "[x](../../_shared/missing.md)\n", "_shared/missing.md")

    def test_unknown_agent_suffix_falls_back_to_skill_lookup(self) -> None:
        self.assert_fails("demo/references/a.md", "Ask the `ycc:nope` agent.\n", "ycc:nope")

    def test_script_fallback_without_script_dir_fails(self) -> None:
        ref = '"${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/lib.sh"'
        self.assert_fails("demo/scripts/b.sh", f"LIB={ref}\n", "SCRIPT_DIR")

    def test_missing_script_fallback_target(self) -> None:
        ref = "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/missing.sh"
        script = f'SCRIPT_DIR="$(pwd)"\nLIB="{ref}"\n'
        self.assert_fails("demo/scripts/b.sh", script, ref)

    def test_residual_plugin_root_in_markdown(self) -> None:
        self.assert_fails("demo/references/a.md", "Root is `${CLAUDE_PLUGIN_ROOT}`.\n", "CLAUDE_PLUGIN_ROOT")

    def test_residual_plugin_root_in_script_code(self) -> None:
        self.assert_fails("demo/scripts/b.sh", 'cd "${CLAUDE_PLUGIN_ROOT}"\n', "CLAUDE_PLUGIN_ROOT")

    def test_non_boolean_model_invocation_flag(self) -> None:
        for value in ('"true"', "1", "null"):
            with self.subTest(value=value):
                skill = f"---\nname: demo\ndescription: d\ndisable-model-invocation: {value}\n---\n"
                write(self.src / "demo/SKILL.md", skill)
                with self.assertRaisesRegex(ValueError, "disable-model-invocation"):
                    self.generate()


WORKTREE_PATHS_SH = """\
#!/usr/bin/env bash
ycc_expand_worktree_root() {
  printf '%s/.claude/worktrees\\n' "$repo_root" # @YCC_DEFAULT_WORKTREE_ROOT@
}
"""


class WorktreeRootTest(FixtureTestCase):
    def test_markdown_and_script_roots_rewritten(self) -> None:
        write(self.src / "demo/references/w.md", "Parent: `<repo-root>/.claude/worktrees/<repo>-<f>/`.\n")
        write(self.src / "demo/scripts/w.sh", "# under <repo-root>/.claude/worktrees/<repo>-<f>/\n", 0o755)
        self.generate()
        self.assertEqual(self.read("demo/references/w.md"), "Parent: `<repo-root>/.omp/worktrees/<repo>-<f>/`.\n")
        self.assertEqual(self.read("demo/scripts/w.sh"), "# under <repo-root>/.omp/worktrees/<repo>-<f>/\n")

    def test_marker_line_emits_omp_root(self) -> None:
        write(self.src / "_shared/scripts/worktree-paths.sh", WORKTREE_PATHS_SH, 0o755)
        self.generate()
        script = self.read("_shared/scripts/worktree-paths.sh")
        self.assertIn("printf '%s/.omp/worktrees\\n' \"$repo_root\" # @YCC_DEFAULT_WORKTREE_ROOT@", script)
        self.assertNotIn(".claude/worktrees", script)

    def test_verbatim_block_keeps_claude_root(self) -> None:
        row = "| Claude Code | `<repo-root>/.claude/worktrees/` | source default |\n"
        source = (
            "Root: `<repo-root>/.claude/worktrees/`.\n"
            "<!-- ycc:verbatim-block:begin -->\n" + row + "<!-- ycc:verbatim-block:end -->\n"
        )
        write(self.src / "demo/references/w.md", source)
        self.generate()
        self.assertEqual(self.read("demo/references/w.md"), "Root: `<repo-root>/.omp/worktrees/`.\n" + row)

    def test_real_worktree_paths_marker_emits_omp(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            dest = Path(raw)
            omp.write_tree(dest, dry_run=False)
            script = (dest / "_shared/scripts/worktree-paths.sh").read_text(encoding="utf-8")
            self.assertIn("printf '%s/.omp/worktrees\\n' \"$repo_root\" # @YCC_DEFAULT_WORKTREE_ROOT@", script)
            strategy = (dest / "_shared/references/worktree-strategy.md").read_text(encoding="utf-8")
            self.assertIn("| Claude Code | `<repo-root>/.claude/worktrees/`", strategy)
            self.assertIn("| OMP         | `<repo-root>/.omp/worktrees/`", strategy)


class DispatchWordingTest(unittest.TestCase):
    def test_vocabulary(self) -> None:
        cases = (
            ('`subagent_type: "planner"`', '`agent: "planner"`'),
            ("- a  subagent_type=implementor  task=<short>", "- a  agent=implementor  task=<short>"),
            ("| name | `subagent_type` |", "| name | `agent` |"),
            ('Never pass `isolation: "worktree"`.', "Never pass `isolated: true`."),
            ('`Agent(isolation="worktree")`', "`Agent(isolated: true)`"),
            ("worktree isolation is on by default", "worktree isolation is on by default"),
        )
        for source, expected in cases:
            with self.subTest(source=source):
                self.assertEqual(omp.rewrite_dispatch_wording(source), expected)

    def test_dispatch_fields_become_task_items(self) -> None:
        shape = "how open-ended the work is (item shape: `skill://ycc-shared/references/standalone-dispatch.md` §1)"
        cases = (
            (
                'Deploy with:\n- `subagent_type`: `implementor`\n- `description`: "Fix F1"\n- `prompt`: The spec\n',
                'Deploy with:\n- `agent`: `implementor`\n- `name`: CamelCase label for "Fix F1"\n'
                f"- `task`: The spec\n- `solutionSpace`: {shape}\n",
            ),
            (
                "- `name`: `f042`\n- `subagent_type`: `fixer`\n- `description`: One-line title\n- `prompt`: Spec",
                f"- `name`: `f042`\n- `agent`: `fixer`\n- `task`: Spec\n- `solutionSpace`: {shape}",
            ),
            (
                '| subagent_type | `committer` |\n| description   | "Commit" |\n| prompt        | Steps |\n',
                f'| agent | `committer` |\n| name | CamelCase label for "Commit" |\n| task | Steps |\n'
                f"| solutionSpace | {shape} |\n",
            ),
            (
                'Agent(\n  subagent_type = "planner",\n  description = "Plan auth",\n  prompt = "Do it"\n)\n',
                'Agent(\n  agent = "planner",\n  name = "<CamelCase label for Plan auth>",\n'
                '  task = "Do it",\n  solutionSpace = "<how open-ended>"\n)\n',
            ),
            (
                'Use `subagent_type="impl"`, `description="<title>"`, `prompt="<spec>"`.',
                'Use `agent="impl"`, `name` (CamelCase label for <title>), '
                '`task="<spec>"`, `solutionSpace="<how open-ended>"`.',
            ),
            (
                "Uses `subagent_type` with `description` set to the role and the `prompt` copied.",
                "Uses `agent` with `name` set to the role and the `task` copied.",
            ),
        )
        for source, expected in cases:
            with self.subTest(source=source[:40]):
                self.assertEqual(omp.rewrite_dispatch_wording(source), expected)

    def test_omit_name_rules_dropped(self) -> None:
        cases = (
            (
                "Uses `subagent_type: x`, distinguished by `description` and the prompt "
                "(omit `name` for standalone calls).",
                "Uses `agent: x`, distinguished by `name` and the prompt.",
            ),
            (
                "See the `Agent` spawn/return contract (omit `name` for standalone dispatch).",
                "See the `Agent` spawn/return contract.",
            ),
            ("using the **`Agent`** tool (omit `name`):", "using the **`Agent`** tool:"),
            (
                "SEVEN `Agent` tool calls** (standalone — no `name`). Wait.",
                "SEVEN `Agent` tool calls** (standalone). Wait.",
            ),
            (
                "MULTIPLE calls**. No `name` — standalone dispatch. Each call",
                "MULTIPLE calls**. Standalone dispatch. Each call",
            ),
            ("MULTIPLE calls**. No `name`. Each call", "MULTIPLE calls**. Each call"),
            (
                "If it spawns a teammate without `name`, it's a bug.",
                "If it spawns a teammate without `name`, it's a bug.",
            ),
        )
        for source, expected in cases:
            with self.subTest(source=source[:40]):
                self.assertEqual(omp.rewrite_dispatch_wording(source), expected)

    def test_non_dispatch_description_and_prompt_untouched(self) -> None:
        cases = (
            "Findings:\n\n- `id`\n- `description`\n- `status`\n",
            '---\nname: x\ndescription: "Demo"\n---\n',
            'todo: subject="1.1", description="<full spec>"\n',
            "Frontmatter keeps `name` and `description`; the `prompt` field is dropped.\n",
            "Use `subagent_type`.\n\n- `description`: unrelated list in the next paragraph\n",
        )
        for source in cases:
            with self.subTest(source=source[:40]):
                self.assertEqual(omp.rewrite_dispatch_wording(source), source.replace("subagent_type", "agent"))

    def test_team_advisories_name_omp(self) -> None:
        cases = (
            ("Cursor and Codex bundles lack team tools.", "Cursor, Codex and OMP bundles lack team tools."),
            ("From a Cursor or Codex bundle, `--team` aborts.", "From a Cursor, Codex or OMP bundle, `--team` aborts."),
            ("- `--team` in Cursor/Codex bundles: no.", "- `--team` in Cursor/Codex/OMP bundles: no."),
            ("Hook events on Cursor or Codex differ.", "Hook events on Cursor or Codex differ."),
        )
        for source, expected in cases:
            with self.subTest(source=source):
                self.assertEqual(omp.rewrite_team_advisories(source), expected)
        self.assertEqual(omp.rewrite_team_advisories(cases[0][1]), cases[0][1])

    def test_dispatch_sentence_rewritten_before_tool_mapping(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            src = build_fixture(root)
            write(src / "demo/references/d.md", "Dispatch without `name` or `run_in_background`.\n")
            table = {"demo/references/d.md": (("without `name` or `run_in_background`", "in one `task` batch"),)}
            omp.write_tree(root / "out", dry_run=False, src_root=src, aliases=ALIASES, dispatch_sentences=table)
            text = (root / "out/demo/references/d.md").read_text(encoding="utf-8")
            self.assertEqual(text, "Dispatch in one `task` batch.\n")

    def test_stale_dispatch_sentence_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            src = build_fixture(root)
            write(src / "demo/references/d.md", "Reworded.\n")
            table = {"demo/references/d.md": (("end the turn", "call `wait`"),)}
            with self.assertRaisesRegex(omp.OmpGenerationError, r"demo/references/d\.md: OMP_DISPATCH_SENTENCES"):
                omp.write_tree(root / "out", dry_run=False, src_root=src, aliases=ALIASES, dispatch_sentences=table)

    def test_real_dispatch_sentences_all_match(self) -> None:
        for rel, entries in omp.OMP_DISPATCH_SENTENCES.items():
            text = (omp.SRC_DIR / rel).read_text(encoding="utf-8")
            for source, _ in entries:
                with self.subTest(rel=rel, source=source[:60]):
                    self.assertIn(source, text)


CANONICAL_DISPATCH = "".join(f"## {n}. Section {n}\n\nBody {n}.\n\n---\n\n" for n in range(1, 11))


class StandaloneDispatchRenderTest(unittest.TestCase):
    def write_template(self, root: Path, numbers: range) -> Path:
        template = root / "standalone-dispatch.md"
        body = "# OMP\n\nIntro.\n\n" + "".join(f"## {n}. T{n}\n\nTemplate {n}.\n\n---\n\n" for n in numbers)
        write(template, body)
        return template

    def test_template_head_and_canonical_tail(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            template = self.write_template(Path(raw), range(1, 8))
            rendered = omp.render_omp_standalone_dispatch(CANONICAL_DISPATCH, template)
        for number in range(1, 8):
            self.assertIn(f"## {number}. T{number}\n", rendered)
            self.assertNotIn(f"Body {number}.", rendered)
        for number in (8, 9, 10):
            self.assertIn(f"## {number}. Section {number}\n\nBody {number}.", rendered)
        self.assertTrue(rendered.startswith("# OMP\n\nIntro.\n"))
        self.assertTrue(rendered.endswith("Body 10.\n"))

    def test_missing_template_section_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            template = self.write_template(Path(raw), range(1, 7))
            with self.assertRaisesRegex(omp.OmpGenerationError, r"missing sections \[7\]"):
                omp.render_omp_standalone_dispatch(CANONICAL_DISPATCH, template)

    def test_extra_template_section_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            template = self.write_template(Path(raw), range(1, 9))
            with self.assertRaisesRegex(omp.OmpGenerationError, "exactly sections 1-7"):
                omp.render_omp_standalone_dispatch(CANONICAL_DISPATCH, template)

    def test_missing_canonical_section_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            template = self.write_template(Path(raw), range(1, 8))
            source = CANONICAL_DISPATCH.replace("## 9. Section 9", "## Nine")
            with self.assertRaisesRegex(omp.OmpGenerationError, r"missing sections \[9\]"):
                omp.render_omp_standalone_dispatch(source, template)

    def test_real_reference_is_omp_native(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            dest = Path(raw)
            omp.write_tree(dest, dry_run=False)
            text = (dest / omp.STANDALONE_DISPATCH_REL).read_text(encoding="utf-8")
        for number in range(1, 11):
            self.assertRegex(text, rf"(?m)^## {number}\. ")
        for needle in ("tasks: [", "solutionSpace", "`wait`", "agent://<id>", "Never set `isolated`", "task.batch"):
            self.assertIn(needle, text)
        self.assertIn("<repo-root>/.omp/worktrees/", text)
        self.assertNotIn("isolated: true", text)
        self.assertIsNone(omp.FORBIDDEN_SEMANTICS.search(text))


class ForbiddenSemanticsTest(unittest.TestCase):
    def test_scan_flags_leaks_and_honors_allowlist(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            package = Path(raw)
            write(package / "skills/demo/SKILL.md", "Use `subagent_type`.\nOK line.\n")
            write(package / "agents/a.md", "Ask with AskUserQuestion.\n")
            write(package / "skills/_shared/references/target-capability-matrix.md", "`run_in_background`\n")
            write(
                package / "skills/_shared/references/worktree-strategy.md",
                "| Claude Code | `<repo-root>/.claude/worktrees/`      | source default (`worktree-paths.sh`)      |\n"
                "Leaked `<repo-root>/.claude/worktrees/` prose.\n",
            )
            findings = omp.scan_forbidden_semantics(package)
        self.assertEqual(
            findings,
            [
                "agents/a.md:1: Ask with AskUserQuestion.",
                "skills/_shared/references/worktree-strategy.md:2: Leaked `<repo-root>/.claude/worktrees/` prose.",
                "skills/demo/SKILL.md:1: Use `subagent_type`.",
            ],
        )

    def test_isolation_spacing_variants_flagged(self) -> None:
        for line in ('isolation: "worktree"', 'isolation:"worktree"', 'isolation="worktree"', 'isolation = "worktree"'):
            with self.subTest(line=line):
                self.assertIsNotNone(omp.FORBIDDEN_SEMANTICS.search(line))

    def test_scan_flags_claude_dispatch_fields_next_to_agent(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            package = Path(raw)
            write(
                package / "skills/demo/SKILL.md",
                "- `agent`: `fixer`\n- `prompt`: Spec\n\n"
                'Call `agent="impl"`, `description="<t>"`.\n\n'
                "| agent | `x` |\n| description | y |\n\n"
                "Findings: `id`, `description`.\n\n"
                'todo: subject="1", description="spec"\n',
            )
            write(package / "skills/demo/run.sh", 'agent=x\nprompt="y"\n')
            findings = omp.scan_forbidden_semantics(package)
        self.assertEqual(
            [finding.split(": Claude")[0] for finding in findings],
            ["skills/demo/SKILL.md:2", "skills/demo/SKILL.md:4", "skills/demo/SKILL.md:7"],
        )

    def test_scan_flags_omit_name_next_to_omp_dispatch(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            package = Path(raw)
            write(
                package / "skills/demo/SKILL.md",
                "Dispatch via the `task` tool (omit `name`).\n\n"
                "Each item sets `agent: x`; no `name` here.\n\n"
                "A teammate without `name` is a bug.\n",
            )
            findings = omp.scan_forbidden_semantics(package)
        self.assertEqual(
            [finding.split(": omit")[0] for finding in findings],
            ["skills/demo/SKILL.md:1", "skills/demo/SKILL.md:3"],
        )

    def test_real_generated_skills_are_clean(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            package = Path(raw)
            omp.write_tree(package / "skills", dry_run=False)
            self.assertEqual(omp.scan_forbidden_semantics(package), [])


class RealTreeTest(unittest.TestCase):
    def test_inventory_parity_exactly_once(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            dest = Path(raw)
            written = omp.write_tree(dest, dry_run=False)
            source_files = {p.relative_to(omp.SRC_DIR) for p in omp.SRC_DIR.rglob("*") if p.is_file()}
            self.assertEqual(written, source_files | {omp.SHARED_STUB_REL})
            source_skills = {p.parent.name for p in omp.SRC_DIR.glob("*/SKILL.md")}
            generated = {p.parent.name for p in dest.glob("*/SKILL.md")}
            self.assertEqual(generated, source_skills | {"_shared"})
            for skill in sorted(source_skills):
                with self.subTest(skill=skill):
                    frontmatter, _ = parse_frontmatter((dest / skill / "SKILL.md").read_text(encoding="utf-8"))
                    self.assertEqual(frontmatter["name"], skill)
            names = [parse_frontmatter(p.read_text(encoding="utf-8"))[0]["name"] for p in dest.glob("*/SKILL.md")]
            self.assertEqual(len(names), len(set(names)))
            self.assertIn("ycc-shared", names)

    def test_manual_only_policy_matches_source(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            dest = Path(raw)
            omp.write_tree(dest, dry_run=False)
            for source in sorted(omp.SRC_DIR.glob("*/SKILL.md")):
                with self.subTest(skill=source.parent.name):
                    src_fm, _ = parse_frontmatter(source.read_text(encoding="utf-8"))
                    out = dest / source.relative_to(omp.SRC_DIR)
                    out_fm, _ = parse_frontmatter(out.read_text(encoding="utf-8"))
                    self.assertEqual(
                        out_fm.get("disable-model-invocation", False), src_fm.get("disable-model-invocation", False)
                    )
                    self.assertNotIn("allowed-tools", out_fm)

    def test_verbatim_files_exist(self) -> None:
        for rel in VERBATIM_SKILL_FILES:
            self.assertTrue((omp.SRC_DIR / rel).is_file(), rel)


if __name__ == "__main__":
    unittest.main()
