#!/usr/bin/env python3
"""Typed stdlib assertion helpers for the YAN-1121 namespace harness."""

from __future__ import annotations

import hashlib
import json
import os
import re
import time
from pathlib import Path
from typing import Any

BANNED_DIAGNOSTICS = re.compile(r"collision|conflict|duplicate", re.IGNORECASE)

EXPECTED_DUP_SKILL_COUNT = {"2.1.143": 2, "2.1.300": 1}

# Real-config guard (YAN-2454): live Claude sessions rewrite this runtime state on their
# own, so it is not compared. Settings, plugin indexes/caches, marketplaces, hooks,
# agents, skills and credentials stay strict.
VOLATILE_DIRS = frozenset(
    {
        "backups", "bridge-spawn", "cache", "chrome", "debug", "downloads", "file-history",
        "ide", "jobs", "paste-cache", "plans", "projects", "remote", "session-data",
        "session-env", "sessions", "shell-snapshots", "state", "statsig", "tasks", "teams",
        "telemetry", "todos", "transcripts", "usage-data",
    }
)  # fmt: skip
VOLATILE_SUBTREES = frozenset({"plugins/.trash", "plugins/data", "plugins/store", "plugins/synced", "skills/synced"})
VOLATILE_TOP_FILES = frozenset({"history.jsonl"})
VOLATILE_NAME = re.compile(r"\.(stamp|signature)\.json(\.tmp\.\w+)?$|-cache(-v\d+)?\.json$")
# Plugin indexes stay strict except for the lastUpdated stamps live sessions bump when
# they check marketplaces for updates; any added/removed/changed entry still fails.
PLUGIN_INDEXES = frozenset({"plugins/installed_plugins.json", "plugins/known_marketplaces.json"})
INDEX_TIMESTAMP_KEYS = frozenset({"lastUpdated"})
CLAUDE_JSON = ".claude.json"
# ~/.claude.json is rewritten by every live session (counters, caches, per-project
# stats); only its MCP servers and per-project tool/MCP permissions are guarded.
CLAUDE_JSON_PROJECT_KEYS = (
    "allowedTools", "disabledMcpServers", "disabledMcpjsonServers", "enabledMcpjsonServers", "mcpServers",
)  # fmt: skip


def check(label: str, expected: Any, actual: Any) -> None:
    """Fail closed with label/expected/actual; never return on mismatch."""
    if expected != actual:
        raise SystemExit(f"CHECK FAILED [{label}]: expected={expected!r} actual={actual!r}")


def present(text: str, markers: dict[str, str]) -> dict[str, bool]:
    """Report body-only marker presence in a text blob."""
    return {key: value in text for key, value in markers.items()}


def tool_descriptions(bodies: list[dict[str, Any]]) -> str:
    """Collect tool description/name text from request bodies."""
    chunks: list[str] = []
    for body in bodies:
        tools = body.get("tools", [])
        if isinstance(tools, list):
            for tool in tools:
                if isinstance(tool, dict):
                    for field in ("description", "name"):
                        value = tool.get(field)
                        if isinstance(value, str):
                            chunks.append(value)
    return "\n".join(chunks)


def select_result(results: list[dict[str, Any]], tool_use_id: str) -> dict[str, Any]:
    """Select the single tool_result for a tool_use id; fail closed otherwise."""
    matches = [r for r in results if r.get("tool_use_id") == tool_use_id]
    if len(matches) != 1:
        raise SystemExit(
            f"CHECK FAILED [tool_result {tool_use_id}]: " f"expected exactly 1 match, actual={len(matches)}"
        )
    result = matches[0]
    if not isinstance(result, dict):
        raise SystemExit(f"CHECK FAILED [tool_result {tool_use_id}]: not an object")
    return result


def assert_no_banned_diagnostics(label: str, texts: list[str]) -> None:
    """Fail if install/startup output reports a namespace collision."""
    for index, text in enumerate(texts):
        hit = BANNED_DIAGNOSTICS.search(text)
        if hit:
            raise SystemExit(f"CHECK FAILED [{label} collision diagnostics]: " f"block={index} match={hit.group(0)!r}")


def init_lists(init: dict[str, Any]) -> tuple[list[Any], list[str], list[str]]:
    """Extract plugins/skills/agents from a stream-json init event."""
    plugins = init.get("plugins", [])
    skills = init.get("skills", [])
    agents = init.get("agents", [])
    if not isinstance(plugins, list) or not isinstance(skills, list) or not isinstance(agents, list):
        raise SystemExit("CHECK FAILED [init shape]: plugins/skills/agents must be lists")
    return plugins, [str(s) for s in skills], [str(a) for a in agents]


