#!/usr/bin/env python3
"""
Shared helpers for Codex-native generation.
"""

from __future__ import annotations

import re
from functools import reduce
from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
YCC_DIR = REPO_ROOT / "ycc"
SRC_SKILLS_DIR = YCC_DIR / "skills"
SRC_AGENTS_DIR = YCC_DIR / "agents"

CODEX_PLUGIN_CONTAINER = REPO_ROOT / ".codex-plugin"
PLUGIN_ROOT = CODEX_PLUGIN_CONTAINER / "ycc"
PLUGIN_SKILLS_DIR = PLUGIN_ROOT / "skills"
PLUGIN_SHARED_DIR = PLUGIN_ROOT / "shared"
PLUGIN_MANIFEST_PATH = PLUGIN_ROOT / ".codex-plugin" / "plugin.json"
PLUGIN_MCP_PATH = PLUGIN_ROOT / ".mcp.json"
PLUGIN_AGENTS_DIR = CODEX_PLUGIN_CONTAINER / "agents"
REPO_MARKETPLACE_PATH = REPO_ROOT / ".agents" / "plugins" / "marketplace.json"

SOURCE_PLUGIN_PATH = YCC_DIR / ".claude-plugin" / "plugin.json"
SOURCE_MCP_PATH = REPO_ROOT / "mcp-configs" / "mcp.json"

HOME_INSTALL_PLUGIN_ROOT = "~/.codex/plugins/ycc"

RUNTIME_LIST_SENTINEL = "\x00CODEX_RUNTIME_LIST\x00"
RUNTIME_LIST_BUNDLES_SENTINEL = "\x00CODEX_RUNTIME_LIST_BUNDLES\x00"
CLAUDE_CODE_ONLY_SENTINEL = "\x00CLAUDE_CODE_ONLY_ADVISORY\x00"
CLAUDE_CODE_ONLY_HYPHEN_SENTINEL = "\x00CLAUDE_CODE_ONLY_HYPHEN_ADVISORY\x00"
RUNTIME_LIST_TEXT = "Claude Code, Cursor, and Codex"
RUNTIME_LIST_BUNDLES_TEXT = f"{RUNTIME_LIST_TEXT} bundles"
CODEX_RUNTIME_ONLY_TEXT = "Codex runtime only; not available in bundle invocations"
CODEX_RUNTIME_ONLY_HYPHEN_TEXT = "Codex-runtime-only (not available in bundle invocations)"

# Multi-runtime policy blocks (worktree roots table, native-placement evidence,
# retired-root literals) must survive per-target rewrites byte-for-byte; a blind
# .claude/ -> .codex/ or /.claude/worktrees -> /.opencode/worktrees pass would
# corrupt them. Marker comments delimit the block and are stripped on output.
MULTI_RUNTIME_MARKER_BEGIN = "<!-- ycc:verbatim-block:begin -->"
MULTI_RUNTIME_MARKER_END = "<!-- ycc:verbatim-block:end -->"
_MULTI_RUNTIME_SENTINEL = "\x00YCC_MULTI_RUNTIME_BLOCK_{idx}\x00"


def protect_marked_verbatim_blocks(text: str) -> tuple[str, dict[str, str]]:
    """Replace every marker-delimited block with a sentinel; returns (text, map).

    The markers themselves are stripped from the output. Call
    ``restore_marked_verbatim_blocks`` after all target rewrites.
    """
    blocks: dict[str, str] = {}
    pattern = re.compile(
        re.escape(MULTI_RUNTIME_MARKER_BEGIN) + r"\n?(.*?)\n?" + re.escape(MULTI_RUNTIME_MARKER_END) + "\n?",
        re.DOTALL,
    )

    def _stash(match: re.Match[str]) -> str:
        sentinel = _MULTI_RUNTIME_SENTINEL.format(idx=len(blocks))
        blocks[sentinel] = match.group(1)
        return sentinel

    return pattern.sub(_stash, text), blocks


def restore_marked_verbatim_blocks(text: str, blocks: dict[str, str]) -> str:
    for sentinel, block in blocks.items():
        text = text.replace(sentinel, block)
    return text


