#!/usr/bin/env python3
"""
Generate OMP (oh-my-pi) skills under packages/omp/ycc/skills from ycc/skills.

Every source skill and the single `_shared` closure are emitted exactly once.
`_shared` gains a generated hidden stub SKILL.md (`name: ycc-shared`) so other
skills reach it as `skill://ycc-shared/<path>`. Transforms are deterministic
and idempotent. Source of truth: ycc/skills/
"""

from __future__ import annotations

import argparse
import os
import re
import stat
import sys
import tempfile
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from generate_codex_common import (
    VERBATIM_SKILL_FILES,
    drop_self_fallbacks,
    dump_frontmatter,
    fix_mcp_malformed_tokens,
    load_agent_aliases,
    model_invocation_disabled,
    parse_frontmatter,
    protect_marked_verbatim_blocks,
    restore_marked_verbatim_blocks,
)

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
SRC_DIR = REPO_ROOT / "ycc" / "skills"
DST_DIR = REPO_ROOT / "packages/omp/ycc/skills"

SHARED_DIR_NAME = "_shared"
SHARED_SKILL_NAME = "ycc-shared"
SHARED_STUB_REL = Path(SHARED_DIR_NAME) / "SKILL.md"
SHARED_STUB = (
    "---\n"
    f"name: {SHARED_SKILL_NAME}\n"
    "description: Shared ycc references, scripts and templates used by the other ycc skills. "
    "Not a standalone workflow.\n"
    "hide: true\n"
    "disable-model-invocation: true\n"
    "---\n"
    "\n"
    "# ycc shared resources\n"
    "\n"
    "Support files for the ycc skills. Skills read them as `skill://ycc-shared/<path>`, for example\n"
    "`skill://ycc-shared/references/forge-detection.md`. Do not invoke this skill directly.\n"
)

TEAM_DISPATCH_REL = Path(SHARED_DIR_NAME) / "references" / "agent-team-dispatch.md"
TEAM_DISPATCH_NOTE = (
    "# Agent Team Dispatch\n"
    "\n"
    "Agent teams (`--team`) are unsupported on OMP. Abort if requested and rerun without `--team`\n"
    "using standalone dispatch.\n"
)

# Sections 1-7 of the OMP standalone-dispatch reference come from this template; the
# dispatch-independent sections 8-10 come from the canonical source (opencode precedent).
STANDALONE_DISPATCH_REL = Path(SHARED_DIR_NAME) / "references" / "standalone-dispatch.md"
STANDALONE_DISPATCH_TEMPLATE = SCRIPT_DIR / "omp_templates" / "standalone-dispatch.md"
TEMPLATE_SECTIONS = tuple(range(1, 8))
CANONICAL_SECTIONS = (8, 9, 10)
_NUMBERED_SECTION = re.compile(r"^## (\d+)\.\s", re.MULTILINE)

# OMP keeps skill-managed worktrees under <repo-root>/.omp/worktrees (D1). Applied to
# markdown and scripts, so worktree-paths.sh's @YCC_DEFAULT_WORKTREE_ROOT@ line emits
# `.omp`; verbatim blocks keep the multi-runtime tables intact.
WORKTREE_ROOT_REWRITE = ("/.claude/worktrees", "/.omp/worktrees")

# Claude dispatch arguments -> OMP `task` item fields (D5). `isolation: "worktree"`
# only ever appears in "never pass" rules, which keep their meaning as `isolated: true`.
_DISPATCH_WORDING: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\bsubagent_type\b"), "agent"),
    (re.compile(r"\bisolation\s*[:=]\s*\"worktree\""), "isolated: true"),
)

# Claude `Agent` call fields inside a dispatch paragraph (a blank-line-delimited block
# naming `subagent_type`) -> OMP item fields: `prompt` -> `task`, `description` -> `name`
# (dropped where the block already sets a `name` field), and every bullet, table or
# code field list gains `solutionSpace`. Prose outside such paragraphs, frontmatter and
# `todo` registrations are untouched.
_PARAGRAPH_BREAK = re.compile(r"(\n[ \t]*\n)")
_DISPATCH_MARKER = re.compile(r"\bsubagent_type\b")
_NAME_FIELD = re.compile(r"^[ \t]*-[ \t]*`name`:|^[ \t]*name\s*=\s*\"", re.MULTILINE)
_DESCRIPTION_BULLET = re.compile(r"^(?P<indent>[ \t]*)- `description`:[ \t]*(?P<value>.*)\n?", re.MULTILINE)
_PROMPT_BULLET = re.compile(r"^(?P<indent>[ \t]*)- `prompt`:(?P<rest>.*)$", re.MULTILINE)
_DESCRIPTION_ROW = re.compile(
    r"^\|(?P<pad>[ \t]*)description[ \t]*\|[ \t]*(?P<value>.*?)[ \t]*\|[ \t]*$\n?", re.MULTILINE
)
_PROMPT_ROW = re.compile(r"^\|(?P<pad>[ \t]*)prompt[ \t]*\|(?P<rest>.*)$", re.MULTILINE)
_DESCRIPTION_CODE = re.compile(
    r"^(?P<indent>[ \t]*)description(?P<eq>\s*=\s*)\"(?P<value>[^\"\n]*)\"(?P<tail>,?)[ \t]*\n", re.MULTILINE
)
_PROMPT_CODE = re.compile(r"^(?P<indent>[ \t]*)prompt(?P<eq>\s*=\s*)(?P<value>\"[^\"\n]*\")", re.MULTILINE)
_DESCRIPTION_INLINE = re.compile(r"`description=\"(?P<value>[^\"\n]*)\"`")
_PROMPT_INLINE = re.compile(r"`prompt=(?P<value>\"[^\"\n]*\")`")
_FIELD_SPAN = {"`description`": "`name`", "`prompt`": "`task`"}
_SOLUTION_SPACE = "how open-ended the work is (item shape: `skill://ycc-shared/references/standalone-dispatch.md` §1)"
# Generated OMP text: a paragraph that sets an OMP `agent` field must not keep Claude fields.
_OMP_AGENT_FIELD = re.compile(r"`agent`|\bagent\s*[:=]\s*[\"`\w]|^\|[ \t]*agent[ \t]*\|", re.MULTILINE)
_CLAUDE_DISPATCH_FIELD = re.compile(
    r"`(?:description|prompt)`|\b(?:description|prompt)\s*=\s*\"|^\|[ \t]*(?:description|prompt)[ \t]*\|",
    re.MULTILINE,
)