def assert_shared_init(
    label: str,
    init: dict[str, Any],
    shared: str,
    expected_sources: set[str],
    version: str,
) -> None:
    """Check both same-named plugins load with expected sources and inventory."""
    plugins, skills, agents = init_lists(init)
    named = [p for p in plugins if isinstance(p, dict) and p.get("name") == shared]
    check(label + " plugin count", 2, len(named))
    check(label + " plugin sources", expected_sources, {str(p.get("source")) for p in named})
    expected_dup = EXPECTED_DUP_SKILL_COUNT.get(version)
    if expected_dup is None:
        raise SystemExit(
            f"INCONCLUSIVE [{label} dup skills]: unlisted version {version!r} "
            f"(add expected duplicate-skill count to EXPECTED_DUP_SKILL_COUNT)"
        )
    check(label + " dup skill count", expected_dup, skills.count(shared + ":probe"))
    check(label + " agent present", True, shared + ":worker" in agents)


def assert_distinct_init(
    label: str,
    init: dict[str, Any],
    caller: str,
    worker: str,
    market: str,
) -> None:
    """Check distinct manifests load with exact sources and full inventory."""
    plugins, skills, agents = init_lists(init)
    by_name = {}
    for plugin in plugins:
        if isinstance(plugin, dict):
            by_name[str(plugin.get("name"))] = str(plugin.get("source"))
    check(label + " caller source", caller + "@" + market, by_name.get(caller))
    check(label + " worker source", worker + "@" + market, by_name.get(worker))
    for skill in (caller + ":probe", worker + ":probe"):
        check(label + " skill " + skill, True, skill in skills)
    for agent in (caller + ":worker", worker + ":worker"):
        check(label + " agent " + agent, True, agent in agents)


def assert_cross_init(label: str, init: dict[str, Any], caller: str, worker: str) -> None:
    """Check caller exposes skills only and worker exposes the agent set."""
    _, skills, agents = init_lists(init)
    check(label + " caller skill", True, caller + ":probe" in skills)
    check(label + " worker skill", True, worker + ":probe" in skills)
    for agent in ("worker", "same", "qualified", "bare", "missing"):
        check(label + " worker agent " + agent, True, worker + ":" + agent in agents)
    check(label + " caller has no agents", False, any(s.startswith(caller + ":") for s in agents))


def result_text(result: dict[str, Any]) -> str:
    """Render tool_result content as searchable text."""
    return json.dumps(result.get("content", ""))


def true_keys(markers: dict[str, bool]) -> set[str]:
    """Return the marker map's positive keys."""
    return {key for key, value in markers.items() if value}


