#!/usr/bin/env python3
"""Typed fail-closed assertions for the YAN-1122 Claude hooks harness.

Expectations are derived from the official hooks documentation claims under
test (plugin ``hooks/hooks.json`` handlers run alongside settings handlers;
settings-only identical-handler dedupe does not merge plugin copies). Any
count outside the declared expectation fails the run; the old floor's plugin
``WorktreeCreate`` behaviour is the one explicit evidence range, because the
``--worktree`` startup plugin-loading fix landed after the floor.
"""

from __future__ import annotations

from typing import Any

from claude_namespace_checks import check

FLOOR = "2.1.143"

# SessionStart marker totals expected in the plain (non-worktree) run.
SS_RUN: dict[str, dict[str, int]] = {
    "baseline": {},
    "settings-only": {"settings": 1},
    "plugin-only": {"plugin": 1},
    "coexist-distinct": {"settings": 1, "plugin": 1},
    "coexist-exact": {"settings": 1, "plugin": 1},
    "post-migration": {"plugin": 1},
    "disabled-plugin": {},
}


def origin(record: dict[str, Any]) -> str:
    """Registration origin: CLAUDE_PLUGIN_ROOT is exported only to plugin handlers."""
    return "plugin" if record.get("plugin_root") else "settings"


def _counts(records: list[dict[str, Any]], event: str) -> dict[str, int]:
    """Count hook records for one event by registration origin (env proof, not marker)."""
    totals: dict[str, int] = {}
    for record in records:
        if record.get("event") == event:
            key = origin(record)
            totals[key] = totals.get(key, 0) + 1
    return totals


def _check_counts(label: str, expected: dict[str, int], actual: dict[str, int]) -> None:
    check(label, expected, {key: value for key, value in actual.items() if value})


def _check_wt_floor(label: str, scenario: str, event: str, records: list[dict[str, Any]]) -> None:
    """Explicit observed old-version No-Go: only settings WorktreeCreate fires."""
    expected = dict(SS_RUN[scenario])
    if event == "WorktreeCreate":
        expected.pop("plugin", None)
    _check_counts(label, expected, _counts(records, event))


def verify_matrix(results: list[dict[str, Any]], version: str) -> None:
    """Assert per-scenario hook counts, cwd selection, and plugin-root proof."""
    check("scenario count", len(SS_RUN), len(results))
    check("scenario labels", set(SS_RUN), {row["scenario"] for row in results})
    for row in results:
        scenario = str(row["scenario"])
        label = f"{version} {scenario}"
        for run_name in ("ss", "wt"):
            run = row[run_name]
            check(f"{label} {run_name} exit", 0, run["exit"])
            check(f"{label} {run_name} reached fake API", True, run["requests"] > 0)
            records = run["records"]
            for record in records:
                check(f"{label} {run_name} fixture marker", True, record["marker"] in ("settings", "plugin"))
                check(f"{label} {run_name} session recorded", True, bool(record["session"]))
                # A plugin-origin record exists only if ${CLAUDE_PLUGIN_ROOT} was exported
                # AND equals the directory of the executed script (stub verifies).
                check(f"{label} {run_name} script in lab", True, record["script_in_lab"])
                if scenario != "coexist-exact":
                    check(f"{label} {run_name} marker matches origin", record["marker"], origin(record))
                else:
                    check(f"{label} {run_name} exact copies share marker", "plugin", record["marker"])
            if run_name == "ss":
                _check_counts(f"{label} ss SessionStart", SS_RUN[scenario], _counts(records, "SessionStart"))
                _check_counts(f"{label} ss WorktreeCreate", {}, _counts(records, "WorktreeCreate"))
                check(f"{label} ss cwd is fixture repo", True, run["cwd_is_repo"])
            elif version == FLOOR:
                _check_wt_floor(f"{label} wt SessionStart", scenario, "SessionStart", records)
                _check_wt_floor(f"{label} wt WorktreeCreate", scenario, "WorktreeCreate", records)
            else:
                expected = SS_RUN[scenario]
                _check_counts(f"{label} wt SessionStart", expected, _counts(records, "SessionStart"))
                _check_counts(f"{label} wt WorktreeCreate", expected, _counts(records, "WorktreeCreate"))
            if run_name == "wt":
                wc_records = _counts(records, "WorktreeCreate")
                if wc_records:
                    check(f"{label} wt cwd is stub path", True, run["cwd_is_stub"])
                else:
                    check(f"{label} wt cwd is default worktree", True, run["cwd_is_default_wt"])
    marker = f"{version} assert_matrix: all expectations verified"
    print(marker, flush=True)


def negative_self_test() -> None:
    """Prove check() fails closed on every normal run (no weakened-mode switch)."""
    try:
        check("negative-self-test", {"a"}, set())
    except SystemExit as exc:
        if "negative-self-test" in str(exc):
            return
    raise SystemExit("CHECK FAILED [negative-self-test]: check() did not fail closed")
