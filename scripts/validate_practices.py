#!/usr/bin/env python3
"""Validate authoring practices for ycc skills, agents and root rule docs.

Baseline ratchet: violations listed in scripts/practices-baseline.json are
accepted as frozen state. New violations, stale baseline entries and worsened
numeric sizes fail validation. S2 descriptions >1024 chars or >12000 chars
in aggregate always fail.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml
from description_budget import DESCRIPTION_LIMIT, DESCRIPTION_TOTAL_CAP
from practices_parse import (
    BASELINE_VERSION,
    RULES,
    S7_ITEM,
    has_early_contents,
    load_unique_yaml,
    parse_tools,
    validate_baseline_shape,
)
from practices_rules import (
    AGENTS_LIMIT,
    CLAUDE_LIMIT,
    COMBINED_LIMIT,
    body_import_errors,
    import_errors,
    rule_path_errors,
)

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent

# Current built-in tools per https://code.claude.com/docs/en/tools-reference
BUILTIN_TOOLS = frozenset("""
Agent Artifact AskUserQuestion Bash CronCreate CronDelete CronList Edit
EndConversation EnterPlanMode EnterWorktree ExitPlanMode ExitWorktree Glob Grep
ListAgents ListMcpResourcesTool LSP Monitor NotebookEdit PowerShell
PushNotification Read ReadMcpResourceTool RemoteTrigger ReportFindings
ScheduleWakeup SendFeedback SendMessage SendUserFile ShareOnboardingGuide Skill
SubagentHandback TaskCreate TaskGet TaskList TaskOutput TaskStop TaskUpdate
TodoWrite ToolSearch WaitForMcpServers WebFetch WebSearch Workflow Write
""".split())

# https://code.claude.com/docs/en/skills#frontmatter-reference
SKILL_ALLOWED_KEYS = frozenset("""
name description when_to_use argument-hint arguments disable-model-invocation
user-invocable allowed-tools disallowed-tools model effort context agent
background hooks paths shell metadata license compatibility
""".split())

AGENT_ALLOWED_KEYS = frozenset("""
name description model effort maxTurns tools disallowedTools skills memory
background omitClaudeMd isolation color permissionMode mcpServers hooks initialPrompt
experimental
""".split())

USE_WHEN_RE = re.compile(r"\buse\s+(when|for|after)\b|\bwhen\s+the\s+user\b", re.IGNORECASE)
SKILL_NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
MCP_TOOL_RE = re.compile(r"^mcp__([A-Za-z0-9_-]+?)__([^\s()]+)$")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
MD_LINK_RE = re.compile(r"\[[^\]\n]*\]\(\s*(?:<([^>]+)>|([^)\s]+))")
MD_REFLINK_DEF_RE = re.compile(r"^\s*\[[^\]\n]+\]:\s*(?:<([^>\n]+)>|(\S+))", re.MULTILINE)
HTML_HREF_RE = re.compile(r"\bhref\s*=\s*(['\"])(.*?)\1", re.IGNORECASE)

ROOT_DOC_BUDGETS: tuple[tuple[str, int], ...] = (
    ("CLAUDE.md", CLAUDE_LIMIT),
    ("AGENTS.md", AGENTS_LIMIT),
    ("ycc/settings/rules/CLAUDE.md", 200),
)
RULE_ALLOWED_KEYS = frozenset({"paths"})


@dataclass(frozen=True)
class Violation:
    """One ratcheted violation; `size` carries the frozen numeric value for S1/S2/S7/R1."""

    rule: str
    path: str
    item: str
    size: int | None = None

    @property
    def vid(self) -> str:
        return f"{self.rule}:{self.path}:{self.item}"

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {"id": self.vid}
        if self.size is not None:
            out["size"] = self.size
        return out


@dataclass
class Report:
    """Collected hard errors (always fatal) and ratcheted violations."""

    hard_errors: list[str] = field(default_factory=list)
    violations: list[Violation] = field(default_factory=list)

    def unique_violations(self) -> dict[str, Violation]:
        """Collapse duplicate IDs, preserving the largest observed numeric size."""
        result: dict[str, Violation] = {}
        for v in self.violations:
            previous = result.get(v.vid)
            if previous is None or (v.size is not None and (previous.size is None or v.size > previous.size)):
                result[v.vid] = v
        return result

    def hard(self, rule: str, path: str | Path, msg: str) -> None:
        self.hard_errors.append(f"{rule}:{path}: {msg}")

    def add(self, rule: str, path: str | Path, item: str, size: int | None = None) -> None:
        self.violations.append(Violation(rule, str(path), item, size))


def load_frontmatter(path: Path, rule: str, rep: Report, rel_root: Path) -> tuple[dict[str, Any] | None, list[str]]:
    """Parse strict YAML frontmatter; returns (mapping, body_lines) or (None, [])."""
    rel = str(path.relative_to(rel_root))
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        rep.hard(rule, rel, "missing YAML frontmatter opener '---'")
        return None, []
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        rep.hard(rule, rel, "unterminated YAML frontmatter")
        return None, []
    raw = "\n".join(lines[1:end])
    try:
        data = load_unique_yaml(raw)
    except yaml.YAMLError as exc:
        rep.hard(rule, rel, f"frontmatter is not parseable YAML: {exc}")
        return None, []
    if not isinstance(data, dict):
        rep.hard(rule, rel, "frontmatter is not a YAML mapping")
        return None, []
    for key in data:
        if not isinstance(key, str):
            rep.hard(rule, rel, f"non-string frontmatter key: {key!r}")
            return None, []
    return data, lines[end + 1 :]


def parse_tool_entries(value: Any, rule: str, rel: str, rep: Report) -> list[str] | None:
    """Normalize a tools value; records a hard error and returns None when malformed."""
    try:
        return parse_tools(value)
    except ValueError as exc:
        rep.hard(rule, rel, str(exc))
        return None


def tool_base(entry: str) -> str:
    return entry.split("(", 1)[0].strip()


def check_tools(entries: list[str], rule: str, rel: str, rep: Report, declared_mcp: frozenset[str]) -> None:
    for entry in entries:
        base = tool_base(entry)
        if not base:
            rep.add(rule, rel, f"empty tool entry in {entry!r}")
            continue
        if base in BUILTIN_TOOLS:
            continue
        m = MCP_TOOL_RE.match(base)
        if m:
            server = m.group(1)
            if server in declared_mcp:
                continue
            rep.add(rule, rel, f"tool {entry!r} references undeclared MCP server {server!r}")
        else:
            rep.add(rule, rel, f"unknown tool {entry!r}")


def source_files(root: Path, prefix: str = "") -> frozenset[str]:
    """Repo-relative tracked or untracked-unignored files under prefix that exist on disk.

    Uses git in a checkout; fixture roots without .git walk the filesystem, skipping caches.
    """
    if (root / ".git").exists():
        try:
            cmd = ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
            if prefix:
                cmd.extend(["--", prefix])
            out = subprocess.run(
                cmd,
                check=True,
                capture_output=True,
                text=True,
                env={k: v for k, v in os.environ.items() if not k.startswith("GIT_")},
            ).stdout
            return frozenset(p for p in out.split("\0") if p and (root / p).is_file())
        except (subprocess.CalledProcessError, OSError):
            pass
    base = root / prefix if prefix else root
    if not base.is_dir():
        return frozenset()
    skip = {".git", "node_modules", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".DS_Store"}
    return frozenset(
        str(p.relative_to(root))
        for p in base.rglob("*")
        if p.is_file() and not (skip & set(p.relative_to(root).parts)) and p.suffix not in {".pyc", ".pyo"}
    )


def strip_code(text: str) -> str:
    """Remove fenced blocks and inline code spans to avoid false positives."""
    out, in_fence, fence = [], False, ""
    for line in text.splitlines():
        m = FENCE_RE.match(line)
        if m:
            marker = m.group(1)[0] * 3
            if not in_fence:
                in_fence, fence = True, marker
            elif line.lstrip().startswith(fence):
                in_fence = False
            continue
        if not in_fence:
            out.append(line)
    return INLINE_CODE_RE.sub("", "\n".join(out))


def mentioned(body: str, rel_in_skill: str) -> bool:
    """Require exact references/scripts path, never a basename substring."""
    return bool(re.search(r"(?<![A-Za-z0-9_.-])" + re.escape(rel_in_skill) + r"(?![A-Za-z0-9_/-]|\.[A-Za-z0-9])", body))


def check_skills(root: Path, rep: Report, declared_mcp: frozenset[str]) -> None:
    """Check S1-S6 + S9 for every skill that has a SKILL.md (skips _shared)."""
    skills_dir = root / "ycc" / "skills"
    if not skills_dir.is_dir():
        rep.hard("S1", "ycc/skills", "required skills directory missing")
        return
    tracked = source_files(root, "ycc/skills")
    desc_total = 0
    for skill_md in sorted(skills_dir.glob("*/SKILL.md")):
        rel = str(skill_md.relative_to(root))
        fm, body_lines = load_frontmatter(skill_md, "frontmatter", rep, root)
        if fm is None:
            continue
        name = fm.get("name")
        desc = fm.get("description")
        # S1: body line budget
        size = len(body_lines)
        if size > 500:
            rep.add("S1", rel, "body-lines", size)
        # S2/S3: description
        if not isinstance(desc, str) or not desc.strip():
            rep.hard("S2", rel, "missing or non-string description")
        else:
            desc_total += len(desc)
            if len(desc) > 1024:
                rep.hard("S2", rel, f"description length {len(desc)} exceeds hard cap 1024")
            elif len(desc) > DESCRIPTION_LIMIT:
                rep.add("S2", rel, "description-length", len(desc))
            if not USE_WHEN_RE.search(desc):
                rep.add("S3", rel, "description lacks 'Use when/for/after' or 'when the user'")
        # S4: name
        if not isinstance(name, str):
            rep.hard("S4", rel, "missing or non-string name")
        else:
            if not SKILL_NAME_RE.match(name):
                rep.add("S4", rel, f"name {name!r} not kebab-case lowercase")
            if len(name) > 64:
                rep.add("S4", rel, f"name {name!r} longer than 64 chars")
            if name != skill_md.parent.name:
                rep.add("S4", rel, f"name {name!r} != directory {skill_md.parent.name!r}")
            if re.search(r"claude|anthropic", name):
                rep.add("S4", rel, f"name {name!r} contains claude/anthropic")
        # S5: frontmatter keys
        for key in sorted(fm):
            if key not in SKILL_ALLOWED_KEYS:
                rep.add("S5", rel, f"unknown frontmatter key {key!r}")
        # S6: every tracked file under references/ and scripts/ is named by path
        body = "\n".join(body_lines)
        skill_prefix = str(skill_md.parent.relative_to(root)) + "/"
        owned = sorted(
            f[len(skill_prefix) :]
            for f in tracked
            if f.startswith(skill_prefix) and f[len(skill_prefix) :].split("/", 1)[0] in ("references", "scripts")
        )
        for f in owned:
            if not mentioned(body, f):
                rep.add("S6", rel, f"unmentioned file {f}")
        # S9: allowed-tools
        entries = parse_tool_entries(fm.get("allowed-tools"), "S9", rel, rep)
        if entries:
            check_tools(entries, "S9", rel, rep, declared_mcp)
    if desc_total > DESCRIPTION_TOTAL_CAP:
        rep.hard(
            "S2", "ycc/skills", f"aggregate description length {desc_total} exceeds hard cap {DESCRIPTION_TOTAL_CAP}"
        )


def check_references(root: Path, rep: Report) -> None:
    skills_dir = root / "ycc" / "skills"
    if not skills_dir.is_dir():
        return  # reported by check_skills
    for skill_dir in sorted(skills_dir.iterdir()):
        if not skill_dir.is_dir() or not (skill_dir / "SKILL.md").is_file():
            continue  # skips _shared (no SKILL.md)
        ref_dir = skill_dir / "references"
        if not ref_dir.is_dir():
            continue
        for f in sorted(ref_dir.rglob("*.md")):
            if not f.is_file():
                continue
            frel = str(f.relative_to(root))
            lines = f.read_text(encoding="utf-8").splitlines()
            if len(lines) > 100 and not has_early_contents(lines):
                rep.add("S7", frel, S7_ITEM, len(lines))
            targets: set[str] = set()
            clean = strip_code("\n".join(lines))
            for m in MD_LINK_RE.finditer(clean):
                targets.add(m.group(1) or m.group(2) or "")
            targets.update(m.group(1) or m.group(2) for m in MD_REFLINK_DEF_RE.finditer(clean))
            targets.update(m.group(2) for m in HTML_HREF_RE.finditer(clean))
            for target in sorted(targets):
                core = target.split("#", 1)[0].split("?", 1)[0].strip()
                if core.lower().endswith(".md") and not re.match(r"^[a-z][a-z0-9+.-]*://", core, re.I):
                    rep.add("S8", frel, f"links to {target!r}")


def check_agents(root: Path, rep: Report, declared_mcp: frozenset[str]) -> None:
    agents_dir = root / "ycc" / "agents"
    if not agents_dir.is_dir():
        rep.hard("A1", "ycc/agents", "required agents directory missing")
        return
    for agent_md in sorted(agents_dir.glob("*.md")):
        rel = str(agent_md.relative_to(root))
        fm, _ = load_frontmatter(agent_md, "frontmatter", rep, root)
        if fm is None:
            continue
        for key in sorted(fm):  # A1
            if key not in AGENT_ALLOWED_KEYS:
                rep.add("A1", rel, f"unknown frontmatter key {key!r}")
        entries = parse_tool_entries(fm.get("tools"), "A2", rel, rep)  # A2
        if entries:
            check_tools(entries, "A2", rel, rep, declared_mcp)


def check_root_docs(root: Path, rep: Report) -> None:
    sizes: dict[str, int] = {}
    texts: dict[str, str] = {}
    for rel, limit in ROOT_DOC_BUDGETS:
        path = root / rel
        if not path.is_file():
            rep.hard("R1", rel, "required doc missing")
            continue
        text = path.read_text(encoding="utf-8")
        texts[rel] = text
        size = len(text.splitlines())
        sizes[rel] = size
        if size > limit:
            rep.add("R1", rel, "line-count", size)
    if "AGENTS.md" in sizes and "CLAUDE.md" in sizes:
        combined = sizes["AGENTS.md"] + sizes["CLAUDE.md"]
        if combined > COMBINED_LIMIT:
            rep.add("R1", "CLAUDE.md+AGENTS.md", "combined-line-count", combined)
    if "CLAUDE.md" in texts:
        for err in import_errors(texts["CLAUDE.md"]):
            rep.hard("R1", "CLAUDE.md", err)


def check_claude_rules(root: Path, rep: Report) -> None:
    rules_dir = root / ".claude" / "rules"
    if not rules_dir.is_dir():
        return
    files = source_files(root)
    for rule_file in sorted(rules_dir.rglob("*")):
        if not rule_file.is_file():
            continue
        rel = str(rule_file.relative_to(root))
        if rule_file.suffix != ".md":
            rep.hard("R1", rel, "non-Markdown file under .claude/rules; only .md rule files are allowed")
            continue
        rule_md = rule_file
        fm, body_lines = load_frontmatter(rule_md, "R1", rep, root)
        if fm is None:
            continue
        for key in sorted(fm):
            if key not in RULE_ALLOWED_KEYS:
                rep.hard("R1", rel, f"unknown frontmatter key {key!r}")
        for err in rule_path_errors(fm.get("paths"), files):
            rep.hard("R1", rel, err)
        for err in body_import_errors("\n".join(body_lines)):
            rep.hard("R1", rel, err)


def load_declared_mcp(root: Path, rep: Report) -> frozenset[str]:
    path = root / "mcp-configs" / "mcp.json"
    if not path.is_file():
        rep.hard("A2/S9", "mcp-configs/mcp.json", "required file missing")
        return frozenset()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        rep.hard("A2/S9", "mcp-configs/mcp.json", f"mcp-configs/mcp.json is not valid JSON: {exc}")
        return frozenset()
    if not isinstance(data, dict):
        rep.hard("A2/S9", "mcp-configs/mcp.json", "root must be a JSON object")
        return frozenset()
    servers = data.get("mcpServers")
    if not isinstance(servers, dict):
        rep.hard("A2/S9", "mcp-configs/mcp.json", "missing 'mcpServers' object")
        return frozenset()
    return frozenset(k for k in servers if isinstance(k, str))


def load_baseline(path: Path) -> dict[str, dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SystemExit(f"validate_practices: baseline missing: {path} (create with --write-baseline)") from None
    except json.JSONDecodeError as exc:
        raise SystemExit(f"validate_practices: baseline {path} is not valid JSON: {exc}") from exc
    try:
        entries = validate_baseline_shape(data)
    except ValueError as exc:
        raise SystemExit(f"validate_practices: invalid baseline {path}: {exc}") from exc
    return {e["id"]: e for e in entries}


def collect(root: Path) -> Report:
    rep = Report()
    declared = load_declared_mcp(root, rep)
    check_root_docs(root, rep)
    check_claude_rules(root, rep)
    check_skills(root, rep, declared)
    check_references(root, rep)
    check_agents(root, rep, declared)
    return rep


def print_counts(rep: Report, baseline_size: int | None = None) -> None:
    """Print counts for every rule (including zeros), then the total."""
    counts = dict.fromkeys(RULES, 0)
    for v in rep.unique_violations().values():
        counts[v.rule] += 1
    for rule in RULES:
        print(f"{rule}: {counts[rule]} violation(s)")
    suffix = f", {baseline_size} baselined" if baseline_size is not None else ""
    print(f"total: {sum(counts.values())} violation(s){suffix}")


def write_baseline(rep: Report, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    entries = [v.to_dict() for _, v in sorted(rep.unique_violations().items())]
    payload = {"version": BASELINE_VERSION, "violations": entries}
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def ratchet(rep: Report, baseline: dict[str, dict[str, Any]]) -> int:
    """Compare current violations to baseline. Returns process exit code."""
    print_counts(rep, len(baseline))
    current = rep.unique_violations()
    failures: list[str] = []
    for vid, v in sorted(current.items()):
        entry = baseline.get(vid)
        if entry is None:
            failures.append(f"NEW {vid}")
            continue
        base_size = entry.get("size")
        if v.size is not None and base_size is None:
            failures.append(f"WORSENED {vid} (baseline lacks size, current {v.size})")
        elif v.size is not None and base_size is not None and v.size > base_size:
            failures.append(f"WORSENED {vid} ({base_size} -> {v.size})")
    failures.extend(f"STALE {vid}" for vid in sorted(set(baseline) - set(current)))
    for line in failures:
        print(line)
    for err in rep.hard_errors:
        print(f"HARD {err}")
    if failures or rep.hard_errors:
        return 1
    print("practices: OK (no new, stale or worsened violations)")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="repository root (default: script's repo)")
    parser.add_argument(
        "--baseline", type=Path, default=None, help="baseline JSON (default: <root>/scripts/practices-baseline.json)"
    )
    parser.add_argument(
        "--write-baseline", action="store_true", help="write observed violations to the baseline and exit"
    )
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if not root.is_dir():
        print(f"validate_practices: --root {root} is not a directory", file=sys.stderr)
        return 1
    baseline_path = (args.baseline or root / "scripts" / "practices-baseline.json").resolve()
    rep = collect(root)
    if args.write_baseline:
        if rep.hard_errors:
            for err in rep.hard_errors:
                print(f"HARD {err}")
            print("validate_practices: refusing to write baseline over hard errors", file=sys.stderr)
            return 1
        write_baseline(rep, baseline_path)
        print(f"validate_practices: wrote {len(rep.violations)} baseline violation(s) to {baseline_path}")
        return 0
    baseline = load_baseline(baseline_path)
    return ratchet(rep, baseline)


if __name__ == "__main__":
    sys.exit(main())