def verify_matrix(results: list[dict[str, Any]], version: str, prefix: str) -> None:
    """Check installs, inventory, diagnostics, tool outcomes and marker geography."""
    check("probe count", 15, len(results))
    by = {re.sub(r"-ns-[0-9a-f]+-", "-", r["label"]): r for r in results}
    caller, worker, shared = (prefix + "-" + n for n in ("caller", "worker", "shared"))
    for row in results:
        label = row["label"]
        check(label + " status", "observed", row["status"])
        check(label + " CLI exit", 0, row["exit"])
        check(label + " parent request exists", True, row["parent_requests"] > 0)
        expected = row["expected_plugins"]
        check(label + " installed count", 2, len(expected))
        listing = row["plugin_list"]
        check(label + " listed IDs", set(expected), {p.get("id") for p in listing})
        for plugin in listing:
            check(label + " user scope", "user", plugin.get("scope"))
            check(label + " enabled", True, plugin.get("enabled"))
        plugins, skills, agents = init_lists(row["init"])
        fixture_plugins = [p for p in plugins if p.get("name", "").startswith(prefix)]
        check(label + " init plugin count", 2, len(fixture_plugins))
        check(label + " init plugin sources/names", expected, {p.get("source"): p.get("name") for p in fixture_plugins})
        fixture_skills = [s for s in skills if s.startswith(prefix)]
        fixture_agents = [a for a in agents if a.startswith(prefix)]
        if label.startswith(("mismatched-", "shared-markets-")):
            assert_shared_init(label, row["init"], shared, set(expected), version)
            check(
                label + " exact skills", [shared + ":probe"] * EXPECTED_DUP_SKILL_COUNT.get(version, 0), fixture_skills
            )
            check(label + " exact agents", [shared + ":worker"], fixture_agents)
        elif label.startswith("distinct-"):
            assert_distinct_init(label, row["init"], caller, worker, next(iter(expected)).split("@", 1)[1])
            check(label + " exact skills", sorted([caller + ":probe", worker + ":probe"]), sorted(fixture_skills))
            check(label + " exact agents", sorted([caller + ":worker", worker + ":worker"]), sorted(fixture_agents))
        else:
            assert_cross_init(label, row["init"], caller, worker)
            wanted_skills = [caller + ":" + s for s in ("probe", "cross-dispatch", "missing-dispatch", "cross-preload")]
            wanted_skills += [worker + ":" + s for s in ("probe", "same-dispatch", "local-preload")]
            check(label + " exact skills", sorted(wanted_skills), sorted(fixture_skills))
            check(
                label + " exact agents",
                sorted(worker + ":" + a for a in ("worker", "same", "qualified", "bare", "missing")),
                sorted(fixture_agents),
            )
        assert_no_banned_diagnostics(label, row["install_diagnostics"] + [row["startup_diagnostics"]])
        check(label + " first parent marker absence", set(), true_keys(row["first_parent_markers"]))
        check(label + " tool descriptions marker absence", set(), true_keys(row["tool_description_markers"]))
        agent_result = select_result(row["tool_results"], "toolu_ns_agent")
        if label == "missing-dispatch":
            check(label + " no subagent", 0, row["subagent_requests"])
            check(label + " agent result error", True, agent_result.get("is_error", False))
            text = result_text(agent_result)
            check(label + " error names target", True, row["absent_name"] in text)
            check(label + " error not found", True, "not found" in text)
        else:
            check(label + " agent result success", False, agent_result.get("is_error", False))
            check(label + " child request exists", True, row["subagent_requests"] > 0)
    expectations = {
        "mismatched-ab-shared": ({"a"}, {"b"}, set()),
        "mismatched-ba-shared": ({"b"}, {"a"}, set()),
        "shared-markets-ab-shared": ({"a"}, {"b"}, set()),
        "shared-markets-ba-shared": ({"b"}, {"a"}, set()),
        "distinct-ab-caller": ({"a"}, {"a"}, set()),
        "distinct-ab-worker": ({"b"}, {"b"}, set()),
        "distinct-ba-caller": ({"a"}, {"a"}, set()),
        "distinct-ba-worker": ({"b"}, {"b"}, set()),
        "cross-dispatch": ({"caller"}, {"worker"}, set()),
        "same-dispatch": ({"caller"}, {"worker"}, set()),
        "missing-dispatch": ({"caller"}, set(), set()),
        "preload-same": ({"worker"}, {"worker"}, {"local"}),
        "preload-qualified": ({"worker"}, {"worker"}, {"preload"}),
        "preload-bare": ({"worker"}, {"worker"}, {"preload"}),
        "preload-missing": ({"worker"}, {"worker"}, set()),
    }
    check("scenario labels", set(expectations), set(by))
    for label, (parent, system, messages) in expectations.items():
        row = by[label]
        check(label + " parent payload", parent, true_keys(row["markers_in_parent_messages"]))
        check(label + " child SYSTEM payload", system, true_keys(row["child_system_markers"]))
        check(label + " child MESSAGES payload", messages, true_keys(row["child_messages_markers"]))


def negative_self_test() -> None:
    """Prove check() fails closed on every normal run (no weakened-mode switch)."""
    try:
        check("negative-self-test", {"a"}, set())
    except SystemExit as exc:
        if "negative-self-test" in str(exc):
            return
    raise SystemExit("CHECK FAILED [negative-self-test]: check() did not fail closed")


