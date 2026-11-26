#!/usr/bin/env python3
"""
Generate the canonical inventory of ycc skills, slash invocations, and agents, and
rewrite the three GENERATED-* regions in README.md.

Outputs:
  docs/inventory.json  -- pretty-printed JSON manifest (sorted, stable key order)
  README.md            -- three marker regions rewritten in-place

Modes:
  (default)   Write both outputs.  Print a summary to stderr.
  --dry-run   Print what would be written without touching files.
  --check     Regenerate in memory, diff against current on-disk state.
              Exits 1 on any difference; exits 0 if everything matches.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml as _yaml

    def _load_yaml(text: str) -> Any:
        return _yaml.safe_load(text)

except ImportError:

    def _load_yaml(text: str) -> Any:
        """Minimal tolerant YAML parser: extracts top-level string scalars only."""
        result: dict[str, Any] = {}
        for line in text.splitlines():
            m = re.match(r"^([a-zA-Z_][a-zA-Z0-9_-]*):\s*(.*)", line)
            if m:
                key, val = m.group(1), m.group(2).strip()
                if val.lower() in {"true", "false"}:
                    result[key] = val.lower() == "true"
                else:
                    result[key] = val.strip("\"'")
        return result


REPO_ROOT = Path(__file__).resolve().parent.parent
SKILLS_DIR = REPO_ROOT / "ycc" / "skills"
AGENTS_DIR = REPO_ROOT / "ycc" / "agents"
INVENTORY_PATH = REPO_ROOT / "docs" / "inventory.json"
README_PATH = REPO_ROOT / "README.md"

SHORT_DESC_LIMIT = 180

# README marker names
MARKER_COUNTS = "GENERATED-COUNTS"
MARKER_COMMANDS = "GENERATED-COMMANDS"
MARKER_AGENTS = "GENERATED-AGENTS"

# Agent categorization for the GENERATED-AGENTS region. New agents that don't
# appear here fall into "Other" and trigger a stderr warning on generation —
# add them to the right category below to silence the warning.
AGENT_CATEGORIES: list[tuple[str, list[str]]] = [
    (
        "Language experts & implementors",
        [
            "frontend-ui-developer",
            "go-api-architect",
            "go-expert-architect",
            "nextjs-ux-ui-expert",
            "nodejs-backend-architect",
            "nodejs-backend-developer",
            "python-developer",
            "python-expert-architect",
            "rust-build-resolver",
            "rust-expert-architect",
            "typescript-developer",
            "typescript-expert-architect",
        ],
    ),
    (
        "Code review & quality",
        [
            "backport-conflict-resolver",
            "code-reviewer",
            "code-simplifier",
            "pr-comment-fixer",
            "release-fix-applier",
            "review-fixer",
            "rust-reviewer",
        ],
    ),
    (
        "Research & discovery",
        [
            "code-explorer",
            "code-finder",
            "code-researcher",
            "codebase-advisor",
            "feature-researcher",
            "library-docs-writer",
            "practices-researcher",
            "prp-researcher",
            "research-specialist",
            "root-cause-analyzer",
        ],
    ),
    (
        "Architecture & planning",
        [
            "architect",
            "architecture-analyst",
            "code-architect",
            "planner",
            "test-strategy-planner",
        ],
    ),
    (
        "Documentation",
        [
            "api-docs-expert",
            "api-documenter",
            "code-documenter",
            "docs-git-committer",
            "documentation-writer",
            "feature-writer",
            "readme-generator",
        ],
    ),
    (
        "Infrastructure & DevOps",
        [
            "ansible-automation-expert",
            "cloudflare-architect",
            "cloudflare-developer",
            "reverse-proxy-architect",
            "systems-engineering-expert",
            "terraform-architect",
            "terraform-developer",
        ],
    ),
    (
        "Databases",
        [
            "db-modifier",
            "sql-database-developer",
            "turso-database-architect",
        ],
    ),
    (
        "Workflow utilities",
        [
            "git-cleanup",
            "implementor",
            "project-file-cleaner",
            "releaser",
        ],
    ),
]


# ---------------------------------------------------------------------------
# Frontmatter parsing
# ---------------------------------------------------------------------------


def _strip_preamble(text: str) -> str:
    """Remove stray lines before the first YAML frontmatter opener."""
    if text.startswith("---"):
        return text
    for i, line in enumerate(text.splitlines(keepends=True)):
        if line.strip() == "---":
            return "".join(text.splitlines(keepends=True)[i:])
    return text


def parse_frontmatter(text: str) -> dict[str, Any]:
    """Return the frontmatter dict from a Markdown file (empty dict if absent)."""
    stripped = _strip_preamble(text)
    if not stripped.startswith("---\n"):
        return {}
    end = stripped.find("\n---\n", 4)
    if end == -1:
        return {}
    raw = stripped[4:end]
    if not raw.strip():
        return {}
    data = _load_yaml(raw)
    if not isinstance(data, dict):
        return {}
    return data


_SENTENCE_END = re.compile(r"(?<=[.!?])\s+")
_TRIGGER_LEAD = re.compile(r"^use when\b", re.IGNORECASE)
_ORDERED_ITEM = re.compile(r"^\d+[.)](\s|$)")


def _sentences(text: str) -> list[str]:
    """Split whitespace-collapsed *text* into sentences on terminal punctuation."""
    return [s for s in _SENTENCE_END.split(text) if s]


def _is_trigger(sentence: str) -> bool:
    """Return True when *sentence* is a "Use when ..." trigger clause."""
    return bool(_TRIGGER_LEAD.match(sentence))


def _fit(sentences: list[str], start: int) -> str:
    """Return sentence *start* if it fits the limit, else truncate from *start*."""
    candidate = sentences[start]
    if len(candidate) <= SHORT_DESC_LIMIT:
        return candidate
    rest = " ".join(sentences[start:])
    return rest[:SHORT_DESC_LIMIT].rstrip() + "..."


def body_lead(body: str) -> str:
    """Return the first prose paragraph of a Markdown body, whitespace-collapsed.

    Headings, emphasis-led callouts, lists, tables, quotes, HTML and code fences
    are skipped so the result is the opening statement of what the file does.
    """
    paragraph: list[str] = []
    in_fence = False
    skipping_block = False
    for raw in body.splitlines():
        line = raw.strip()
        if line.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if not line:
            if paragraph:
                break
            skipping_block = False
            continue
        if paragraph:
            paragraph.append(line)
            continue
        if line.startswith("#"):
            # A heading is one line; prose may follow it directly.
            continue
        if skipping_block or not line[0].isalnum() or _ORDERED_ITEM.match(line):
            # Skip the whole block (list items plus continuation lines,
            # callouts, tables, quotes, HTML) up to the next blank line.
            skipping_block = True
            continue
        paragraph.append(line)
    return " ".join(" ".join(paragraph).split())


def short_description(full: str, body: str = "") -> str:
    """Return a single-line capability summary of a description for the README table.

    Prefers the first description sentence that is not a "Use when ..." trigger
    clause. When every description sentence is a trigger, uses the first sentence
    of the first prose paragraph in *body* (the SKILL.md body), then falls back to
    the first description sentence.
    """
    if not full:
        return ""
    # Collapse newlines and extra whitespace
    single = re.sub(r"\s+", " ", str(full)).strip()
    sentences = _sentences(single)
    if not sentences:
        return ""
    for index, sentence in enumerate(sentences):
        if not _is_trigger(sentence):
            return _fit(sentences, index)
    lead = _sentences(body_lead(body))
    if lead and not _is_trigger(lead[0]):
        return _fit(lead, 0)
    return _fit(sentences, 0)


def skill_body(name: str) -> str:
    """Return the Markdown body (after frontmatter) of skill *name*, or ""."""
    skill_md = SKILLS_DIR / name / "SKILL.md"
    if not skill_md.is_file():
        return ""
    text = _strip_preamble(skill_md.read_text(encoding="utf-8"))
    if not text.startswith("---\n"):
        return ""
    end = text.find("\n---\n", 4)
    return "" if end == -1 else text[end + 5 :]


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------


def discover_skills() -> list[dict[str, str]]:
    """Return sorted list of {name, description} dicts for all valid skills."""
    entries: list[dict[str, str]] = []
    for skill_dir in sorted(SKILLS_DIR.iterdir()):
        if not skill_dir.is_dir():
            continue
        if skill_dir.name.startswith("_"):
            continue
        skill_md = skill_dir / "SKILL.md"
        if not skill_md.exists():
            continue
        fm = parse_frontmatter(skill_md.read_text(encoding="utf-8"))
        entries.append(
            {
                "name": fm.get("name") or skill_dir.name,
                "description": str(fm.get("description") or ""),
            }
        )
    return sorted(entries, key=lambda e: e["name"])


def discover_commands() -> list[dict[str, str]]:
    """Return slash invocations from public skills (user-invocable defaults true)."""
    entries: list[dict[str, str]] = []
    for skill_md in sorted(SKILLS_DIR.glob("*/SKILL.md")):
        if skill_md.parent.name.startswith("_"):
            continue
        fm = parse_frontmatter(skill_md.read_text(encoding="utf-8"))
        if fm.get("user-invocable") is False:
            continue
        entries.append(
            {
                "name": skill_md.parent.name,
                "description": str(fm.get("description") or ""),
            }
        )
    return sorted(entries, key=lambda e: e["name"])


def discover_agents() -> list[dict[str, str]]:
    """Return sorted list of {name, description} dicts for all agent *.md files."""
    entries: list[dict[str, str]] = []
    for agent_md in sorted(AGENTS_DIR.glob("*.md")):
        fm = parse_frontmatter(agent_md.read_text(encoding="utf-8"))
        entries.append(
            {
                "name": agent_md.stem,
                "description": str(fm.get("description") or ""),
            }
        )
    return sorted(entries, key=lambda e: e["name"])


# ---------------------------------------------------------------------------
# Inventory JSON builder
# ---------------------------------------------------------------------------


def build_inventory(
    skills: list[dict[str, str]],
    commands: list[dict[str, str]],
    agents: list[dict[str, str]],
) -> dict[str, Any]:
    return {
        "skills": skills,
        "commands": commands,
        "agents": agents,
        "counts": {
            "skills": len(skills),
            "commands": len(commands),
            "agents": len(agents),
        },
    }


def render_inventory_json(inventory: dict[str, Any]) -> str:
    return json.dumps(inventory, indent=2) + "\n"


# ---------------------------------------------------------------------------
# README region rewriting
# ---------------------------------------------------------------------------


def _region_pattern(marker: str) -> re.Pattern[str]:
    """Return a compiled regex that matches the full BEGIN/END block for *marker*.

    Both markers must be alone on their own line — this prevents documentation
    that mentions the marker names (e.g. inside backticks or list items) from
    being accidentally rewritten.
    """
    return re.compile(
        r"^<!-- BEGIN:" + re.escape(marker) + r" -->$" r".*?" r"^<!-- END:" + re.escape(marker) + r" -->$",
        re.DOTALL | re.MULTILINE,
    )


def render_counts_region(
    skills: list[dict[str, str]],
    commands: list[dict[str, str]],
    agents: list[dict[str, str]],
) -> str:
    ns, nc, na = len(skills), len(commands), len(agents)
    body = f"The source plugin ships **{ns} skills**, " f"**{nc} slash-invocable skills**, " f"and **{na} agents**."
    return f"<!-- BEGIN:{MARKER_COUNTS} -->\n\n{body}\n\n<!-- END:{MARKER_COUNTS} -->"


def render_commands_region(commands: list[dict[str, str]]) -> str:
    # Emit a markdown table whose column widths match what Prettier would produce
    # after formatting: each column padded to the widest cell in that column.
    headers = ("Command / Skill", "Purpose")
    rows: list[tuple[str, str]] = []
    for cmd in commands:
        col1 = f"`/ycc:{cmd['name']}`"
        col2 = short_description(cmd["description"], skill_body(cmd["name"]))
        rows.append((col1, col2))

    w1 = max(len(headers[0]), *(len(r[0]) for r in rows))
    w2 = max(len(headers[1]), *(len(r[1]) for r in rows))

    lines = [
        f"| {headers[0]:<{w1}} | {headers[1]:<{w2}} |",
        f"| {'-' * w1} | {'-' * w2} |",
    ]
    lines.extend(f"| {r[0]:<{w1}} | {r[1]:<{w2}} |" for r in rows)
    table = "\n".join(lines)

    return f"<!-- BEGIN:{MARKER_COMMANDS} -->\n\n" f"{table}\n\n" f"<!-- END:{MARKER_COMMANDS} -->"


def _group_agents(agents: list[dict[str, str]]) -> list[tuple[str, list[str]]]:
    """Group agent names by category. Uncategorized agents land in 'Other'.

    Emits a stderr warning for any uncategorized agent so new additions don't
    silently drift out of the grouped listing.
    """
    known: dict[str, str] = {}
    for category, names in AGENT_CATEGORIES:
        for n in names:
            known[n] = category

    by_category: dict[str, list[str]] = {c: [] for c, _ in AGENT_CATEGORIES}
    uncategorized: list[str] = []
    agent_names = {a["name"] for a in agents}

    for name in sorted(agent_names):
        known_category = known.get(name)
        if known_category is None:
            uncategorized.append(name)
        else:
            by_category[known_category].append(name)

    if uncategorized:
        print(
            f"  warning: uncategorized agents (added to 'Other'): {', '.join(uncategorized)}",
            file=sys.stderr,
        )
        by_category["Other"] = uncategorized

    # Preserve declared category order; append 'Other' last if present.
    result = [(c, by_category[c]) for c, _ in AGENT_CATEGORIES if by_category.get(c)]
    if uncategorized:
        result.append(("Other", uncategorized))
    return result


def render_agents_region(agents: list[dict[str, str]]) -> str:
    na = len(agents)
    summary = (
        f"The plugin bundles **{na}** specialized agents covering codebase analysis, "
        "language experts (Go, Rust, Python, TypeScript), reviewers, planners, "
        "documenters, and infrastructure architects."
    )
    grouped = _group_agents(agents)
    group_lines = [
        f"- **{category}** ({len(names)}): {', '.join(f'`{n}`' for n in names)}" for category, names in grouped
    ]
    body = (
        summary + "\n\n"
        "<details>\n"
        f"<summary>Full agent list ({na} agents, grouped by role)</summary>\n\n" + "\n".join(group_lines) + "\n\n"
        "</details>"
    )
    return f"<!-- BEGIN:{MARKER_AGENTS} -->\n\n{body}\n\n<!-- END:{MARKER_AGENTS} -->"


def rewrite_readme(
    readme_text: str,
    skills: list[dict[str, str]],
    commands: list[dict[str, str]],
    agents: list[dict[str, str]],
) -> str:
    """Return readme_text with all three GENERATED-* regions replaced."""
    result = readme_text

    result = _region_pattern(MARKER_COUNTS).sub(render_counts_region(skills, commands, agents), result)
    result = _region_pattern(MARKER_COMMANDS).sub(render_commands_region(commands), result)
    result = _region_pattern(MARKER_AGENTS).sub(render_agents_region(agents), result)
    return result


# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------


def run_generate(
    skills: list[dict[str, str]],
    commands: list[dict[str, str]],
    agents: list[dict[str, str]],
    inventory: dict[str, Any],
    dry_run: bool,
) -> None:
    json_content = render_inventory_json(inventory)
    readme_text = README_PATH.read_text(encoding="utf-8")
    new_readme = rewrite_readme(readme_text, skills, commands, agents)

    if dry_run:
        print(f"Would write {INVENTORY_PATH.relative_to(REPO_ROOT)} ({len(json_content)} bytes):")
        print("--- inventory.json (first 40 lines) ---")
        for line in json_content.splitlines()[:40]:
            print(line)
        print()
        print(f"Would rewrite {README_PATH.relative_to(REPO_ROOT)} ({len(new_readme)} bytes)")
        print("--- GENERATED-COUNTS region ---")
        print(render_counts_region(skills, commands, agents))
        print()
        print("--- GENERATED-COMMANDS region (first 10 rows) ---")
        cmd_region_lines = render_commands_region(commands).splitlines()
        for line in cmd_region_lines[:12]:
            print(line)
        if len(cmd_region_lines) > 12:
            print(f"  ... ({len(cmd_region_lines) - 12} more lines)")
        print()
        print("--- GENERATED-AGENTS region ---")
        print(render_agents_region(agents))
    else:
        INVENTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
        INVENTORY_PATH.write_text(json_content, encoding="utf-8")
        print(f"Wrote {INVENTORY_PATH.relative_to(REPO_ROOT)}", file=sys.stderr)
        README_PATH.write_text(new_readme, encoding="utf-8")
        print(f"Rewrote {README_PATH.relative_to(REPO_ROOT)}", file=sys.stderr)

    _print_summary(skills, commands, agents)


def run_check(
    skills: list[dict[str, str]],
    commands: list[dict[str, str]],
    agents: list[dict[str, str]],
    inventory: dict[str, Any],
) -> int:
    """Check mode: regenerate in memory and diff against on-disk state."""
    diffs: list[str] = []

    # Check inventory.json via SEMANTIC compare. Byte-for-byte comparison is
    # fragile: downstream formatters (prettier, jq, IDE on-save hooks) rewrite
    # whitespace and array layout in ways that don't change the data but do
    # drift the bytes. We care whether the inventory DATA is correct, not
    # whether it was last touched by Python or prettier.
    json_content = render_inventory_json(inventory)
    if not INVENTORY_PATH.exists():
        diffs.append(f"MISSING: {INVENTORY_PATH.relative_to(REPO_ROOT)}")
    else:
        existing_raw = INVENTORY_PATH.read_text(encoding="utf-8")
        try:
            existing_data = json.loads(existing_raw)
        except json.JSONDecodeError as exc:
            diffs.append(f"INVALID JSON: {INVENTORY_PATH.relative_to(REPO_ROOT)} ({exc})")
            existing_data = None
        if existing_data is not None and existing_data != inventory:
            diffs.append(f"DRIFT: {INVENTORY_PATH.relative_to(REPO_ROOT)}")
            _show_text_diff(existing_raw, json_content, str(INVENTORY_PATH.relative_to(REPO_ROOT)))

    # Check README.md regions
    if not README_PATH.exists():
        diffs.append(f"MISSING: {README_PATH.relative_to(REPO_ROOT)}")
    else:
        readme_text = README_PATH.read_text(encoding="utf-8")
        new_readme = rewrite_readme(readme_text, skills, commands, agents)
        if readme_text != new_readme:
            diffs.append(f"DRIFT: {README_PATH.relative_to(REPO_ROOT)} (GENERATED-* regions)")
            _show_text_diff(readme_text, new_readme, str(README_PATH.relative_to(REPO_ROOT)))

    if diffs:
        print("Inventory is out of date. Run: python3 scripts/generate_inventory.py", file=sys.stderr)
        for line in diffs:
            print(f"  {line}", file=sys.stderr)
        return 1

    print("Inventory is up to date.", file=sys.stderr)
    _print_summary(skills, commands, agents)
    return 0


def _show_text_diff(old: str, new: str, label: str) -> None:
    """Print a simple unified-style summary of changed lines."""
    old_lines = old.splitlines()
    new_lines = new.splitlines()
    changed = sum(1 for a, b in zip(old_lines, new_lines, strict=False) if a != b)
    added = max(0, len(new_lines) - len(old_lines))
    removed = max(0, len(old_lines) - len(new_lines))
    print(
        f"    {label}: ~{changed} changed line(s), +{added}/-{removed} lines",
        file=sys.stderr,
    )


def _print_summary(
    skills: list[dict[str, str]],
    commands: list[dict[str, str]],
    agents: list[dict[str, str]],
) -> None:
    print(
        f"Summary: {len(skills)} skills, {len(commands)} slash invocations, {len(agents)} agents",
        file=sys.stderr,
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be written without touching files",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help=(
            "Regenerate in memory and diff against docs/inventory.json and "
            "README.md GENERATED-* regions. Exit 1 on any difference."
        ),
    )
    args = parser.parse_args()

    skills = discover_skills()
    commands = discover_commands()
    agents = discover_agents()
    inventory = build_inventory(skills, commands, agents)

    if args.check:
        sys.exit(run_check(skills, commands, agents, inventory))

    run_generate(skills, commands, agents, inventory, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