# Claude reserves `name` for teammates, so its standalone rules say "omit `name`". An OMP
# `task` item always carries `name` as its job label (template section 1), so those
# clauses are dropped from generated markdown; the scanner flags any that survive.
_NAME_OMISSION_REWRITES: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r" \(omit `name`(?: for standalone (?:dispatch|calls))?\)"), ""),
    (re.compile(r"\(standalone — no `name`\)"), "(standalone)"),
    (re.compile(r"\bNo `name` — standalone dispatch\."), "Standalone dispatch."),
    (re.compile(r"\bNo `name`\. "), ""),
)
_NAME_OMISSION_RULE = re.compile(r"\b(?:[Oo]mit|[Nn]o|[Ww]ithout)\s+`name`")
_OMP_DISPATCH_CONTEXT = re.compile(r"`task`|`agent`|\bagent\s*[:=]\s*[\"`\w]")

# Team advisories name OMP too (D7): on lines about teams only.
_TEAM_LINE = re.compile(r"\bteam", re.IGNORECASE)
_TEAM_ADVISORY_WORDING: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\bCursor and Codex\b"), "Cursor, Codex and OMP"),
    (re.compile(r"\bCursor or Codex\b"), "Cursor, Codex or OMP"),
    (re.compile(r"\bCursor/Codex\b(?!/OMP)"), "Cursor/Codex/OMP"),
)

# Frontmatter keys OMP keeps; `allowed-tools` has no OMP semantics (spike §2.8).
KEPT_FRONTMATTER_KEYS = ("name", "description", "argument-hint", "disable-model-invocation")

# Maintainer-only source-authoring guidance: it tells authors what to write into the
# canonical ycc/skills tree, so `${CLAUDE_PLUGIN_ROOT}` stays literal (opencode's
# REPOSITORY_LAYOUT_FILES precedent). Paths are source-relative to ycc/skills/.
REPOSITORY_LAYOUT_FILES: frozenset[str] = frozenset(
    {
        "bundle-author/references/surface-map.md",
        "bundle-author/references/when-not-to-scaffold.md",
        "bundle-author/references/templates/skill-template.md",
    }
)

MARKDOWN_SUFFIXES = frozenset({".md", ".mdc"})
SCRIPT_SUFFIXES = frozenset({".sh", ".bash", ".py"})

PLUGIN_ROOT_TOKEN = "CLAUDE_PLUGIN_ROOT"
_PATH_TAIL = r"([^\s\"'`()\[\]|,;]*)"
_PLUGIN_SKILL_PATH = re.compile(r"\$\{CLAUDE_PLUGIN_ROOT\}/skills/" + _PATH_TAIL)
_RELATIVE_SHARED_LINK = re.compile(r"(?<![\w./-])(?:\.\./)+_shared/" + _PATH_TAIL)
_SCRIPT_FALLBACK = re.compile(
    r"(?P<lhs>\b[A-Za-z_][A-Za-z0-9_]*=)\"\$\{CLAUDE_PLUGIN_ROOT\}/skills/(?P<path>[^\"\s]+)\""
)
_PATTERN_CHARS = frozenset("*?[]{}<>$")

_REF = r"([A-Za-z0-9][A-Za-z0-9-]*)"
_SUBAGENT_REF = re.compile(r"(subagent_type`?\s*(?:[:=]|is)\s*[`\"']*)ycc:" + _REF)
_AGENT_SUFFIX_REF = re.compile(r"(?<![\w/])ycc:" + _REF + r"(?=`?\s+agent\b)")
_MANAGED_BLOCK_REF = re.compile(r"\bycc:" + _REF + r"(?= managed block)")
_SLASH_REF = re.compile(r"/ycc:" + _REF)
_BARE_REF = re.compile(r"\bycc:" + _REF)
_PROTECTED_NAMES = frozenset({"verbatim-block"})