def digest(path: Path) -> str:
    """Hash file bytes without including them in diagnostic output."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def guarded_json_rel(root: Path, item: Path) -> str | None:
    """Return the key for files compared by semantic JSON digest, else None."""
    rel = item.name if item == root else item.relative_to(root).as_posix()
    # A custom CLAUDE_CONFIG_DIR keeps its .claude.json inside the config directory.
    return rel if rel == CLAUDE_JSON or (item != root and rel in PLUGIN_INDEXES) else None


def is_volatile(rel: str) -> bool:
    """True for config-dir paths that concurrent live Claude sessions rewrite on their own.

    Filename patterns apply only to top-level and plugins/ runtime files, plus the
    plugins/cache/<market>/<plugin>/<version>/.in_use marker, never inside plugin
    payloads, marketplaces, hooks, agents or skills.
    """
    parts = rel.split("/")
    name = parts[-1]
    runtime_file = len(parts) == 1 or (len(parts) == 2 and parts[0] == "plugins")
    return (
        parts[0] in VOLATILE_DIRS
        or "/".join(parts[:2]) in VOLATILE_SUBTREES
        or (len(parts) == 1 and name in VOLATILE_TOP_FILES)
        or (len(parts) == 6 and parts[:2] == ["plugins", "cache"] and name == ".in_use")
        or (runtime_file and (name.startswith((".last-", ".last_")) or VOLATILE_NAME.search(name) is not None))
    )


def strip_timestamps(value: Any) -> Any:
    """Drop the lastUpdated stamps live sessions bump on plugin indexes without other changes."""
    if isinstance(value, dict):
        return {k: strip_timestamps(v) for k, v in value.items() if k not in INDEX_TIMESTAMP_KEYS}
    if isinstance(value, list):
        return [strip_timestamps(v) for v in value]
    return value


def claude_json_guarded(data: dict[str, Any]) -> dict[str, Any]:
    """Keep only the settings-bearing keys of ~/.claude.json (MCP servers, tool permissions)."""
    projects = data.get("projects")
    scoped = {
        name: picked
        for name, entry in (projects.items() if isinstance(projects, dict) else [])
        if isinstance(entry, dict) and (picked := {k: entry[k] for k in CLAUDE_JSON_PROJECT_KEYS if entry.get(k)})
    }
    return {"mcpServers": data.get("mcpServers"), "projects": scoped}


def json_identity(path: Path, rel: str) -> dict[str, Any] | None:
    """Semantic digest of a live-rewritten JSON file; None means hash it strictly instead."""
    for attempt in range(3):
        try:
            data = json.loads(path.read_bytes())
        except (OSError, ValueError):  # a live session may be mid-rewrite: retry, then fail strict
            time.sleep(0.2 * (attempt + 1))
            continue
        if not isinstance(data, dict):
            return None
        guarded = claude_json_guarded(data) if rel == CLAUDE_JSON else strip_timestamps(data)
        return {"json_sha256": hashlib.sha256(json.dumps(guarded, sort_keys=True).encode()).hexdigest()}
    return None


def entry_identity(root: Path, item: Path) -> dict[str, Any]:
    """Identity of one snapshot entry; never follows symlinks or records file contents."""
    if not item.exists() and not item.is_symlink():
        return {"absent": True}
    if item.is_dir() and not item.is_symlink():
        return {"dir": True}  # only roots: nested directories are walked, not recorded
    regular = item.is_file() and not item.is_symlink()
    rel = guarded_json_rel(root, item) if regular else None
    identity = json_identity(item, rel) if rel else None
    if identity is not None:
        return identity
    stat = item.lstat()
    return {
        "mtime_ns": stat.st_mtime_ns,
        "size": stat.st_size,
        "sha256": digest(item) if regular else None,
        "symlink": os.readlink(item) if item.is_symlink() else None,
    }


def snapshot(paths: list[str]) -> dict[str, Any]:
    """Capture guarded content/mtime identity, not secret contents; do not follow symlinks.

    Inside a config directory, volatile live-session state (is_volatile) is skipped and
    nested real directories are not recorded (sessions create ancestors for excluded
    state); every guarded file and file or directory symlink beneath them still is.
    ~/.claude.json and the plugin indexes compare a semantic JSON digest (json_identity).
    Everything else (settings, marketplaces, plugin cache payloads, hooks, agents, skills,
    credentials) stays strict: content digest, size and mtime must not change.
    """
    result: dict[str, Any] = {}
    for raw in paths:
        root = Path(raw)
        items = [root]
        if not root.is_symlink() and root.is_dir():
            for directory, dirs, files in os.walk(root, followlinks=False):
                base = Path(directory)
                dirs[:] = sorted(d for d in dirs if not is_volatile((base / d).relative_to(root).as_posix()))
                # Directory symlinks land in dirs and are not walked: record them like files.
                links = [d for d in dirs if (base / d).is_symlink()]
                kept = (n for n in sorted(files + links) if not is_volatile((base / n).relative_to(root).as_posix()))
                items.extend(base / name for name in kept)
        result.update((str(item), entry_identity(root, item)) for item in items)
    return result


def changed_entries(before: dict[str, Any], after: dict[str, Any]) -> list[str]:
    """Sorted guarded paths that were added, removed or modified between snapshots."""
    return sorted(key for key in before.keys() | after.keys() if before.get(key) != after.get(key))