PRODUCT_FILE_REPLACEMENTS: tuple[tuple[str, str], ...] = (
    ("CLAUDE.md", "AGENTS.md"),
    ("claude.template.md", "agents.template.md"),
    (".claude-plugin/", ".codex-plugin/"),
)

HOME_PATH_REPLACEMENTS: tuple[tuple[str, str], ...] = (
    ("~/.claude/", "~/.codex/"),
    ("/.claude/", "/.codex/"),
    ("../../_shared/scripts", "../../../shared/scripts"),
)

PRODUCT_WORDING_REPLACEMENTS: tuple[tuple[str, str], ...] = (
    ("Claude Code", "Codex"),
    ("Claude CLI", "Codex CLI"),
    ("Claude home directory", "Codex home directory"),
    ("main Claude session", "main Codex session"),
    ("the main Claude session", "the main Codex session"),
    ("Restart Claude CLI", "Restart Codex"),
    ("Claude CLI logs", "Codex logs"),
    ("set up Claude CLI environment", "set up the Codex environment"),
    ("closing Claude Code", "closing Codex"),
    ("a live Claude Code session", "a live Codex session"),
)

TOOL_WORDING_REPLACEMENTS: tuple[tuple[str, str], ...] = (
    # Article-aware pairs must run before their bare-token pairs below so
    # "the TaskList" does not become "the the task tracker".
    ("the TodoWrite", "the task tracker"),
    ("the TaskList", "the task tracker"),
    ("Task tool calls", "parallel agent runs"),
    ("Task tool call", "agent run"),
    ("Task tool", "parallel agent workflow"),
    ("Agent tool calls", "parallel agent runs"),
    ("Agent tool call", "agent run"),
    ("Agent tool", "parallel agent workflow"),
    ("TodoWrite", "the task tracker"),
    ("AskUserQuestion", "ask the user"),
    ("TeamCreate", "create an agent group"),
    ("TeamDelete", "close the agent group"),
    ("TaskCreate", "record the task"),
    ("TaskUpdate", "update the task tracker"),
    ("TaskList", "the task tracker"),
    ("TaskGet", "the task details"),
    ("SendMessage", "send follow-up instructions"),
    ('message={type: "shutdown_request"}', "a shutdown request"),
)

VERBATIM_SKILL_FILES: frozenset[str] = frozenset(
    {
        "_shared/references/target-capability-matrix.md",
        "hooks-workflow/references/support-notes.md",
        "hooks-workflow/scripts/build-hook-config.sh",
        "compatibility-audit/scripts/audit-install-assumptions.sh",
        "compatibility-audit/scripts/audit-target-features.sh",
        "compatibility-audit/references/reading-the-report.md",
        "release-model/scripts/pointer-targets.sh",
        "init/scripts/migrate-rules.sh",
        "init/scripts/rules_file_lib.py",
        "_shared/scripts/rules_pointer.py",
        "_shared/scripts/rules-pointer.sh",
        "_shared/scripts/require-python.sh",
        "init/scripts/count-source-files.sh",
        "init/scripts/migrate-rules.py",
        "init/scripts/render-template.py",
        "init/scripts/rules-report.sh",
        "init/scripts/profile-project.sh",
        "init/scripts/render-template.sh",
    }
)
"""Skill-tree source files that must be copied verbatim into the Codex bundle.

They describe or check all three deployment targets literally, so any blind text
replacement (.claude-plugin/ -> .codex-plugin/, Claude Code -> Codex,
~/.claude/ -> ~/.codex/, etc.) produces semantically wrong output.
Paths are source-relative to ``ycc/skills/``.
"""


def strip_preamble_before_frontmatter(text: str) -> str:
    """Remove stray lines before the first YAML frontmatter opener."""
    if text.startswith("---"):
        return text

    lines = text.splitlines(keepends=True)
    for index, line in enumerate(lines):
        if line.strip() == "---":
            return "".join(lines[index:])
    return text


def parse_frontmatter(text: str) -> tuple[dict[str, Any], str]:
    """Return (frontmatter_dict, body)."""
    stripped = strip_preamble_before_frontmatter(text)
    if not stripped.startswith("---\n"):
        return {}, stripped

    end = stripped.find("\n---\n", 4)
    if end == -1:
        return {}, stripped

    raw_frontmatter = stripped[4:end]
    body = stripped[end + 5 :]
    if not raw_frontmatter.strip():
        return {}, body

    data = yaml.safe_load(raw_frontmatter)
    if not isinstance(data, dict):
        return {}, body
    return data, body