# Claude tool identifiers -> OMP tools (D8). Code (fences and inline spans) gets bare
# names so backticks never nest; prose gets backticked names.
_TODO_TOOLS = r"(?:TodoWrite|TaskCreate|TaskUpdate|TaskList|TaskGet)"
_CODE_TOOL_WORDING: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\b(?:Agent|Task) tool\b"), "task tool"),
    (re.compile(r"\bAgent(?=\()"), "task"),
    (re.compile(r"\b" + _TODO_TOOLS + r"\b"), "todo"),
    (re.compile(r"\bAskUserQuestion\b"), "ask"),
    (re.compile(r"\bWebSearch\b"), "web_search"),
    (re.compile(r"\bWebFetch\b"), "read"),
)
_PROSE_TOOL_WORDING: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\b(?:Agent|Task) tool\b"), "`task` tool"),
    (re.compile(r"\bAgent (calls?)\b"), r"`task` \1"),
    (re.compile(r"\bAgent(?=\()"), "task"),
    (re.compile(r"\bAskUserQuestion\b"), "`ask`"),
    (re.compile(r"\bWebSearch\b"), "`web_search`"),
    (re.compile(r"\bWebFetch\b"), "`read` (URL)"),
    (re.compile(r"\b" + _TODO_TOOLS + r"\b"), "`todo`"),
)
# Sentences whose meaning lives in which tool each path uses, keyed by the source file
# that holds them; rewritten before tool mapping. Generation fails when a listed file
# or sentence is gone, so rewording the source cannot silently skip the rewrite.
PathSentences = Mapping[str, tuple[tuple[str, str], ...]]
PATH_TOOL_SENTENCES: PathSentences = {
    "orchestrate/references/dispatch-playbook.md": (
        (
            "via `TaskCreate`/`TaskUpdate` (Path A) or `TaskList` (Path B)",
            "via `todo` (Path A creates and updates tasks; Path B lists them)",
        ),
        (
            "`TaskCreate`/`TaskUpdate` in Path A, `TaskList` in Path B",
            "`todo` (create and update tasks in Path A, list them in Path B)",
        ),
    ),
}
# Dispatch sentences whose Claude semantics (`run_in_background`, "end the turn",
# `TaskList` monitoring, `Agent(...)` examples) are wrong on OMP, keyed by source file;
# applied before every other rewrite and drift-checked like PATH_TOOL_SENTENCES. The
# standalone-dispatch §3/§7 entries pin the source wording the OMP template mirrors.
_MONITOR_PROGRESS = (
    "**Monitor progress** - Use TaskList to check when all tasks complete",
    "**Monitor progress** - Call `wait` until every spawned job settles",
)
_PLAYBOOK_PROMPT = (
    '"Working directory: <repo-root>/.claude/worktrees/<repo>-<FEATURE_SLUG>/\\n'
    "All parallel agents in this batch share this path; batching guarantees no two agents touch the same file."
    '\\n\\n[substituted template with Path A coordination block]"'
)
# (agent, Claude description, OMP CamelCase name) for the three Path A example calls.
_PLAYBOOK_AGENTS = (
    ("nodejs-backend-architect", "Implement auth system", "ImplementAuthSystem"),
    ("test-strategy-planner", "Create auth test plan", "AuthTestPlan"),
    ("documentation-writer", "Document auth API", "AuthApiDocs"),
)
_PLAYBOOK_PATH_A_SOURCE = (
    "```\n"
    + "".join(
        f'Agent(\n  subagent_type = "{agent}",\n  description = "{title}",\n  prompt = {_PLAYBOOK_PROMPT}\n)\n'
        for agent, title, _ in _PLAYBOOK_AGENTS
    )
    + "```"
)
_PLAYBOOK_PATH_A_OMP = (
    "```\ntask({\n"
    '  context: "<task goal and the Path A coordination background shared by every subtask>",\n'
    "  tasks: [\n"
    + ",\n".join(
        f'    {{ agent: "{agent}", name: "{name}",\n'
        f"      task: {_PLAYBOOK_PROMPT},\n"
        '      solutionSpace: "<how open-ended>" }'
        for agent, _, name in _PLAYBOOK_AGENTS
    )
    + "\n  ]\n})\n```\n\nThen call `wait` until every job of the batch has settled."
)
OMP_DISPATCH_SENTENCES: PathSentences = {
    "_shared/references/standalone-dispatch.md": (
        (
            "If results are pending and the runtime offers a wait tool, call it until every dispatched\n"
            "job has settled; otherwise end the turn so completion notifications can arrive.",
            "If results are pending, call `wait` until every dispatched job has settled.",
        ),
        (
            "OMP dispatches through one `task` batch, ships no team tools, and fails `--team` closed.",
            "OMP dispatches through one `task` batch and fails `--team` closed.",
        ),
        (
            "Applies to standalone and `--team` runs.",
            "Applies to standalone runs; `--team` is unsupported on OMP (section 7).",
        ),
        (
            'Never pass `isolation: "worktree"` or\n'
            '`Agent(isolation: "worktree")`; it creates separate harness worktrees. Codex/opencode: prompt line is\n'
            "sufficient. Cursor: warn and print the manual `git worktree add` command.",
            "Never set `isolated` on a `task` item: it makes a separate `~/.omp/wt` copy per agent and\n"
            "breaks the single-worktree contract. The prompt line is sufficient.",
        ),
        (
            "Dispatch each batch as one message;\nwait for the whole batch before the next.",
            "Dispatch each batch as one `task` call;\n`wait` for the whole batch before the next.",
        ),
        (
            "with one `ycc:implementor` `Agent` per step in one message;",
            "with one `ycc:implementor` item per step in one `task` batch;",
        ),
    ),
    "_shared/references/review-dispatch.md": (
        (
            "in parallel in a single\nmessage with multiple `Agent` calls.",
            "in one `task` batch\n(one `tasks[]` item each).",
        ),
        (
            "if results are pending and the runtime\noffers a wait tool, call it until every reviewer job has settled;",
            "if results are pending, call `wait`\nuntil every reviewer job has settled;",
        ),
        ("After all 3 `Agent` calls return,", "After all 3 reviewer jobs settle,"),
    ),
    "_shared/references/review-checklist.md": (
        (
            "dispatched via `Agent` without\n`name` or `run_in_background` (Path B),",
            "dispatched in one `task` batch\n(Path B),",
        ),
    ),
    "prp-plan/SKILL.md": (
        (
            "Dispatch without `name` or `run_in_background`. Results may arrive asynchronously; "
            "wait for all results before synthesis and end the turn while results are pending.",
            "Dispatch every researcher in one `task` batch. Results arrive as background jobs; "
            "call `wait` until every job settles before synthesis, and never end the turn while one is pending.",
        ),
    ),
    "orchestrate/references/dispatch-playbook.md": (
        (
            "One message, multiple calls, no `name`, no `run_in_background`.",
            "One `task` call with one `tasks[]` item per subtask.",
        ),
        (_PLAYBOOK_PATH_A_SOURCE, _PLAYBOOK_PATH_A_OMP),
    ),
    "feature-research/templates/research-agents.md": (_MONITOR_PROGRESS,),
    "implement-plan/SKILL.md": (
        (
            '`description="Implement [Task ID]: [Title]"`, full substituted template.',
            '`name="Impl<TaskId>"`, `task=` the full substituted template, `solutionSpace="<how open-ended>"`.',
        ),
    ),
    "plan/references/enhanced-personas.md": (
        (
            "distinguished by `description` and the role-specific prompt in standalone mode; "
            "only team mode sets `name`.",
            "distinguished by the item `name` (role) and the role-specific `task` prompt.",
        ),
    ),
    "plan-workflow/references/planning-agents.md": (_MONITOR_PROGRESS,),
    "plan-workflow/references/research-agents.md": (_MONITOR_PROGRESS,),
    "plan-workflow/references/validation-agents.md": (_MONITOR_PROGRESS,),
}

