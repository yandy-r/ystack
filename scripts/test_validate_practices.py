#!/usr/bin/env python3
"""Unit tests for scripts/validate_practices.py using temporary fixture roots."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validate_practices as vp  # noqa: E402

GOOD_DESC = "Fix things. Use when the user asks to fix something."
MCP_JSON = {"mcpServers": {"github": {"type": "http"}, "linear-team": {"type": "http"}}}


def write_skill(root: Path, text: str, name: str = "demo") -> Path:
    d = root / "ycc" / "skills" / name
    d.mkdir(parents=True, exist_ok=True)
    p = d / "SKILL.md"
    p.write_text(text, encoding="utf-8")
    return p


def base_fixture(root: Path) -> None:
    (root / "mcp-configs").mkdir(parents=True)
    (root / "mcp-configs" / "mcp.json").write_text(json.dumps(MCP_JSON))
    (root / "CLAUDE.md").write_text("@AGENTS.md\n\n# doc\n")
    (root / "AGENTS.md").write_text("# doc\n")
    (root / "ycc" / "settings" / "rules").mkdir(parents=True)
    (root / "ycc" / "settings" / "rules" / "CLAUDE.md").write_text("# rules\n")
    (root / "ycc" / "agents").mkdir(parents=True)
    (root / "ycc" / "skills").mkdir(parents=True)


def sk(
    name: str = "demo",
    desc: str = GOOD_DESC,
    allowed: list[str] | str | None = None,
    extra_fm: list[str] | None = None,
    body: str = "# Demo\n",
) -> str:
    lines = ["---", f"name: {name}", f"description: {json.dumps(desc)}"]
    if extra_fm:
        lines.extend(extra_fm)
    if isinstance(allowed, list):
        lines.append("allowed-tools:")
        lines.extend(f"  - {json.dumps(t)}" for t in allowed)
    elif isinstance(allowed, str):
        lines.append(f"allowed-tools: {json.dumps(allowed)}")
    lines.extend(["---", "", body])
    return "\n".join(lines) + "\n"


def ag(name: str = "helper", extra_fm: list[str] | None = None, tools: list[str] | str | None = None) -> str:
    lines = ["---", f"name: {name}", "description: 'Does things.'"]
    if extra_fm:
        lines.extend(extra_fm)
    if isinstance(tools, list):
        lines.append("tools:")
        lines.extend(f"  - {json.dumps(t)}" for t in tools)
    elif isinstance(tools, str):
        lines.append(f"tools: {json.dumps(tools)}")
    lines.extend(["---", "", "Body."])
    return "\n".join(lines) + "\n"


def ids(rep: vp.Report, rule: str) -> set[str]:
    return {v.vid for v in rep.violations if v.rule == rule}


def run_ratchet(rep: vp.Report, baseline: dict[str, dict[str, Any]]) -> int:
    with contextlib.redirect_stdout(io.StringIO()):
        return vp.ratchet(rep, baseline)


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="ycc-practices-")
        self.root = Path(self.tmp.name)
        base_fixture(self.root)
        self.addCleanup(self.tmp.cleanup)

    def rep(self) -> vp.Report:
        return vp.collect(self.root)

    def baseline(self, rep: vp.Report | None = None) -> dict[str, dict[str, Any]]:
        rep = rep or self.rep()
        return {v.vid: v.to_dict() for v in rep.violations}


class TestSkillRules(Fixture):
    def test_s1_body_lines_thresholds(self) -> None:
        # sk() emits one blank separator line after the closing '---' (counted, literal "after frontmatter")
        write_skill(self.root, sk(body="\n".join(["# Demo"] + ["x"] * 498)).rstrip("\n"))  # 1 + 499 = 500
        self.assertEqual(ids(self.rep(), "S1"), set())
        write_skill(self.root, sk(body="\n".join(["# Demo"] + ["x"] * 499)).rstrip("\n"))  # 501
        self.assertTrue(any(":body-lines" in i for i in ids(self.rep(), "S1")))
        v = [x for x in self.rep().violations if x.rule == "S1"][0]
        self.assertEqual(v.size, 501)

    def test_s2_length_thresholds_and_hard_cap(self) -> None:
        write_skill(self.root, sk(desc="Use when x. " + "a" * 280))  # 295 chars
        self.assertEqual(ids(self.rep(), "S2"), set())
        write_skill(self.root, sk(desc="Use when x. " + "a" * 290))  # 305 -> violation
        r = self.rep()
        self.assertEqual(len(ids(r, "S2")), 1)
        write_skill(self.root, sk(desc="Use when x. " + "a" * 1020))  # >1024 -> hard
        r = self.rep()
        self.assertEqual(ids(r, "S2"), set())
        self.assertTrue(any("exceeds hard cap 1024" in h for h in r.hard_errors))

    def test_s2_aggregate_cap(self) -> None:
        prefix = "Use when x. "
        for total in (11_999, 12_000, 12_001):
            with self.subTest(total=total):
                # Keep every description under 300 chars to isolate the aggregate cap.
                base, extra = divmod(total, 41)
                for i in range(41):
                    length = base + (1 if i < extra else 0)
                    write_skill(self.root, sk(name=f"s{i}", desc=prefix + "a" * (length - len(prefix))), name=f"s{i}")
                rep = self.rep()
                self.assertEqual(ids(rep, "S2"), set())
                expected = (
                    ["S2:ycc/skills: aggregate description length 12001 exceeds hard cap 12000"]
                    if total > 12_000
                    else []
                )
                self.assertEqual(rep.hard_errors, expected)
                self.assertEqual(run_ratchet(rep, {}), int(total > 12_000))

    def test_s3_use_when(self) -> None:
        write_skill(self.root, sk(desc="Fixes things quickly."))
        self.assertEqual(len(ids(self.rep(), "S3")), 1)
        for d in ("USE WHEN asked", "use for cleanup", "use after sync", "When the user says hi"):
            write_skill(self.root, sk(desc=d + "."))
            self.assertEqual(ids(self.rep(), "S3"), set(), d)
        write_skill(self.root, sk(desc="reuse whenever now."))
        self.assertEqual(len(ids(self.rep(), "S3")), 1)

    def test_s4_name_rules(self) -> None:
        write_skill(self.root, sk(name="Bad_Name"), name="demo")
        r = self.rep()
        self.assertTrue(any("not kebab-case" in i for i in ids(r, "S4")))
        self.assertTrue(any("!= directory" in i for i in ids(r, "S4")))
        write_skill(self.root, sk(name="claude-helper"))
        r = self.rep()
        self.assertTrue(any("claude/anthropic" in i for i in ids(r, "S4")))
        long_name = "a" * 65
        write_skill(self.root, sk(name=long_name), name=long_name)
        self.assertTrue(any("longer than 64" in i for i in ids(self.rep(), "S4")))

    def test_s5_known_keys(self) -> None:
        write_skill(self.root, sk(extra_fm=["version: 2", "license: MIT"]))
        r = self.rep()
        self.assertTrue(any("version" in i for i in ids(r, "S5")))
        self.assertEqual(len(ids(r, "S5")), 1)

    def test_s6_missing_and_present_mentions(self) -> None:
        p = write_skill(self.root, sk(body="# Demo\nSee references/deep/notes.md only.\n"))
        (p.parent / "references" / "deep").mkdir(parents=True)
        (p.parent / "references" / "deep" / "notes.md").write_text("n")
        (p.parent / "references" / "unused.md").write_text("u")  # duplicate basename case below
        r = self.rep()
        self.assertEqual(ids(r, "S6"), {f"S6:{vp_rel(self.root, p)}:unmentioned file references/unused.md"})
        p.write_text(sk(body="# Demo\nreferences/deep/notes.md and references/unused.md\n"))
        self.assertEqual(ids(self.rep(), "S6"), set())

    def test_s6_duplicate_basenames_require_paths(self) -> None:
        p = write_skill(self.root, sk(body="# Demo\nmentions alpha.md only\n"))
        for sub in ("references/a", "references/b"):
            (p.parent / sub).mkdir(parents=True)
            (p.parent / sub / "alpha.md").write_text("x")
        r = self.rep()
        self.assertEqual(len(ids(r, "S6")), 2)  # bare basename not enough
        p.write_text(sk(body="# Demo\nreferences/a/alpha.md and references/b/alpha.md\n"))
        self.assertEqual(ids(self.rep(), "S6"), set())

    def test_s7_contents(self) -> None:
        d = self.root / "ycc" / "skills" / "demo" / "references"
        d.mkdir(parents=True)
        write_skill(self.root, sk())
        short = "\n".join(["# Short"] + ["x"] * 99)
        (d / "short.md").write_text(short)
        self.assertEqual(ids(self.rep(), "S7"), set())
        long_body = "\n".join(["# Long", "## Intro"] + ["x"] * 100)
        (d / "long.md").write_text(long_body)
        self.assertEqual(len(ids(self.rep(), "S7")), 1)
        good = "\n".join(["---", "x: 1", "---", "# Title", "", "## Contents", "", "- [A](#a)"] + ["x"] * 100)
        (d / "long.md").write_text(good)
        self.assertEqual(ids(self.rep(), "S7"), set())
        (d / "long.md").write_text("\n".join(["# Title", "## Intro", "x" * 40, "## Contents"] + ["x"] * 100))
        self.assertEqual(len(ids(self.rep(), "S7")), 1)  # Contents too deep / not first H2
        # M2: prose line before Contents breaks the "only blanks then Contents" rule
        (d / "long.md").write_text("\n".join(["# Title", "intro prose", "## Contents"] + ["x"] * 100))
        self.assertEqual(len(ids(self.rep(), "S7")), 1)
        # M2: H3 Contents is not accepted
        (d / "long.md").write_text("\n".join(["# Title", "### Contents"] + ["x"] * 100))
        self.assertEqual(len(ids(self.rep(), "S7")), 1)
        # M2: "## Table of Contents" is accepted
        (d / "long.md").write_text("\n".join(["# Title", "   ## Table of Contents"] + ["x"] * 100))
        self.assertEqual(ids(self.rep(), "S7"), set())

    def test_s8_md_links(self) -> None:
        d = self.root / "ycc" / "skills" / "demo" / "references"
        d.mkdir(parents=True)
        write_skill(self.root, sk())
        (d / "a.md").write_text(
            "# T\n\n[inl](guide.md) [q](guide.md?x=1) [anch](guide.md#s) [web](https://e.com/a.md)\n\n[ref]: other.md\n"
            '<a href="third.md">x</a> bare guide.md `code(guide.md)`\n\n```\n[block](block.md)\n```\n'
        )
        got = {v.item for v in self.rep().violations if v.rule == "S8"}
        self.assertEqual(
            got,
            {
                "links to 'guide.md'",
                "links to 'guide.md?x=1'",
                "links to 'guide.md#s'",
                "links to 'other.md'",
                "links to 'third.md'",
            },
        )

    def test_s9_tools_forms(self) -> None:
        ok = ["Read", "Bash(git status:*)", "mcp__github__add_issue_comment", "mcp__linear-team__get_workspace"]
        write_skill(self.root, sk(allowed=ok))
        self.assertEqual(ids(self.rep(), "S9"), set())
        write_skill(self.root, sk(allowed="Read, Task, mcp__github__x, Bash(git status:*), WebFetch"))
        self.assertEqual(ids(self.rep(), "S9"), {"S9:ycc/skills/demo/SKILL.md:unknown tool 'Task'"})
        write_skill(self.root, sk(allowed="Read mcp__nope__x"))
        self.assertTrue(any("undeclared MCP server 'nope'" in i for i in ids(self.rep(), "S9")))

    def test_s9_malformed_tools(self) -> None:
        d = json.dumps(GOOD_DESC)
        write_skill(self.root, f"---\nname: demo\ndescription: {d}\nallowed-tools: [Read, 5]\n---\n# D\n")
        self.assertTrue(any("non-string tool entry" in h for h in self.rep().hard_errors))
        write_skill(self.root, f"---\nname: demo\ndescription: {d}\nallowed-tools: 'Read, Bash(x'\n---\n# D\n")
        self.assertTrue(any("unbalanced '('" in h for h in self.rep().hard_errors))
        write_skill(self.root, f"---\nname: demo\ndescription: {d}\nallowed-tools: 'Read, x)'\n---\n# D\n")
        self.assertTrue(any("unbalanced ')'" in h for h in self.rep().hard_errors))
        write_skill(self.root, f"---\nname: demo\ndescription: {d}\nallowed-tools: 7\n---\n# D\n")
        self.assertTrue(any("must be list or string" in h for h in self.rep().hard_errors))
        # M1: structurally invalid tool entries are hard errors, not unknown-tool violations
        for bad_val in ("Bash(x)not-a-tool", "Bash(x)Task(y)", "Read(", "Read)"):
            write_skill(
                self.root, f"---\nname: demo\ndescription: {d}\nallowed-tools: {json.dumps(bad_val)}\n---\n# D\n"
            )
            self.assertTrue(
                any("malformed tool" in h or "malformed tools value" in h for h in self.rep().hard_errors),
                bad_val,
            )
            self.assertEqual(ids(self.rep(), "S9"), set(), bad_val)
        write_skill(
            self.root,
            f"---\nname: demo\ndescription: {d}\nallowed-tools:\n  - {json.dumps('Bash(git status')}\n---\n# D\n",
        )
        self.assertTrue(any("malformed tool entry" in h for h in self.rep().hard_errors))


class TestAgentRules(Fixture):
    def test_a1_keys(self) -> None:
        (self.root / "ycc" / "agents" / "helper.md").write_text(ag(extra_fm=["title: Helper", "model: sonnet"]))
        r = self.rep()
        self.assertTrue(any("title" in i for i in ids(r, "A1")))
        self.assertEqual(len(ids(r, "A1")), 1)

    def test_a2_tools(self) -> None:
        tools = ["Read", "MultiEdit", "mcp__linear-team__get_workspace", "mcp__github__*"]
        (self.root / "ycc" / "agents" / "helper.md").write_text(ag(tools=tools))
        got = {v.item for v in self.rep().violations if v.rule == "A2"}
        self.assertEqual(got, {"unknown tool 'MultiEdit'"})
        (self.root / "ycc" / "agents" / "helper.md").write_text(ag(tools="Read, mcp__nope__x"))
        self.assertTrue(any("undeclared MCP server" in i for i in ids(self.rep(), "A2")))


class TestRootAndInputs(Fixture):
    def test_r1_counts(self) -> None:
        (self.root / "CLAUDE.md").write_text("@AGENTS.md\n" + "\n".join(["# c"] * 39))
        self.assertEqual(ids(self.rep(), "R1"), set())
        (self.root / "CLAUDE.md").write_text("@AGENTS.md\n" + "\n".join(["# c"] * 40))
        self.assertEqual(ids(self.rep(), "R1"), {"R1:CLAUDE.md:line-count"})
        (self.root / "CLAUDE.md").write_text("@AGENTS.md\n")
        (self.root / "AGENTS.md").write_text("\n".join(["# a"] * 150))
        self.assertEqual(ids(self.rep(), "R1"), set())
        (self.root / "AGENTS.md").write_text("\n".join(["# a"] * 151))
        self.assertEqual(ids(self.rep(), "R1"), {"R1:AGENTS.md:line-count"})
        (self.root / "ycc" / "settings" / "rules" / "CLAUDE.md").write_text("\n".join(["# r"] * 201))
        self.assertIn("R1:ycc/settings/rules/CLAUDE.md:line-count", ids(self.rep(), "R1"))

    def test_r1_combined_budget_counts_agents_once(self) -> None:
        (self.root / "AGENTS.md").write_text("\n".join(["# a"] * 150))
        (self.root / "CLAUDE.md").write_text("@AGENTS.md\n" + "\n".join(["# c"] * 39))
        self.assertEqual(ids(self.rep(), "R1"), set())  # 150 + 40 == 190
        (self.root / "CLAUDE.md").write_text("@AGENTS.md\n" + "\n".join(["# c"] * 40))
        r = self.rep()
        self.assertEqual(
            ids(r, "R1"),
            {"R1:CLAUDE.md:line-count", "R1:CLAUDE.md+AGENTS.md:combined-line-count"},
        )
        v = [x for x in r.violations if x.item == "combined-line-count"][0]
        self.assertEqual(v.size, 191)  # AGENTS.md counted once, not twice

    def test_r1_claude_md_standalone_import_rules(self) -> None:
        (self.root / "CLAUDE.md").write_text(
            "@AGENTS.md\n\nSee @AGENTS.md and `@AGENTS.md`.\n- @AGENTS.md\n> @AGENTS.md\n"
            "    @AGENTS.md\n<!-- @AGENTS.md -->\n<!--\n@AGENTS.md\n-->\n```\n@AGENTS.md\n@OTHER.md\n```\n"
        )
        self.assertEqual(self.rep().hard_errors, [])
        (self.root / "CLAUDE.md").write_text("# no import\nSee @AGENTS.md in prose only.\n")
        self.assertTrue(any("missing standalone @AGENTS.md import" in h for h in self.rep().hard_errors))
        (self.root / "CLAUDE.md").write_text("@AGENTS.md\n\n  @AGENTS.md  \n")
        self.assertTrue(any("duplicate @AGENTS.md imports (2)" in h for h in self.rep().hard_errors))
        (self.root / "CLAUDE.md").write_text("@AGENTS.md\n@CONTRIBUTING.md\n")
        self.assertTrue(any("unexpected import '@CONTRIBUTING.md'" in h for h in self.rep().hard_errors))
        (self.root / "CLAUDE.md").write_text("@./AGENTS.md\n")
        self.assertTrue(any("unexpected import '@./AGENTS.md'" in h for h in self.rep().hard_errors))
        (self.root / "CLAUDE.md").write_text("<!-- note --> @AGENTS.md\n<!-- comment --> @OTHER.md\n")
        self.assertTrue(any("unexpected import '@OTHER.md'" in h for h in self.rep().hard_errors))
        (self.root / "CLAUDE.md").write_text("@AGENTS.md\n<!-- unclosed comment\n@OTHER.md\n")
        self.assertTrue(any("unclosed HTML comment" in h for h in self.rep().hard_errors))

    def test_r1_claude_rules_frontmatter_and_globs(self) -> None:
        rules = self.root / ".claude" / "rules" / "sub"
        rules.mkdir(parents=True)
        (self.root / "scripts" / "deep").mkdir(parents=True)
        (self.root / "scripts" / "top.py").write_text("x")
        (self.root / "scripts" / "deep" / "nested.py").write_text("x")
        rule = rules / "demo.md"
        rule.write_text("---\npaths:\n  - 'scripts/*.py'\n  - 'scripts/**/nested.py'\n---\n# ok\n")
        self.assertEqual(self.rep().hard_errors, [])
        # * must not cross /, while ** must
        (self.root / "scripts" / "top.py").unlink()
        self.assertTrue(any("scripts/*.py' matches no existing" in h for h in self.rep().hard_errors))
        rule.write_text("---\npaths:\n  - 'scripts/**/*.py'\n---\n# ok\n")
        self.assertEqual(self.rep().hard_errors, [])
        # trailing ** requires a file inside the directory, and root suffix match is rejected
        rule.write_text("---\npaths:\n  - 'nested.py'\n---\n# dead\n")
        self.assertTrue(any("nested.py' matches no existing" in h for h in self.rep().hard_errors))
        # missing frontmatter, bad key, empty paths, invalid glob components
        for bad, needle in (
            ("# no frontmatter\n", "missing YAML frontmatter"),
            ("---\npaths: []\n---\n", "nonempty list"),
            ("---\npaths: 'scripts/**'\n---\n", "nonempty list"),
            ("---\npaths:\n  - 1\n---\n", "must be a glob string"),
            ("---\npaths:\n  - ''\n---\n", "nonempty glob"),
            ("---\npaths:\n  - '../CLAUDE.md'\n---\n", "repository-relative POSIX glob"),
            ("---\npaths:\n  - '/CLAUDE.md'\n---\n", "repository-relative POSIX glob"),
            ("---\npaths:\n  - 'scripts/**.py'\n---\n", "entire path component"),
            ("---\npaths:\n  - 'scripts/*.{py,sh}'\n---\n", "split it into separate"),
            ("---\npaths:\n  - 'CLAUDE.md'\nglobs:\n  - 'CLAUDE.md'\n---\n", "unknown frontmatter key 'globs'"),
            ("---\npaths:\n  - 'CLAUDE.md'\n---\n# body\n@AGENTS.md\n", "standalone import '@AGENTS.md'"),
            ("---\npaths:\n  - 'CLAUDE.md'\n---\n<!-- open\n@AGENTS.md\n", "unclosed HTML comment"),
        ):
            rule.write_text(bad)
            self.assertTrue(any(needle in h for h in self.rep().hard_errors), (bad, self.rep().hard_errors))
        rule.write_text("---\npaths:\n  - 'CLAUDE.md'\n---\n# ok\n")
        (rules / "notes.txt").write_text("bad\n")
        self.assertTrue(any("non-Markdown file under .claude/rules" in h for h in self.rep().hard_errors))
        (rules / "notes.txt").unlink()
        (self.root / "node_modules" / "pkg").mkdir(parents=True)
        (self.root / "node_modules" / "pkg" / "index.js").write_text("x")
        rule.write_text("---\npaths:\n  - 'node_modules/**'\n---\n# bad\n")
        self.assertTrue(any("node_modules/**' matches no existing" in h for h in self.rep().hard_errors))

    def test_missing_mcp_json_hard(self) -> None:
        (self.root / "mcp-configs" / "mcp.json").unlink()
        self.assertTrue(any("required file missing" in h for h in self.rep().hard_errors))

    def test_bad_frontmatter_hard(self) -> None:
        write_skill(self.root, "no frontmatter here\n")
        self.assertTrue(any("missing YAML frontmatter" in h for h in self.rep().hard_errors))
        write_skill(self.root, "---\nname: [unclosed\ndescription: x\n")
        self.assertTrue(any("not parseable YAML" in h or "unterminated" in h for h in self.rep().hard_errors))
        write_skill(self.root, "---\n- a\n- b\n---\n# D\n")
        self.assertTrue(any("not a YAML mapping" in h for h in self.rep().hard_errors))


class TestRatchet(Fixture):
    def test_new_stale_worsened(self) -> None:
        p = write_skill(self.root, sk(body="\n".join(["# D"] + ["x"] * 600)))
        rep = self.rep()
        base = self.baseline(rep)
        self.assertEqual(run_ratchet(rep, base), 0)
        # worsened: grow body
        p.write_text(sk(body="\n".join(["# D"] + ["x"] * 700)))
        rep2 = self.rep()
        self.assertEqual(run_ratchet(rep2, base), 1)
        # improved: allowed (smaller), but then stale if violation disappears
        p.write_text(sk(body="# D\n"))
        rep3 = self.rep()
        self.assertEqual(run_ratchet(rep3, base), 1)  # STALE
        base3 = self.baseline(rep3)
        self.assertEqual(run_ratchet(rep3, base3), 0)
        # new violation
        (self.root / "ycc" / "agents" / "a.md").write_text(ag(name="a", extra_fm=["bogus: 1"]))
        rep4 = self.rep()
        self.assertEqual(run_ratchet(rep4, base3), 1)

    def test_hard_1024_not_baselined(self) -> None:
        write_skill(self.root, sk(desc="Use when x. " + "a" * 1020))
        rep = self.rep()
        self.assertEqual(run_ratchet(rep, self.baseline(rep)), 1)  # hard error fails even when baselined empty

    def test_baseline_shape(self) -> None:
        with self.assertRaises(SystemExit):
            vp.load_baseline(self.root / "nope.json")
        bad = self.root / "bad.json"
        payloads = (
            '{"version": 2, "violations": []}',
            '{"version": 1}',
            "not json",
            '{"version": 1, "violations": [{"id": 3}]}',
        )
        for payload in payloads:
            bad.write_text(payload)
            with self.assertRaises(SystemExit):
                vp.load_baseline(bad)
        good = self.root / "good.json"
        good.write_text('{"version": 1, "violations": [{"id": "S1:y/x:body-lines", "size": 510}]}')
        self.assertEqual(vp.load_baseline(good)["S1:y/x:body-lines"]["size"], 510)


class TestCLI(Fixture):
    def cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(vp.SCRIPT_DIR / "validate_practices.py"), *args],
            capture_output=True,
            text=True,
            cwd="/",
        )

    def test_cli_end_to_end(self) -> None:
        write_skill(self.root, sk(body="\n".join(["# D"] + ["x"] * 600)))
        rc = self.cli("--root", str(self.root))
        self.assertNotEqual(rc.returncode, 0)  # missing baseline
        self.assertIn("baseline missing", rc.stderr)
        w = self.cli("--root", str(self.root), "--write-baseline")
        self.assertEqual(w.returncode, 0, w.stderr)
        ok = self.cli("--root", str(self.root))
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertIn("total:", ok.stdout)
        # worsened via baseline edit
        bp = self.root / "scripts" / "practices-baseline.json"
        data = json.loads(bp.read_text())
        for e in data["violations"]:
            if "size" in e:
                e["size"] = 0
        bp.write_text(json.dumps(data))
        bad = self.cli("--root", str(self.root))
        self.assertEqual(bad.returncode, 1)
        self.assertIn("WORSENED", bad.stdout)
        write_skill(self.root, sk(body="# D\n"))
        bp.write_text(json.dumps(data))
        st = self.cli("--root", str(self.root))
        self.assertEqual(st.returncode, 1)
        self.assertIn("STALE", st.stdout)


class TestReviewFixes(Fixture):
    def test_h1_baseline_numeric_rules(self) -> None:
        def load(violations: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
            path = self.root / "b.json"
            path.write_text(json.dumps({"version": 1, "violations": violations}))
            return vp.load_baseline(path)

        for rid in ("S1:a/SKILL.md:body-lines", "S2:a/SKILL.md:description-length", "R1:CLAUDE.md:line-count"):
            for bad in ({"id": rid}, {"id": rid, "size": -1}, {"id": rid, "size": "5"}, {"id": rid, "size": True}):
                with self.assertRaises(SystemExit, msg=str(bad)):
                    load([bad])
            self.assertIn(rid, load([{"id": rid, "size": 0}]))
        with self.assertRaises(SystemExit):
            load([{"id": "S3:a/SKILL.md:x", "size": 3}])  # size on non-numeric rule
        with self.assertRaises(SystemExit):
            load([{"id": "S3:a/SKILL.md:x"}, {"id": "S3:a/SKILL.md:x"}])  # duplicate id
        with self.assertRaises(SystemExit):
            load([{"id": "ZZ:a:b"}])  # unknown rule

    def test_h1_ratchet_fails_when_baseline_lacks_size(self) -> None:
        write_skill(self.root, sk(body="\n".join(["# D"] + ["x"] * 600)))
        rep = self.rep()
        base = {v.vid: {"id": v.vid} for v in rep.violations}
        self.assertEqual(run_ratchet(rep, base), 1)

    def test_h2_source_files_uses_git_cached_and_others(self) -> None:
        p = write_skill(self.root, sk(body="# D\nreferences/kept.md\n"))
        (p.parent / "references").mkdir()
        (p.parent / "references" / "kept.md").write_text("k")
        (p.parent / "references" / "gone.md").write_text("g")
        (self.root / ".gitignore").write_text("ignored.md\n")
        git_repo_fixture(self.root)
        (p.parent / "references" / "gone.md").unlink()  # cached but missing on disk
        (p.parent / "references" / "new.md").write_text("n")  # untracked, not ignored
        (p.parent / "references" / "ignored.md").write_text("i")  # untracked, ignored
        got = vp.source_files(self.root, "ycc/skills")
        self.assertIn("ycc/skills/demo/references/kept.md", got)
        self.assertIn("ycc/skills/demo/references/new.md", got)
        self.assertNotIn("ycc/skills/demo/references/gone.md", got)
        self.assertNotIn("ycc/skills/demo/references/ignored.md", got)
        self.assertEqual(ids(self.rep(), "S6"), {f"S6:{vp_rel(self.root, p)}:unmentioned file references/new.md"})

    def test_h3_missing_skills_or_agents_dir(self) -> None:
        shutil.rmtree(self.root / "ycc" / "skills")
        r = self.rep()
        self.assertTrue(any("skills directory missing" in h for h in r.hard_errors))
        shutil.rmtree(self.root / "ycc" / "agents")
        r = self.rep()
        self.assertTrue(any("agents directory missing" in h for h in r.hard_errors))
        self.assertEqual(run_ratchet(r, {}), 1)

    def test_h4_mcp_non_object_root(self) -> None:
        for payload in ("[]", '"x"', "null", "3"):
            (self.root / "mcp-configs" / "mcp.json").write_text(payload)
            self.assertTrue(any("root must be a JSON object" in h for h in self.rep().hard_errors), payload)

    def test_m3_agent_hooks_key_allowed(self) -> None:
        (self.root / "ycc" / "agents" / "helper.md").write_text(ag(extra_fm=["hooks: {}"]))
        self.assertEqual(ids(self.rep(), "A1"), set())

    def test_m4_counts_include_zero_rules(self) -> None:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            vp.print_counts(self.rep(), 0)
        out = buf.getvalue()
        for rule in ("S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9", "A1", "A2", "R1"):
            self.assertIn(f"{rule}: 0 violation(s)", out)


class TestCodeRabbitFixes(Fixture):
    def test_duplicate_frontmatter_key_is_hard_error(self) -> None:
        (self.root / "ycc" / "agents" / "helper.md").write_text(ag(tools=["Read"], extra_fm=["tools:", "  - Grep"]))
        self.assertTrue(any("duplicate key 'tools'" in h for h in self.rep().hard_errors))

    def test_duplicate_nested_key_is_hard_error(self) -> None:
        (self.root / "ycc" / "agents" / "helper.md").write_text(ag(extra_fm=["hooks:", "  a: 1", "  a: 2"]))
        self.assertTrue(any("duplicate key 'a'" in h for h in self.rep().hard_errors))

    def test_merge_keys_match_safe_load(self) -> None:
        import yaml
        from practices_parse import load_unique_yaml

        raw = "base: &b\n  x: 1\n  y: 2\nchild:\n  <<: *b\n  x: 3\n"
        self.assertEqual(load_unique_yaml(raw), yaml.safe_load(raw))

    def test_s8_angle_bracket_reference_destination(self) -> None:
        d = self.root / "ycc" / "skills" / "demo" / "references"
        d.mkdir(parents=True)
        write_skill(self.root, sk())
        (d / "a.md").write_text("# T\n\n[guide]: <guide.md>\n[ok]: <https://e.com/x.md>\n")
        got = {v.item for v in self.rep().violations if v.rule == "S8"}
        self.assertEqual(got, {"links to 'guide.md'"})

    def test_duplicate_violation_deduped_and_baseline_round_trips(self) -> None:
        (self.root / "ycc" / "agents" / "helper.md").write_text(ag(tools=["Read", "Bogus", "Bogus"]))
        rep = self.rep()
        self.assertEqual(len(rep.violations), 2)  # raw: Bogus recorded twice
        self.assertEqual(len(rep.unique_violations()), 1)  # deduped view
        out = self.root / "scripts" / "practices-baseline.json"
        vp.write_baseline(rep, out)
        entries = json.loads(out.read_text())["violations"]
        self.assertEqual(len(entries), len({e["id"] for e in entries}))
        self.assertEqual(run_ratchet(self.rep(), vp.load_baseline(out)), 0)

    def test_duplicate_numeric_keeps_max_size(self) -> None:
        rep = vp.Report()
        rep.add("S7", "a.md", "x", 120)
        rep.add("S7", "a.md", "x", 150)
        rep.add("S7", "a.md", "x", 130)
        self.assertEqual([v.size for v in rep.unique_violations().values()], [150])


class TestWrapper(Fixture):
    """validate-practices.sh against a fixture root, with a fake `claude` on PATH."""

    def setUp(self) -> None:
        super().setUp()
        (self.root / "scripts").mkdir()
        (self.root / "scripts" / "practices-baseline.json").write_text('{"version": 1, "violations": []}')
        (self.root / "scripts" / "validate_practices.py").write_text("# placeholder\n")
        (self.root / "scripts" / "practices_parse.py").write_text("# placeholder\n")
        (self.root / "scripts" / "practices_rules.py").write_text("# placeholder\n")
        write_skill(self.root, sk())

    def run_wrapper(self, claude_exit: int | None) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as tmp:
            bindir = Path(tmp)
            for tool in ("python3", "dirname"):
                (bindir / tool).symlink_to(shutil.which(tool) or tool)
            if claude_exit is not None:
                fake = bindir / "claude"
                fake.write_text(f'#!/bin/sh\necho fake-claude "$@"\nexit {claude_exit}\n')
                fake.chmod(0o755)
            env = {"PATH": str(bindir), "PRACTICES_ROOT": str(self.root)}
            wrapper = vp.SCRIPT_DIR / "validate-practices.sh"
            return subprocess.run(["/bin/bash", str(wrapper)], capture_output=True, text=True, env=env, cwd="/")

    def test_skips_without_cli(self) -> None:
        r = self.run_wrapper(None)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("NOTICE: claude CLI not on PATH", r.stdout)

    def test_cli_success_and_failure_propagate(self) -> None:
        ok = self.run_wrapper(0)
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertIn("fake-claude plugin validate", ok.stdout)
        bad = self.run_wrapper(3)
        self.assertNotEqual(bad.returncode, 0)

    def test_missing_required_input_fails(self) -> None:
        (self.root / "scripts" / "practices-baseline.json").unlink()
        r = self.run_wrapper(None)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("required input missing", r.stderr)


def git_repo_fixture(root: Path) -> None:
    """Turn the fixture root into a committed git repo (for source_files() coverage)."""
    # Git hooks export GIT_DIR/GIT_INDEX_FILE; inheriting them would mutate the caller's repo.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    for args in (
        ["init", "-q"],
        ["add", "-A"],
        ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"],
    ):
        subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, env=env)


def vp_rel(root: Path, p: Path) -> str:
    return str(p.relative_to(root))


if __name__ == "__main__":
    unittest.main()
