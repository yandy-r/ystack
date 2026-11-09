#!/usr/bin/env python3
"""Golden tests for scripts/generate_omp_agents.py."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_omp_agents as omp  # noqa: E402
from generate_codex_common import SRC_AGENTS_DIR, parse_frontmatter  # noqa: E402
from generate_omp_skills import OmpGenerationError, PathSentences, compare_trees  # noqa: E402

DEMO_AGENT = """\
---
name: demo-agent
description: Demo agent used by ycc:demo.
tools:
  - Read
  - Grep
  - WebFetch
  - Read
  - Bash(ls:*)
  - Bash(git -C * show:*)
  - Bash(ls:*)
  - WebSearch
  - NotebookEdit
  - Edit
  - mcp__context7__query-docs
model: opus
color: blue
---

You are the demo agent. Run /ycc:demo, then hand off to `ycc:helper-file`.
Search with WebSearch.
"""

HELPER_AGENT = """\
---
name: helper
description: Helper agent.
tools:
  - Read
  - Bash
  - Bash(git:*)
model: sonnet
---

Helper body.
"""


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


class FixtureTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.agents = self.root / "agents"
        self.skills = self.root / "skills"
        self.mcp = self.root / "mcp.json"
        self.dest = self.root / "out"
        write(self.agents / "demo-agent.md", DEMO_AGENT)
        # File stem differs from the frontmatter name, like turso-database-architect.
        write(self.agents / "helper-file.md", HELPER_AGENT)
        write(self.skills / "demo/SKILL.md", "---\nname: demo\ndescription: Demo.\n---\n")
        write(self.mcp, json.dumps({"mcpServers": {"context7": {"command": "npx"}}}))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def generate(self, dest: Path | None = None) -> set[Path]:
        return omp.write_tree(
            self.dest if dest is None else dest,
            dry_run=False,
            src_root=self.agents,
            skills_root=self.skills,
            mcp_path=self.mcp,
        )

    def output(self, stem: str) -> tuple[dict[str, object], str]:
        return parse_frontmatter((self.dest / f"{stem}.md").read_text(encoding="utf-8"))

    def assert_fails(self, text: str, *needles: str, stem: str = "demo-agent") -> None:
        write(self.agents / f"{stem}.md", text)
        with self.assertRaises(OmpGenerationError) as caught:
            self.generate()
        for needle in (f"agents/{stem}.md", *needles):
            self.assertIn(needle, str(caught.exception))


class FrontmatterTest(FixtureTestCase):
    def test_key_order_name_stem_and_color_dropped(self) -> None:
        written = self.generate()
        self.assertEqual(written, {Path("demo-agent.md"), Path("helper-file.md")})
        frontmatter, _ = self.output("demo-agent")
        self.assertEqual(list(frontmatter), ["name", "description", "tools", "model"])
        self.assertEqual(self.output("helper-file")[0]["name"], "helper")

    def test_tool_mapping_dedupes_in_first_seen_order_and_omits_mcp(self) -> None:
        self.generate()
        frontmatter, _ = self.output("demo-agent")
        self.assertEqual(frontmatter["tools"], ["read", "grep", "bash", "web_search", "edit"])

    def test_model_mapping(self) -> None:
        self.generate()
        self.assertEqual(self.output("demo-agent")[0]["model"], "@slow")
        self.assertEqual(self.output("helper-file")[0]["model"], "@task")

    def test_inherit_and_absent_model_emit_no_key(self) -> None:
        for model_line in ("model: inherit\n", ""):
            with self.subTest(model_line=model_line):
                write(self.agents / "helper-file.md", HELPER_AGENT.replace("model: sonnet\n", model_line))
                self.generate()
                self.assertNotIn("model", self.output("helper-file")[0])

    def test_description_namespace_rewritten(self) -> None:
        self.generate()
        self.assertEqual(self.output("demo-agent")[0]["description"], "Demo agent used by /skill:demo.")


class ShellScopeTest(FixtureTestCase):
    def test_scoped_bash_appends_deduped_prefix_section(self) -> None:
        self.generate()
        _, body = self.output("demo-agent")
        self.assertTrue(body.endswith(omp.shell_scope_section(["ls", "git -C * show"])))
        self.assertEqual(body.count(omp.SHELL_SCOPE_HEADING), 1)
        section = body[body.index(omp.SHELL_SCOPE_HEADING) :]
        bullets = [line[2:] for line in section.splitlines() if line.startswith("- ")]
        self.assertEqual(bullets, ["`ls`", "`git -C * show`"])

    def test_plain_bash_wins_over_scoped_forms(self) -> None:
        self.generate()
        frontmatter, body = self.output("helper-file")
        self.assertEqual(frontmatter["tools"], ["read", "bash"])
        self.assertNotIn(omp.SHELL_SCOPE_HEADING, body)
        self.assertEqual(body, "\nHelper body.\n")

    def test_no_tools_key_emits_no_tools_and_no_section(self) -> None:
        write(self.agents / "helper-file.md", HELPER_AGENT.replace("tools:\n  - Read\n  - Bash\n  - Bash(git:*)\n", ""))
        self.generate()
        frontmatter, body = self.output("helper-file")
        self.assertEqual(list(frontmatter), ["name", "description", "model"])
        self.assertNotIn(omp.SHELL_SCOPE_HEADING, body)

    def test_scope_data_is_the_source_of_the_prompt_section(self) -> None:
        self.generate()
        scopes = omp.agent_scopes(src_root=self.agents, mcp_path=self.mcp)
        self.assertEqual(
            scopes["demo-agent"],
            {"bash": ["ls", "git -C * show"], "mcp": [{"server": "context7", "tool": "query-docs"}]},
        )
        self.assertEqual(scopes["helper"], {"bash": None, "mcp": []})
        _, body = self.output("demo-agent")
        self.assertTrue(body.endswith(omp.shell_scope_section(scopes["demo-agent"]["bash"])))

    def test_no_tools_key_is_unrestricted_scope(self) -> None:
        write(self.agents / "helper-file.md", HELPER_AGENT.replace("tools:\n  - Read\n  - Bash\n  - Bash(git:*)\n", ""))
        scopes = omp.agent_scopes(src_root=self.agents, mcp_path=self.mcp)
        self.assertEqual(scopes["helper"], {"bash": None, "mcp": None})


class BodyTest(FixtureTestCase):
    def test_namespace_and_tool_wording_rewritten(self) -> None:
        self.generate()
        _, body = self.output("demo-agent")
        self.assertIn("Run /skill:demo, then hand off to `helper`.", body)
        self.assertIn("Search with `web_search`.", body)
        self.assertNotIn("ycc:", body)

    def render_body(self, body: str) -> str:
        write(self.agents / "helper-file.md", HELPER_AGENT.replace("Helper body.\n", body))
        self.generate()
        return self.output("helper-file")[1].removeprefix("\n")

    def test_claude_file_and_shell_tool_names_mapped(self) -> None:
        cases = (
            ("Use `Read` on the file, then `Edit`.\n", "Use `read` on the file, then `edit`.\n"),
            ("Inspect with Read, Grep, and Glob.\n", "Inspect with `read`, `grep`, and `glob`.\n"),
            ("Every Read / Write / Edit / Grep call.\n", "Every `read` / `write` / `edit` / `grep` call.\n"),
            ("Write it using the Write tool.\n", "Write it using the `write` tool.\n"),
            ("Modify files using Edit tools.\n", "Modify files using the `edit` tool.\n"),
            ("Run it via Bash. Do not use Write.\n", "Run it via `bash`. Do not use `write`.\n"),
            ("Use `Bash(git:*)` for history.\n", "Use `bash` (`git` commands) for history.\n"),
            ("Search with `Grep`,\n`Glob`, and Read.\n", "Search with `grep`,\n`glob`, and `read`.\n"),
            ("Write with the\nWrite tool.\n", "Write with the\n`write` tool.\n"),
            ("Inspect with Read,\nGrep, and Glob.\n", "Inspect with `read`,\n`grep`, and `glob`.\n"),
            ("Use NotebookEdit for cells.\n", "Use `edit` for cells.\n"),
        )
        for source, expected in cases:
            with self.subTest(source=source):
                self.assertEqual(self.render_body(source), expected)

    def test_english_and_code_left_verbatim(self) -> None:
        cases = (
            "Read the docs. Write clean code. Edit each conflict hunk.\n",
            "Use Read replicas for reporting queries.\n",
            "Grant Read and Write permissions on the bucket.\n",
            "Match files with filepath.Glob and the Grep-style matcher.\n",
            "Bash scripts must use strict mode.\n",
            "Implement `Write(p []byte)` and call `Read(buf)`.\n",
            "```go\nmatches, _ := filepath.Glob(pattern)\nfunc (w *W) Write(p []byte) (int, error)\nBash(ls)\n```\n",
        )
        for source in cases:
            with self.subTest(source=source):
                self.assertEqual(self.render_body(source), source)

    def test_lists_collapsing_onto_one_omp_tool_fail(self) -> None:
        for source in (
            "Use `Read` or `WebFetch`.\n",
            "Use `WebFetch` or `Read`.\n",
            "Use Read, then WebFetch\nor Read.\n",
        ):
            with self.subTest(source=source):
                self.assert_fails(DEMO_AGENT + source, "same OMP tool")

    def test_claude_tool_residue(self) -> None:
        flagged = ("Call TodoWrite now.", "Run Bash(ls) first.", "Ask with AskUserQuestion.", "Then `Grep`.")
        clean = (
            "Read the docs.",
            "Implement `Write(p []byte)`.",
            "Use `bash` (`git` commands).",
            "```\nTodoWrite\n```",
        )
        self.assertEqual(omp.claude_tool_residue("\n".join(flagged)), list(flagged))
        self.assertEqual(omp.claude_tool_residue("\n".join(clean)), [])

    def test_sentence_table_applied_and_stale_entry_fails(self) -> None:
        def generate(sentences: PathSentences) -> None:
            omp.write_tree(
                self.dest,
                dry_run=False,
                src_root=self.agents,
                skills_root=self.skills,
                mcp_path=self.mcp,
                sentences=sentences,
            )

        generate({"helper-file": (("Helper body.", "Rewritten body."),)})
        self.assertEqual(self.output("helper-file")[1], "\nRewritten body.\n")
        for stale in ({"helper-file": (("gone", "x"),)}, {"nobody": (("a", "b"),)}):
            with self.subTest(stale=stale), self.assertRaisesRegex(OmpGenerationError, "AGENT_SENTENCES"):
                generate(stale)

    def test_unknown_body_reference_fails(self) -> None:
        self.assert_fails(DEMO_AGENT.replace("/ycc:demo", "/ycc:nope"), "/ycc:nope")

    def test_unknown_description_reference_fails(self) -> None:
        self.assert_fails(DEMO_AGENT.replace("ycc:demo.", "ycc:nope."), "ycc:nope")

    def test_residual_plugin_root_fails(self) -> None:
        self.assert_fails(DEMO_AGENT + "Root is `${CLAUDE_PLUGIN_ROOT}`.\n", "CLAUDE_PLUGIN_ROOT")


class FailureTest(FixtureTestCase):
    def test_unknown_frontmatter_key(self) -> None:
        self.assert_fails(DEMO_AGENT.replace("color: blue\n", "color: blue\nisolation: worktree\n"), "isolation")

    def test_unknown_tool(self) -> None:
        self.assert_fails(DEMO_AGENT.replace("  - Edit\n", "  - TodoWrite\n"), "TodoWrite")

    def test_malformed_scoped_bash(self) -> None:
        self.assert_fails(DEMO_AGENT.replace("Bash(ls:*)", "Bash(ls)"), "Bash(ls)")

    def test_tools_must_be_a_list(self) -> None:
        text = DEMO_AGENT.split("tools:")[0] + "tools: Read, Grep\nmodel: opus\n---\nBody.\n"
        self.assert_fails(text, "tools")

    def test_unknown_model(self) -> None:
        for value in ("unmapped-alias", "'@slow'", "true"):
            with self.subTest(value=value):
                self.assert_fails(DEMO_AGENT.replace("model: opus", f"model: {value}"), "model")

    def test_mcp_server_absent_from_ycc_mcp(self) -> None:
        self.assert_fails(DEMO_AGENT.replace("mcp__context7__", "mcp__nowhere__"), "nowhere")

    def test_duplicate_agent_name(self) -> None:
        self.assert_fails(HELPER_AGENT, "duplicate agent name 'helper'", "helper-file.md", stem="zz-copy")

    def test_reserved_agent_name(self) -> None:
        self.assert_fails(HELPER_AGENT.replace("name: helper", "name: main"), "reserved", stem="helper-file")

    def test_bundled_agent_name_would_shadow(self) -> None:
        for name in sorted(omp.BUNDLED_AGENT_NAMES):
            with self.subTest(name=name):
                self.assert_fails(HELPER_AGENT.replace("name: helper", f"name: {name}"), name, stem="helper-file")

    def test_missing_description(self) -> None:
        self.assert_fails(DEMO_AGENT.replace("description: Demo agent used by ycc:demo.\n", ""), "description")

    def test_no_output_on_failure(self) -> None:
        write(self.agents / "bad.md", DEMO_AGENT.replace("model: opus", "model: unmapped-alias"))
        with self.assertRaises(OmpGenerationError):
            self.generate()
        self.assertFalse(self.dest.exists())


class TreeTest(FixtureTestCase):
    def test_idempotent_and_prunes_orphans(self) -> None:
        self.generate()
        before = {p: p.read_bytes() for p in self.dest.rglob("*")}
        write(self.dest / "stale.md", "stale\n")
        self.generate()
        self.assertEqual({p: p.read_bytes() for p in self.dest.rglob("*")}, before)

    def test_compare_trees_detects_drift(self) -> None:
        self.generate()
        fresh = self.root / "fresh"
        self.generate(fresh)
        self.assertEqual(compare_trees(fresh, self.dest), [])
        (self.dest / "helper-file.md").write_text("edited\n", encoding="utf-8")
        write(self.dest / "extra.md", "x\n")
        (fresh / "demo-agent.md").unlink()
        self.assertEqual(
            compare_trees(fresh, self.dest),
            ["extra in repo: demo-agent.md", "extra in repo: extra.md", "drift: helper-file.md"],
        )


class RealTreeTest(unittest.TestCase):
    def test_inventory_parity_and_unique_names(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            dest = Path(raw)
            written = omp.write_tree(dest, dry_run=False)
            sources = sorted(SRC_AGENTS_DIR.glob("*.md"))
            self.assertEqual(written, {Path(p.name) for p in sources})
            self.assertEqual({p.relative_to(dest) for p in dest.rglob("*")}, written)
            names: list[str] = []
            for source in sources:
                with self.subTest(agent=source.stem):
                    src_fm, _ = parse_frontmatter(source.read_text(encoding="utf-8"))
                    out_fm, _ = parse_frontmatter((dest / source.name).read_text(encoding="utf-8"))
                    self.assertEqual(out_fm["name"], src_fm["name"])
                    self.assertEqual(omp.MODEL_MAP.get(str(src_fm.get("model", "inherit"))), out_fm.get("model"))
                    self.assertTrue(set(out_fm.get("tools", [])) <= omp.OMP_TOOL_IDS)
                    names.append(str(out_fm["name"]))
            self.assertEqual(len(names), len(set(names)))

    def test_check_detects_drift_in_real_tree(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            dest = Path(raw)
            omp.write_tree(dest, dry_run=False)
            self.assertEqual(omp.run_check(dest), 0)
            target = dest / "planner.md"
            target.write_text(target.read_text(encoding="utf-8") + "drift\n", encoding="utf-8")
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(omp.run_check(dest), 1)
            self.assertIn("drift: planner.md", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