# Forbidden Claude workflow semantics in the generated OMP package (AC1). Allowed only
# in multi-runtime text: whole verbatim files (paths relative to packages/omp/ycc) and
# line-anchored rows of the worktree-strategy runtime table.
FORBIDDEN_SEMANTICS = re.compile(
    r"subagent_type|run_in_background|isolation\s*[:=]\s*\"worktree\"|AskUserQuestion|TaskOutput|BashOutput"
    r"|/\.claude/worktrees"
)
SEMANTICS_ALLOWED_FILES: frozenset[str] = frozenset({"skills/_shared/references/target-capability-matrix.md"})
SEMANTICS_ALLOWED_LINES: Mapping[str, tuple[re.Pattern[str], ...]] = {
    "skills/_shared/references/worktree-strategy.md": (
        re.compile(
            r"^\| Claude Code +\| `<repo-root>/\.claude/worktrees/` +\| source default \(`worktree-paths\.sh`\) +\|$"
        ),
        re.compile(r"^ *`<repo-root>/\.claude/worktrees` and honors `YCC_WORKTREE_ROOT`\. Without the$"),
    ),
}
_FENCE = re.compile(r"^[ \t]*(?:```|~~~)")
_CODE_SPAN = re.compile(r"(`[^`\n]+`)")
_SPAN = r"`[^`\n]+`"
_LIST_SEP = r"(?:[ \t]*/[ \t]*|,\s+(?:(?:and|or)\s+)?|\s+(?:and|or)\s+)"
_SPAN_LIST = re.compile(_SPAN + r"(?:" + _LIST_SEP + _SPAN + r")+")
_LIST_SEPARATOR = re.compile(r"(?<=`)" + _LIST_SEP + r"(?=`)")
_TODO_SPAN = "`todo`"


class OmpGenerationError(ValueError):
    """A source file holds a reference the OMP bundle cannot resolve."""


@dataclass(frozen=True)
class Catalog:
    """Names a ycc reference may resolve to."""

    src_root: Path
    skills: frozenset[str]
    agents: Mapping[str, str]  # file stem or frontmatter name -> agent name


def build_catalog(src_root: Path, aliases: Mapping[str, str] | None = None) -> Catalog:
    skills = frozenset(p.parent.name for p in src_root.glob("*/SKILL.md"))
    return Catalog(src_root, skills, dict(load_agent_aliases() if aliases is None else aliases))


def _resolve_skill(name: str, rel: Path, ref: str, catalog: Catalog) -> str:
    if name in catalog.skills:
        return f"/skill:{name}"
    if name in catalog.agents:
        return catalog.agents[name]
    raise OmpGenerationError(f"{rel}: '{ref}' names neither a ycc skill nor a ycc agent")


def _resolve_agent(name: str, rel: Path, ref: str, catalog: Catalog) -> str:
    if name in catalog.agents:
        return catalog.agents[name]
    raise OmpGenerationError(f"{rel}: '{ref}' is used as an agent but names no ycc agent")


def rewrite_namespace(text: str, rel: Path, catalog: Catalog) -> str:
    """Map `/ycc:` and bare `ycc:` references to OMP names (D5); unknown names raise (D6)."""

    def subagent(match: re.Match[str]) -> str:
        ref = match.group(0)[len(match.group(1)) :]
        return match.group(1) + _resolve_agent(match.group(2), rel, ref, catalog)

    def agent_suffix(match: re.Match[str]) -> str:
        name = match.group(1)
        return catalog.agents[name] if name in catalog.agents else match.group(0)

    def managed_block(match: re.Match[str]) -> str:
        # Managed-block markers are matched by awk regexes and by other bundles'
        # output, so they take the bare name, as in the Cursor and Codex bundles.
        name = match.group(1)
        if name not in catalog.skills:
            raise OmpGenerationError(f"{rel}: '{match.group(0)}' names no ycc skill")
        return name

    def slash(match: re.Match[str]) -> str:
        return _resolve_skill(match.group(1), rel, match.group(0), catalog)

    def bare(match: re.Match[str]) -> str:
        if match.group(1) in _PROTECTED_NAMES:
            return match.group(0)
        return _resolve_skill(match.group(1), rel, match.group(0), catalog)

    text = _SUBAGENT_REF.sub(subagent, text)
    text = _AGENT_SUFFIX_REF.sub(agent_suffix, text)
    text = _MANAGED_BLOCK_REF.sub(managed_block, text)
    text = _SLASH_REF.sub(slash, text)
    return _BARE_REF.sub(bare, text)