def model_invocation_disabled(frontmatter: dict[str, Any], skill: str) -> bool:
    """Read the source-only invocation flag without coercing YAML values."""
    value = frontmatter.get("disable-model-invocation", False)
    if type(value) is not bool:
        raise ValueError(f"skill '{skill}': 'disable-model-invocation' must be a boolean, got {value!r}")
    return value


def dump_frontmatter(data: dict[str, Any]) -> str:
    serialized = yaml.safe_dump(
        data,
        sort_keys=False,
        allow_unicode=True,
        default_flow_style=False,
    ).rstrip()
    return f"---\n{serialized}\n---\n"


def fix_mcp_malformed_tokens(text: str) -> str:
    """Fix mcp**server**tool typos copied from older prompts."""
    previous = None
    output = text
    while previous != output:
        previous = output
        output = re.sub(
            r"mcp\*\*([a-zA-Z0-9]+)\*\*([a-zA-Z0-9][a-zA-Z0-9.-]*)",
            r"mcp__\1__\2",
            output,
        )
    return output


def apply_literal_replacements(text: str, replacements: tuple[tuple[str, str], ...]) -> str:
    return reduce(lambda output, pair: output.replace(*pair), replacements, text)


def protect_codex_runtime_terms(text: str) -> str:
    output = text.replace(RUNTIME_LIST_BUNDLES_TEXT, RUNTIME_LIST_BUNDLES_SENTINEL)
    output = output.replace(RUNTIME_LIST_TEXT, RUNTIME_LIST_SENTINEL)
    output = output.replace("Claude Code-only", CLAUDE_CODE_ONLY_HYPHEN_SENTINEL)
    return output.replace("Claude Code only", CLAUDE_CODE_ONLY_SENTINEL)


def restore_codex_runtime_terms(text: str) -> str:
    output = text.replace(CLAUDE_CODE_ONLY_HYPHEN_SENTINEL, CODEX_RUNTIME_ONLY_HYPHEN_TEXT)
    output = output.replace(CLAUDE_CODE_ONLY_SENTINEL, CODEX_RUNTIME_ONLY_TEXT)
    output = output.replace(RUNTIME_LIST_BUNDLES_SENTINEL, RUNTIME_LIST_BUNDLES_TEXT)
    return output.replace(RUNTIME_LIST_SENTINEL, RUNTIME_LIST_TEXT)


_SHELL_ASSIGNMENT = re.compile(
    r"^\s*(?:(?:local|export|readonly|declare)\s+)?(?P<var>[A-Za-z_][A-Za-z0-9_]*)=(?P<value>\S.*?)\s*$"
)
_SHELL_FILE_FALLBACK = re.compile(
    r"^\s*\[\[\s+-f\s+\"\$\{?(?P<var>[A-Za-z_][A-Za-z0-9_]*)\}?\"\s+\]\]\s+\|\|\s+(?P=var)=(?P<value>\S.*?)\s*$"
)


def self_fallbacks(text: str) -> list[tuple[int, str]]:
    """Return ``(line index, variable)`` for every dead shell fallback in ``text``.

    A fallback ``[[ -f "$VAR" ]] || VAR="X"`` is dead when the nearest preceding
    non-blank, non-comment line is exactly ``VAR="X"`` (optionally prefixed by
    ``local``/``export``/``readonly``/``declare``): both branches name the same
    path. Only that adjacent form counts, so an assignment in another branch,
    function or heredoc never makes a fallback look dead.
    """
    previous: str | None = None
    found: list[tuple[int, str]] = []
    for index, line in enumerate(text.splitlines()):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fallback = _SHELL_FILE_FALLBACK.match(line)
        if fallback and previous is not None:
            assignment = _SHELL_ASSIGNMENT.match(previous)
            if assignment and (assignment["var"], assignment["value"]) == (fallback["var"], fallback["value"]):
                found.append((index, fallback["var"]))
        previous = line
    return found


