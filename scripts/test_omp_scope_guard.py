#!/usr/bin/env python3
"""Behaviour tests for the generated ycc OMP agent scope guard (YAN-1250).

The generated extension (packages/omp/ycc/extensions/scope-guard.ts) is imported under Node's
TypeScript type stripping with its real agent-scopes.json, bound to a fake OMP `pi` that records
the `tool_call` handler, and each case calls that handler with an OMP-shaped event and
`ctx.agent` identity ({kind, name}, as sdk.ts builds it for task subagents).
"""

from __future__ import annotations

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

import generate_omp_packages as gen  # noqa: E402

GUARD_ROOT = gen.REPO_ROOT / gen.COMPONENT_ROOT
NODE = shutil.which("node")


def node_strips_types() -> bool:
    """Node >= 22.6 accepts --experimental-strip-types; older Node cannot load the .ts guard."""
    if NODE is None:
        return False
    probe = subprocess.run(
        [NODE, "--no-warnings", "--experimental-strip-types", "-e", ""], capture_output=True, check=False
    )
    return probe.returncode == 0


# CI must exercise the guard, so a missing capability there fails instead of skipping.
NODE_READY = node_strips_types() or bool(os.environ.get("CI"))

# Reads {guard, cases} on stdin; prints one JSON array of handler results.
DRIVER = r"""
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { guard, cases } = JSON.parse(readFileSync(0, "utf8"));
const handlers = [];
const module = await import(pathToFileURL(guard).href);
module.default({ on: (event, handler) => handlers.push([event, handler]), setLabel() {} });
if (handlers.length !== 1 || handlers[0][0] !== "tool_call") throw new Error("expected one tool_call handler");
const results = cases.map(({ toolName, input, agent }) =>
  handlers[0][1]({ type: "tool_call", toolCallId: "t", toolName, input }, { agent }) ?? null);
console.log(JSON.stringify(results));
"""


def sub(name: str) -> dict[str, Any]:
    return {"kind": "sub", "id": f"0-{name}", "name": name, "depth": 1}


def bash(agent: str, command: str) -> dict[str, Any]:
    return {"toolName": "bash", "input": {"command": command}, "agent": sub(agent)}