def _check_skill_path(path: str, rel: Path, ref: str, catalog: Catalog) -> None:
    """Fail on a concrete (non-glob, non-placeholder) skill-tree path that does not exist."""
    check = path.split("#", 1)[0].rstrip(".:*")
    if "..." in check or any(char in _PATTERN_CHARS for char in check):
        return
    top = check.split("/", 1)[0]
    if top and top != SHARED_DIR_NAME and top not in catalog.skills:
        raise OmpGenerationError(f"{rel}: '{ref}' points outside the ycc skills ('{top}' is not a skill)")
    if not (catalog.src_root / check).exists():
        raise OmpGenerationError(f"{rel}: '{ref}' does not exist in ycc/skills")


def _skill_url(path: str) -> str:
    if path == SHARED_DIR_NAME or path.startswith(SHARED_DIR_NAME + "/"):
        return f"skill://{SHARED_SKILL_NAME}" + path[len(SHARED_DIR_NAME) :]
    return f"skill://{path}"


def rewrite_plugin_paths(text: str, rel: Path, catalog: Catalog) -> str:
    """`${CLAUDE_PLUGIN_ROOT}/skills/<path>` -> `skill://` URLs (D3)."""

    def replace(match: re.Match[str]) -> str:
        _check_skill_path(match.group(1), rel, match.group(0), catalog)
        return _skill_url(match.group(1))

    return _PLUGIN_SKILL_PATH.sub(replace, text)


def rewrite_relative_shared_links(text: str, rel: Path, catalog: Catalog) -> str:
    """Markdown `(../)+_shared/<path>` links -> `skill://ycc-shared/<path>` (D3)."""

    def replace(match: re.Match[str]) -> str:
        _check_skill_path(f"{SHARED_DIR_NAME}/{match.group(1)}", rel, match.group(0), catalog)
        return _skill_url(f"{SHARED_DIR_NAME}/{match.group(1)}")

    return _RELATIVE_SHARED_LINK.sub(replace, text)


def rewrite_script_plugin_paths(text: str, rel: Path, catalog: Catalog) -> str:
    """Script fallbacks become the script-relative primary path; comments get `skill://` (D4).

    Child processes cannot resolve `skill://` and OMP sets no plugin-root variable, so a
    `${CLAUDE_PLUGIN_ROOT}` used as code anywhere but a fallback assignment fails. A
    rewritten fallback repeats its primary path, so the dead fallback line is dropped.
    """

    def fallback(match: re.Match[str]) -> str:
        path = match.group("path")
        _check_skill_path(path, rel, match.group(0), catalog)
        if not re.search(r"^\s*SCRIPT_DIR=", text, re.MULTILINE):
            raise OmpGenerationError(f"{rel}: '{match.group(0)}' needs a SCRIPT_DIR assignment to rewrite")
        relative = Path(os.path.relpath(path, rel.parent.as_posix())).as_posix()
        return f'{match.group("lhs")}"${{SCRIPT_DIR}}/{relative}"'

    text = _SCRIPT_FALLBACK.sub(fallback, text)
    for line in text.splitlines():
        if PLUGIN_ROOT_TOKEN in line and not line.lstrip().startswith("#"):
            raise OmpGenerationError(f"{rel}: unsupported {PLUGIN_ROOT_TOKEN} use in script code: {line.strip()}")
    return rewrite_plugin_paths(drop_self_fallbacks(text), rel, catalog)


def _rewrite_code_tools(code: str) -> str:
    for pattern, replacement in _CODE_TOOL_WORDING:
        code = pattern.sub(replacement, code)
    return code


def _rewrite_span(span: str) -> str:
    content = span[1:-1]
    if content in ("Agent", "Task"):
        return "`task`"
    if content == "WebFetch":
        return "`read` (URL)"
    return f"`{_rewrite_code_tools(content)}`"


def _join_items(items: list[str], separators: list[str]) -> str:
    if len(items) == 1:
        return items[0]
    if all("/" in separator for separator in separators):
        return "/".join(items)
    conjunctions = [word for separator in separators for word in ("and", "or") if re.search(rf"\b{word}\b", separator)]
    if not conjunctions:
        return ", ".join(items)
    if len(items) == 2:
        return f"{items[0]} {conjunctions[-1]} {items[1]}"
    return ", ".join(items[:-1]) + f", {conjunctions[-1]} {items[-1]}"


def _collapse_todo_lists(text: str) -> str:
    """Merge repeated `todo` items in a span list, keeping its final conjunction."""

    def collapse(match: re.Match[str]) -> str:
        run = match.group(0)
        separators = _LIST_SEPARATOR.findall(run)
        items = _CODE_SPAN.findall(_LIST_SEPARATOR.sub("\x00", run))
        if items.count(_TODO_SPAN) < 2:
            return run
        unique = [item for index, item in enumerate(items) if item != _TODO_SPAN or _TODO_SPAN not in items[:index]]
        return _join_items(unique, separators)

    return _SPAN_LIST.sub(collapse, text)


def _rewrite_fenced_tools(code: str) -> str:
    """Fenced blocks: bare names in code; prompt templates' inline spans as in prose."""
    parts = _CODE_SPAN.split(code)
    for index, part in enumerate(parts):
        parts[index] = _rewrite_span(part) if index % 2 else _rewrite_code_tools(part)
    return _collapse_todo_lists("".join(parts))