def drop_self_fallbacks(text: str) -> str:
    """Delete dead shell fallbacks (see ``self_fallbacks``) left by path rewrites."""
    dead = {index for index, _ in self_fallbacks(text)}
    if not dead:
        return text
    return "".join(line for index, line in enumerate(text.splitlines(keepends=True)) if index not in dead)


def load_agent_aliases() -> dict[str, str]:
    aliases: dict[str, str] = {}
    for path in sorted(SRC_AGENTS_DIR.glob("*.md")):
        frontmatter, _ = parse_frontmatter(path.read_text(encoding="utf-8"))
        name = str(frontmatter.get("name") or path.stem)
        aliases[path.stem] = name
        aliases[name] = name
    return aliases


def map_namespaced_reference(name: str, aliases: dict[str, str]) -> str:
    return aliases.get(name, name)


def apply_codex_text_transforms(text: str, aliases: dict[str, str]) -> str:
    text, verbatim_blocks = protect_marked_verbatim_blocks(text)
    output = fix_mcp_malformed_tokens(text)

    # Product/file naming.
    output = apply_literal_replacements(output, PRODUCT_FILE_REPLACEMENTS)

    # Home/config paths.
    output = apply_literal_replacements(output, HOME_PATH_REPLACEMENTS)
    output = re.sub(r"\$\{HOME\}/\.claude/", r"${HOME}/.codex/", output)
    output = re.sub(r"\$HOME/\.claude/", r"$HOME/.codex/", output)

    # Product wording.
    #
    # Some source prose names Claude Code as one runtime in a multi-target list or
    # as the only runtime that supports agent teams. Preserve those semantics
    # before the broad product-name rewrite so Codex output does not duplicate
    # "Codex" or advertise bundle-incompatible `--team` flags as plain
    # "Codex-only" features.
    output = protect_codex_runtime_terms(output)
    output = apply_literal_replacements(output, PRODUCT_WORDING_REPLACEMENTS)
    output = re.sub(
        r"\bClaude API with structured output\b",
        "LLM API with structured output",
        output,
    )

    # Skill/command references.
    output = re.sub(
        r"/ycc:([a-zA-Z0-9-]+)",
        lambda match: f"${map_namespaced_reference(match.group(1), aliases)}",
        output,
    )
    output = re.sub(
        r"\bycc:([a-zA-Z0-9-]+)\b",
        lambda match: map_namespaced_reference(match.group(1), aliases),
        output,
    )

    # Claude-specific agent/tool phrasing -> Codex-native wording.
    output = re.sub(
        r'Use the Task tool with \*\*`subagent_type: "([^"]+)"`\*\*',
        lambda match: f"Spawn the `{map_namespaced_reference(match.group(1), aliases)}` custom agent",
        output,
    )
    output = re.sub(
        r'Use the Agent tool with `subagent_type: "([^"]+)"`',
        lambda match: f"Spawn the `{map_namespaced_reference(match.group(1), aliases)}` custom agent",
        output,
    )
    output = re.sub(
        r'`subagent_type: "([^"]+)"`',
        lambda match: f"`{map_namespaced_reference(match.group(1), aliases)}`",
        output,
    )
    output = apply_literal_replacements(output, TOOL_WORDING_REPLACEMENTS)
    output = restore_codex_runtime_terms(output)
    output = restore_marked_verbatim_blocks(output, verbatim_blocks)

    if output and not output.endswith("\n"):
        output += "\n"
    return output


def compress_skill_description(text: str, max_length: int = 1024) -> str:
    """Fit a skill description into Codex's current frontmatter limit."""
    normalized = " ".join(text.split())
    if len(normalized) <= max_length:
        return normalized

    # Drop low-value provenance text first.
    normalized = re.sub(r"\s*Adapted from .*?$", "", normalized).strip()
    if len(normalized) <= max_length:
        return normalized

    sentences = re.split(r"(?<=[.!?])\s+", normalized)
    kept: list[str] = []
    for sentence in sentences:
        candidate = " ".join(kept + [sentence]).strip()
        if len(candidate) > max_length:
            break
        kept.append(sentence)

    compressed = " ".join(kept).strip()
    if compressed and len(compressed) <= max_length:
        return compressed

    hard_limit = max_length - 3
    return normalized[:hard_limit].rstrip() + "..."