@unittest.skipUnless(NODE_READY, "node >= 22.6 with --experimental-strip-types is required")
class ScopeGuardTest(unittest.TestCase):
    def run_cases(self, cases: list[dict[str, Any]], root: Path = GUARD_ROOT) -> list[dict[str, Any] | None]:
        assert NODE is not None
        with tempfile.TemporaryDirectory() as tmp:
            driver = Path(tmp) / "driver.mjs"
            driver.write_text(DRIVER, encoding="utf-8")
            result = subprocess.run(
                [NODE, "--no-warnings", "--experimental-strip-types", str(driver)],
                input=json.dumps({"guard": str(root / gen.SCOPE_GUARD), "cases": cases}),
                capture_output=True,
                text=True,
                timeout=60,
                env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": tmp},
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        results: list[dict[str, Any] | None] = json.loads(result.stdout.strip().splitlines()[-1])
        return results

    def assert_allowed(self, cases: list[dict[str, Any]]) -> None:
        for case, outcome in zip(cases, self.run_cases(cases), strict=True):
            with self.subTest(case=case):
                self.assertIsNone(outcome)

    def assert_blocked(self, cases: list[dict[str, Any]], needle: str = "") -> list[str]:
        reasons: list[str] = []
        for case, outcome in zip(cases, self.run_cases(cases), strict=True):
            with self.subTest(case=case):
                assert outcome is not None, f"expected a block for {case}"
                self.assertTrue(outcome["block"])
                self.assertIn("ycc scope guard", outcome["reason"])
                self.assertIn(needle, outcome["reason"])
                reasons.append(outcome["reason"])
        return reasons

    def test_git_cleanup_allows_every_segment_within_its_prefixes(self) -> None:
        self.assert_allowed(
            [
                bash("git-cleanup", command)
                for command in (
                    "git branch --merged main",
                    "git fetch --prune && gh pr list --state merged | glab mr list",
                    "git log --oneline -5 || git status; git worktree list &",
                    "(git branch -vv; git stash list) 2>&1 | git column",
                    "{ git tag -l; } 2>/dev/null",
                    "git branch -r |\n  git status\ngh repo view",
                    "git log --format='%h %s' \"--grep=fix bug\"  # trailing comment",
                )
            ]
        )

    def test_git_cleanup_blocks_any_segment_outside_its_prefixes(self) -> None:
        reasons = self.assert_blocked(
            [
                bash("git-cleanup", command)
                for command in (
                    "rm -rf .git",
                    "git status && rm -rf /tmp/x",
                    "git log | sh",
                    "git status; curl https://example.invalid",
                    "(git status; python3 -c 'x')",
                    "{ git status; rmdir x; }",
                    "git status &\nnpm publish",
                    "github-cli status",
                    "bash -c 'git status'",
                    "sudo git gc",
                    "env git status",
                    "xargs git branch -D",
                )
            ],
            "outside the allowed prefixes",
        )
        self.assertIn('"rm -rf /tmp/x"', reasons[1])
        self.assertIn("allowed prefixes: `git`, `gh`, `glab`", reasons[0])

    def test_unverifiable_commands_fail_closed(self) -> None:
        self.assert_blocked(
            [
                bash("git-cleanup", command)
                for command in (
                    "git log $(rm -rf x)",
                    "git log `rm x`",
                    'git log "$(rm x)"',
                    "git branch -D $BRANCH",
                    "git diff <(cat /etc/passwd)",
                    "git commit -F- <<EOF",
                    "git log > /tmp/out",
                    "git log 'unbalanced",
                    'git log "unbalanced',
                    "(git status",
                    "git status |",
                    "GIT_DIR=/tmp git status",
                    "git status;; git log",
                )
            ],
            "",
        )

    def test_backport_wildcard_matches_exactly_one_argument(self) -> None:
        agent = "backport-conflict-resolver"
        self.assert_allowed(
            [
                bash(agent, "git -C /tmp/wt show HEAD:src/a.py"),
                bash(agent, "git -C '/tmp/my wt' diff --stat && git -C wt log -3 | git -C wt blame f"),
                bash(agent, "git -C wt merge-base main HEAD"),
            ]
        )
        self.assert_blocked(
            [
                bash(agent, "git show HEAD"),
                bash(agent, "git -C wt checkout main"),
                bash(agent, "git -C a b show HEAD"),
                bash(agent, "git -C show"),
                bash(agent, "git -C * show"),
                bash(agent, "git -C wt show && git -C wt push"),
                # bash keeps a digit word before `&>` as an argument: this runs `git -C 2 push show`.
                bash(agent, "git -C 2&>/dev/null push show"),
                bash(agent, "git -C 2&>>/dev/null push show"),
            ]
        )

    def test_agent_without_shell_scope_is_blocked(self) -> None:
        self.assert_blocked([bash("code-finder", "ls")], "declares no shell access")

    def test_find_exec_is_blocked_for_find_scoped_agents(self) -> None:
        self.assert_allowed([bash("architecture-analyst", "find . -name '*.py' | wc -l")])
        self.assert_blocked([bash("architecture-analyst", "find . -exec rm {} +")], "runs another command")

    def test_fixers_run_only_their_validation_commands(self) -> None:
        # YAN-1276: the narrowed fixer allowlists hold on OMP too, so a fixer cannot run an
        # interpreter one-liner or a shell wrapper next to its allowed validation command.
        for agent in ("pr-comment-fixer", "review-fixer", "release-fix-applier"):
            self.assert_allowed([bash(agent, "pytest -q tests/test_a.py"), bash(agent, "cargo check")])
            self.assert_blocked(
                [
                    bash(agent, command)
                    for command in (
                        "python3 -c 'print(1)'",
                        "python -c 'print(1)'",
                        "node -e '1'",
                        "bash -c 'pytest'",
                        "sh -c 'cargo check'",
                        "pytest && python3 -c 'print(1)'",
                        "cat setup.cfg",
                    )
                ],
                "outside the allowed prefixes",
            )

    def test_digit_word_before_ampersand_redirect_stays_an_argument(self) -> None:
        # `python3 2&>/dev/null -m mypy` runs the file `2`; only `2>`/`2<` name an fd.
        self.assert_blocked([bash("review-fixer", "python3 2&>/dev/null -m mypy")], "outside the allowed prefixes")
        self.assert_allowed([bash("review-fixer", "python3 -m mypy . 2>/dev/null &>/dev/null")])

    def test_mcp_blocked_for_agents_that_declared_none(self) -> None:
        reasons = self.assert_blocked(
            [
                {"toolName": "mcp__ycc_mcp_github_create_pull_request", "input": {}, "agent": sub("git-cleanup")},
                {"toolName": "mcp__context7_query_docs", "input": {}, "agent": sub("planner")},
                {"toolName": "read", "input": {"path": "mcp://notes://x"}, "agent": sub("planner")},
            ]
        )
        self.assertIn("declares no MCP tools", reasons[0])
        self.assertIn("MCP resource reads", reasons[2])

    def test_mcp_declared_tools_allowed_others_blocked(self) -> None:
        agent = "feature-researcher"
        self.assert_allowed(
            [
                {"toolName": name, "input": {}, "agent": sub(agent)}
                for name in (
                    "mcp__ycc_mcp_context7_query_docs",
                    "mcp__ycc_mcp_context7_resolve_library_id",
                    "mcp__context7_query_docs",
                )
            ]
        )
        reasons = self.assert_blocked(
            [
                {"toolName": "mcp__ycc_mcp_github_search_code", "input": {}, "agent": sub(agent)},
                {"toolName": "mcp__ycc_mcp_context7_other", "input": {}, "agent": sub(agent)},
            ],
            "is not a declared MCP tool",
        )
        self.assertIn("context7/query-docs", reasons[0])

    def test_main_session_and_non_ycc_agents_pass_through(self) -> None:
        main = {"kind": "main", "id": "Main", "name": "main", "depth": 0}
        self.assert_allowed(
            [
                {"toolName": "bash", "input": {"command": "rm -rf x"}, "agent": main},
                {"toolName": "bash", "input": {"command": "rm -rf x"}, "agent": sub("task")},
                {"toolName": "bash", "input": {"command": "rm -rf x"}, "agent": sub("sub")},
                {"toolName": "mcp__ycc_mcp_github_search_code", "input": {}, "agent": sub("scout")},
                # Plain `Bash` agents keep full shell access.
                bash("implementor", "rm -rf x && curl x | sh"),
                # Non-guarded tools of scoped agents.
                {"toolName": "read", "input": {"path": "src/a.py"}, "agent": sub("git-cleanup")},
            ]
        )

    def test_missing_scope_data_blocks_bash_and_mcp_for_subagents(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / gen.SCOPE_GUARD).parent.mkdir(parents=True)
            shutil.copy2(GUARD_ROOT / gen.SCOPE_GUARD, root / gen.SCOPE_GUARD)
            results = self.run_cases(
                [
                    bash("implementor", "ls"),
                    {"toolName": "read", "input": {"path": "a"}, "agent": sub("planner")},
                    bash("x", "ls") | {"agent": {"kind": "main", "name": "main"}},
                ],
                root,
            )
        assert results[0] is not None
        self.assertIn("failed to load", results[0]["reason"])
        self.assertEqual(results[1:], [None, None])


if __name__ == "__main__":
    unittest.main()