def _rewrite_prose_tools(prose: str) -> str:
    parts = _CODE_SPAN.split(prose)
    for index, part in enumerate(parts):
        if index % 2:
            parts[index] = _rewrite_span(part)
        else:
            for pattern, replacement in _PROSE_TOOL_WORDING:
                part = pattern.sub(replacement, part)
            parts[index] = part
    return _collapse_todo_lists("".join(parts))


def rewrite_tool_wording(text: str) -> str:
    """Claude tool identifiers -> OMP tool names (D8): bare in code, backticked in prose."""
    chunks: list[str] = []
    prose: list[str] = []
    in_fence = False
    for line in text.splitlines(keepends=True):
        if _FENCE.match(line):
            if not in_fence:
                chunks.append(_rewrite_prose_tools("".join(prose)))
                prose = []
            in_fence = not in_fence
            chunks.append(line)
        elif in_fence:
            chunks.append(_rewrite_fenced_tools(line))
        else:
            prose.append(line)
    chunks.append(_rewrite_prose_tools("".join(prose)))
    return "".join(chunks)


def _check_no_plugin_root(text: str, rel: Path) -> None:
    for line in text.splitlines():
        if PLUGIN_ROOT_TOKEN in line:
            raise OmpGenerationError(f"{rel}: unresolved {PLUGIN_ROOT_TOKEN} reference: {line.strip()}")


def apply_path_sentences(
    text: str,
    rel: Path,
    sentences: tuple[tuple[str, str], ...],
    table: str = "PATH_TOOL_SENTENCES",
) -> str:
    """Apply one file's sentence-table entries; a missing sentence raises, naming the table."""
    for source, replacement in sentences:
        if source not in text:
            raise OmpGenerationError(f"{rel}: {table} entry no longer matches: {source!r}")
        text = text.replace(source, replacement)
    return text


def rewrite_worktree_root(text: str) -> str:
    """`/.claude/worktrees` -> `/.omp/worktrees` (D1)."""
    return text.replace(*WORKTREE_ROOT_REWRITE)


def _project_dispatch_fields(paragraph: str) -> str:
    """One dispatch paragraph: Claude `description`/`prompt` fields -> OMP `name`/`task`."""
    has_name = bool(_NAME_FIELD.search(paragraph))

    def label(value: str) -> str:
        return f"CamelCase label for {value.strip()}"

    def description_bullet(match: re.Match[str]) -> str:
        return "" if has_name else f"{match['indent']}- `name`: {label(match['value'])}\n"

    def description_row(match: re.Match[str]) -> str:
        return "" if has_name else f"|{match['pad']}name | {label(match['value'])} |\n"

    def description_code(match: re.Match[str]) -> str:
        if has_name:
            return ""
        return f'{match["indent"]}name{match["eq"]}"<CamelCase label for {match["value"]}>"{match["tail"]}\n'

    paragraph = _DESCRIPTION_BULLET.sub(description_bullet, paragraph)
    paragraph = _PROMPT_BULLET.sub(
        lambda m: f"{m['indent']}- `task`:{m['rest']}\n{m['indent']}- `solutionSpace`: {_SOLUTION_SPACE}", paragraph
    )
    paragraph = _DESCRIPTION_ROW.sub(description_row, paragraph)
    paragraph = _PROMPT_ROW.sub(
        lambda m: f"|{m['pad']}task |{m['rest']}\n|{m['pad']}solutionSpace | {_SOLUTION_SPACE} |", paragraph
    )
    paragraph = _DESCRIPTION_CODE.sub(description_code, paragraph)
    paragraph = _PROMPT_CODE.sub(
        lambda m: f'{m["indent"]}task{m["eq"]}{m["value"]},\n{m["indent"]}solutionSpace{m["eq"]}"<how open-ended>"',
        paragraph,
    )
    paragraph = _DESCRIPTION_INLINE.sub(lambda m: f"`name` ({label(m['value'])})", paragraph)
    paragraph = _PROMPT_INLINE.sub(lambda m: f'`task={m["value"]}`, `solutionSpace="<how open-ended>"`', paragraph)
    for span, replacement in _FIELD_SPAN.items():
        paragraph = paragraph.replace(span, replacement)
    return paragraph


def rewrite_dispatch_wording(text: str) -> str:
    """Claude dispatch arguments -> OMP `task` item fields (D5); item shape: OMP standalone-dispatch §1."""
    parts = _PARAGRAPH_BREAK.split(text)
    for index in range(0, len(parts), 2):
        if _DISPATCH_MARKER.search(parts[index]):
            parts[index] = _project_dispatch_fields(parts[index])
    text = "".join(parts)
    for pattern, replacement in _DISPATCH_WORDING + _NAME_OMISSION_REWRITES:
        text = pattern.sub(replacement, text)
    return text


def _paragraph_lines(text: str, context: re.Pattern[str], rule: re.Pattern[str]) -> list[int]:
    """1-based lines matching rule inside paragraphs that match context."""
    lines: list[int] = []
    offset = 1
    for index, part in enumerate(_PARAGRAPH_BREAK.split(text)):
        if index % 2 == 0 and context.search(part):
            for number, line in enumerate(part.splitlines(), offset):
                if rule.search(line):
                    lines.append(number)
        offset += part.count("\n")
    return lines


def dispatch_field_leaks(text: str) -> list[int]:
    """1-based lines holding a Claude `description`/`prompt` field in a paragraph that sets an OMP `agent`."""
    return _paragraph_lines(text, _OMP_AGENT_FIELD, _CLAUDE_DISPATCH_FIELD)


def name_omission_leaks(text: str) -> list[int]:
    """1-based lines telling an OMP `task`/`agent` dispatch to omit `name` (every OMP item has one)."""
    return _paragraph_lines(text, _OMP_DISPATCH_CONTEXT, _NAME_OMISSION_RULE)


def rewrite_team_advisories(text: str) -> str:
    """Team advisories that list the bundles without team tools also name OMP (D7)."""
    lines = text.splitlines(keepends=True)
    for index, line in enumerate(lines):
        if _TEAM_LINE.search(line):
            for pattern, replacement in _TEAM_ADVISORY_WORDING:
                line = pattern.sub(replacement, line)
            lines[index] = line
    return "".join(lines)


def split_numbered_sections(text: str, required: tuple[int, ...], what: str) -> dict[int, str]:
    """Split `## <n>. ...` sections by number; raise when a required number is missing."""
    matches = list(_NUMBERED_SECTION.finditer(text))
    sections: dict[int, str] = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        sections[int(match.group(1))] = text[match.start() : end].rstrip().removesuffix("---").rstrip()
    missing = [number for number in required if number not in sections]
    if missing:
        raise OmpGenerationError(f"{what} is missing sections {missing}")
    return sections


def render_omp_standalone_dispatch(source: str, template_path: Path = STANDALONE_DISPATCH_TEMPLATE) -> str:
    """Template sections 1-7 (with its preamble) + canonical sections 8-10, before rewrites."""
    try:
        template = template_path.read_text(encoding="utf-8")
    except OSError as error:
        raise OmpGenerationError(f"OMP dispatch template is unavailable: {template_path}") from error
    found = split_numbered_sections(template, TEMPLATE_SECTIONS, f"OMP dispatch template {template_path.name}")
    if tuple(found) != TEMPLATE_SECTIONS:
        raise OmpGenerationError(f"OMP dispatch template {template_path.name} must hold exactly sections 1-7")
    canonical = split_numbered_sections(source, CANONICAL_SECTIONS, str(STANDALONE_DISPATCH_REL))
    head = template.rstrip().removesuffix("---").rstrip()
    body = "\n\n---\n\n".join(canonical[number] for number in CANONICAL_SECTIONS)
    return f"{head}\n\n---\n\n{body}\n"


def transform_text(
    text: str,
    rel: Path,
    catalog: Catalog,
    sentences: tuple[tuple[str, str], ...] = (),
    dispatch_sentences: tuple[tuple[str, str], ...] = (),
) -> str:
    """Rewrite one non-verbatim skill-tree text file for OMP."""
    is_markdown = rel.suffix.lower() in MARKDOWN_SUFFIXES
    is_script = rel.suffix.lower() in SCRIPT_SUFFIXES
    keeps_plugin_root = rel.as_posix() in REPOSITORY_LAYOUT_FILES

    def body_rewrite(segment: str) -> str:
        segment = fix_mcp_malformed_tokens(segment)
        if keeps_plugin_root:
            pass
        elif is_script:
            segment = rewrite_script_plugin_paths(segment, rel, catalog)
        else:
            segment = rewrite_plugin_paths(segment, rel, catalog)
        if is_markdown:
            segment = rewrite_relative_shared_links(segment, rel, catalog)
        segment = rewrite_namespace(segment, rel, catalog)
        segment = rewrite_worktree_root(segment)
        if is_markdown:
            segment = rewrite_dispatch_wording(segment)
            segment = rewrite_team_advisories(segment)
            segment = rewrite_tool_wording(segment)
        if not keeps_plugin_root:
            _check_no_plugin_root(segment, rel)
        return segment

    if rel == TEAM_DISPATCH_REL:
        return TEAM_DISPATCH_NOTE

    header = ""
    if rel.name == "SKILL.md" and len(rel.parts) == 2:
        frontmatter, text = parse_frontmatter(text)
        header = dump_frontmatter(transform_frontmatter(frontmatter, rel, body_rewrite))

    text = apply_path_sentences(text, rel, dispatch_sentences, "OMP_DISPATCH_SENTENCES")
    text = apply_path_sentences(text, rel, sentences)
    if rel == STANDALONE_DISPATCH_REL:
        text = render_omp_standalone_dispatch(text)
    protected, blocks = protect_marked_verbatim_blocks(text)
    output = header + restore_marked_verbatim_blocks(body_rewrite(protected), blocks)
    if output and not output.endswith("\n"):
        output += "\n"
    return output


def transform_frontmatter(frontmatter: dict[str, Any], rel: Path, rewrite: Callable[[str], str]) -> dict[str, Any]:
    """Keep OMP-meaningful keys (D7); strict `disable-model-invocation` (D6)."""
    model_invocation_disabled(frontmatter, rel.parent.name)
    kept: dict[str, Any] = {}
    for key in KEPT_FRONTMATTER_KEYS:
        if key not in frontmatter:
            continue
        value = frontmatter[key]
        kept[key] = rewrite(value) if isinstance(value, str) else value
    return kept


def copy_mode(src: Path, dst: Path) -> None:
    dst.chmod(stat.S_IMODE(src.stat().st_mode))


def iter_source_files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*") if p.is_file())


def write_tree(
    dest: Path,
    dry_run: bool,
    *,
    src_root: Path | None = None,
    aliases: Mapping[str, str] | None = None,
    path_sentences: PathSentences | None = None,
    dispatch_sentences: PathSentences | None = None,
) -> set[Path]:
    """Write the OMP skill tree under dest; returns the relative file paths written."""
    src = SRC_DIR if src_root is None else src_root
    # Fixture trees (an explicit src_root) get no real-tree sentence tables by default.
    if path_sentences is None:
        path_sentences = PATH_TOOL_SENTENCES if src_root is None else {}
    if dispatch_sentences is None:
        dispatch_sentences = OMP_DISPATCH_SENTENCES if src_root is None else {}
    sentences = path_sentences
    if not src.is_dir():
        raise SystemExit(f"Missing source directory: {src}")
    catalog = build_catalog(src, aliases)
    if (src / SHARED_STUB_REL).exists():
        raise OmpGenerationError(f"{SHARED_STUB_REL}: source must not define the generated {SHARED_SKILL_NAME} stub")
    listed_files = set(sentences) | set(dispatch_sentences) | (REPOSITORY_LAYOUT_FILES if src_root is None else set())
    for listed in sorted(listed_files):
        if not (src / listed).is_file():
            raise OmpGenerationError(f"{listed}: listed in the OMP generator but missing from ycc/skills")

    outputs: dict[Path, tuple[bytes, Path | None]] = {}
    for src_file in iter_source_files(src):
        rel = src_file.relative_to(src)
        data = src_file.read_bytes()
        if rel.as_posix() not in VERBATIM_SKILL_FILES:
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                pass
            else:
                data = transform_text(
                    text,
                    rel,
                    catalog,
                    sentences.get(rel.as_posix(), ()),
                    dispatch_sentences.get(rel.as_posix(), ()),
                ).encode("utf-8")
        outputs[rel] = (data, src_file)
    if (src / SHARED_DIR_NAME).is_dir():
        outputs[SHARED_STUB_REL] = (SHARED_STUB.encode("utf-8"), None)

    if dry_run:
        for rel in sorted(outputs):
            print(f"Would write {(dest / rel)}")
        return set(outputs)

    for rel, (data, origin) in sorted(outputs.items()):
        dst_file = dest / rel
        dst_file.parent.mkdir(parents=True, exist_ok=True)
        dst_file.write_bytes(data)
        if origin is None:
            dst_file.chmod(0o644)
        else:
            copy_mode(origin, dst_file)
    prune_orphans(dest, set(outputs))
    return set(outputs)


def prune_orphans(dest: Path, keep: set[Path]) -> None:
    """Remove files and then empty directories under dest that the generator did not write."""
    for path in sorted(dest.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if path.is_file() or path.is_symlink():
            if path.relative_to(dest) not in keep:
                path.unlink()
        elif path.is_dir() and not any(path.iterdir()):
            path.rmdir()


def _tree(root: Path) -> dict[Path, Path]:
    if not root.is_dir():
        return {}
    return {p.relative_to(root): p for p in root.rglob("*") if p.is_file() or p.is_symlink()}


def compare_trees(generated: Path, repo_dst: Path) -> list[str]:
    """Byte-for-byte and executable-bit comparison; returns human-readable drift lines."""
    gen, dst = _tree(generated), _tree(repo_dst)
    diffs: list[str] = []
    for rel in sorted(gen.keys() | dst.keys()):
        if rel not in dst:
            diffs.append(f"missing in repo: {rel}")
        elif rel not in gen:
            diffs.append(f"extra in repo: {rel}")
        elif dst[rel].is_symlink() or gen[rel].read_bytes() != dst[rel].read_bytes():
            diffs.append(f"drift: {rel}")
        elif (gen[rel].stat().st_mode ^ dst[rel].stat().st_mode) & 0o111:
            diffs.append(f"mode drift: {rel}")
    return diffs


def scan_forbidden_semantics(package_root: Path) -> list[str]:
    """Lines under package_root (packages/omp/ycc) with Claude workflow semantics, minus the allowlist."""
    findings: list[str] = []
    for path in sorted(p for p in package_root.rglob("*") if p.is_file()):
        rel = path.relative_to(package_root).as_posix()
        if rel in SEMANTICS_ALLOWED_FILES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        allowed = SEMANTICS_ALLOWED_LINES.get(rel, ())
        lines = text.splitlines()
        for number, line in enumerate(lines, 1):
            if FORBIDDEN_SEMANTICS.search(line) and not any(pattern.match(line) for pattern in allowed):
                findings.append(f"{rel}:{number}: {line.strip()}")
        if path.suffix.lower() in MARKDOWN_SUFFIXES:
            for number in dispatch_field_leaks(text):
                findings.append(f"{rel}:{number}: Claude dispatch field next to `agent`: {lines[number - 1].strip()}")
            for number in name_omission_leaks(text):
                findings.append(f"{rel}:{number}: omit-`name` rule next to OMP dispatch: {lines[number - 1].strip()}")
    return findings


def run_check(dest: Path = DST_DIR) -> int:
    with tempfile.TemporaryDirectory() as tmp:
        generated = Path(tmp)
        write_tree(generated, dry_run=False)
        diffs = compare_trees(generated, dest)
    if diffs:
        print("OMP skills are out of date. Run: ./scripts/generate-omp-skills.sh", file=sys.stderr)
        for line in diffs:
            print(f"  {line}", file=sys.stderr)
        return 1
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit 1 if packages/omp/ycc/skills differs from generator output (bytes or executable bits)",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print paths that would be written (no writes)")
    args = parser.parse_args()

    try:
        if args.check:
            if not DST_DIR.is_dir():
                print(f"Missing {DST_DIR}; run generator without --check first.", file=sys.stderr)
                sys.exit(1)
            sys.exit(run_check())
        written = write_tree(DST_DIR, dry_run=args.dry_run)
    except ValueError as error:
        print(f"generate_omp_skills.py: {error}", file=sys.stderr)
        sys.exit(1)
    if not args.dry_run:
        print(f"Wrote {len(written)} files under {DST_DIR}")


if __name__ == "__main__":
    main()
