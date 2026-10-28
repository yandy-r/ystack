#!/usr/bin/env python3
"""
Shared helpers for the cross-tool "agents" target (.agents-plugin).

The agents target ships the ycc SKILLS ONLY into ~/.agents/skills/ — the flat
cross-tool user skill directory read by Zed, Codex, opencode, Cursor, Gemini
CLI, VS Code/Copilot, Amp, Goose and Windsurf (agentskills.io layout; NOT
Claude Code). Skills must be flat: <dir-name>/SKILL.md with a lowercase
kebab dir name matching the frontmatter name, so the shared _shipped helpers
cannot live under ~/.agents/skills/_shared — they install as the sibling
directory ~/.agents/ycc-shared/ instead.

Key porting facts (vs Claude Code):
- No ${CLAUDE_PLUGIN_ROOT} variable: generated paths use ~/.agents/skills/...
- Skill frontmatter is agentskills.io-shaped: name, description (<=1024),
  license, compatibility, metadata, allowed-tools (source values verbatim).
- Product names ("Claude Code", "Codex", ...) are intentionally NOT renamed:
  readers span many tools and no rewrite would be truthful everywhere.
- Transforms are a minimal subset of the opencode pass (see
  generate_opencode_common.apply_opencode_text_transforms): namespace strip,
  CLAUDE.md -> AGENTS.md, plugin-root and _shared path rewrites only.
"""

from __future__ import annotations

import re

from generate_codex_common import (
    expand_quoted_home,
    model_invocation_disabled,
    protect_marked_verbatim_blocks,
    restore_marked_verbatim_blocks,
)

# Frontmatter + text helpers are target-agnostic; reuse them directly.
from generate_opencode_common import (
    SRC_SKILLS_DIR,
    VERBATIM_SKILL_FILES,
    compress_skill_description,
    dump_frontmatter,
    fix_mcp_malformed_tokens,
    load_agent_aliases,
    map_namespaced_reference,
    parse_frontmatter,
)

__all__ = [
    "AGENTS_PLUGIN_ROOT",
    "AGENTS_SKILLS_DST",
    "AGENTS_SHARED_DST",
    "HOME_INSTALL_AGENTS_ROOT",
    "SRC_SKILLS_DIR",
    "VERBATIM_SKILL_FILES",
    "apply_agents_text_transforms",
    "compress_skill_description",
    "dump_frontmatter",
    "load_agent_aliases",
    "parse_frontmatter",
    "rewrite_agents_plugin_paths",
    "AGENTS_VERBATIM_EXCLUDE",
]

REPO_ROOT = SRC_SKILLS_DIR.parent.parent

AGENTS_PLUGIN_ROOT = REPO_ROOT / ".agents-plugin"
AGENTS_SKILLS_DST = AGENTS_PLUGIN_ROOT / "skills"
AGENTS_SHARED_DST = AGENTS_PLUGIN_ROOT / "ycc-shared"

# Install-time locations on the user's machine. ~/.agents/skills/<name>/ is the
# flat cross-tool layout; ycc-shared/ sits beside it (NOT inside skills/,
# whose entries must each be a valid skill directory).
HOME_INSTALL_AGENTS_ROOT = "~/.agents"

# agentskills.io frontmatter keys. `allowed-tools` passes through verbatim from
# the Claude source (spec-optional; readers interpret it per-tool).
AGENTS_FRONTMATTER_KEYS = (
    "name",
    "description",
    "license",
    "compatibility",
    "metadata",
    "allowed-tools",
)


# worktree-paths.sh marks its one default-root line; the portable bundle swaps in
# the runtime-detecting resolver defined in the same file.
WORKTREE_DEFAULT_MARKER_LINE = "printf '%s/.claude/worktrees\\n' \"$repo_root\" # @YCC_DEFAULT_WORKTREE_ROOT@"
WORKTREE_DEFAULT_AGENTS_LINE = 'ycc_runtime_worktree_root "$repo_root"'
# Targets whose own bundle is not a portable agents build keep these verbatim;
# the agents target must transform the marker line instead.
AGENTS_VERBATIM_EXCLUDE: frozenset[str] = frozenset({"_shared/scripts/worktree-paths.sh"})


def rewrite_agents_plugin_paths(text: str) -> str:
    """Rewrite ``${CLAUDE_PLUGIN_ROOT}/skills/<path>`` references to absolute
    ~/.agents install paths.

    ``_shared/`` relocates to the sibling ``~/.agents/ycc-shared/`` directory.
    """
    pattern = r"\$\{CLAUDE_PLUGIN_ROOT\}/skills/([^\"`\s]+)"

    def replace(match: re.Match[str]) -> str:
        path_text = match.group(1)
        if path_text.startswith("_shared/"):
            return f"{HOME_INSTALL_AGENTS_ROOT}/ycc-shared/{path_text[len('_shared/'):]}"
        return f"{HOME_INSTALL_AGENTS_ROOT}/skills/{path_text}"

    return re.sub(pattern, replace, text)


def apply_agents_text_transforms(
    text: str,
    aliases: dict[str, str],
    *,
    rewrite_runtime_aliases: bool = True,
    output_suffix: str = ".md",
) -> str:
    """Apply the agents-target rewrite pass (minimal, tool-neutral subset).

    Product names are deliberately left as-is: this bundle is read by many
    tools and renaming "Claude Code" prose to any single tool would be wrong.
    ``output_suffix`` gates the quoted-home rewrite to shell and Markdown files
    (see generate_codex_common.expand_quoted_home).
    """
    text, verbatim_blocks = protect_marked_verbatim_blocks(text)
    output = fix_mcp_malformed_tokens(text)

    # File naming: every agentskills.io reader uses AGENTS.md.
    output = output.replace("CLAUDE.md", "AGENTS.md")
    output = output.replace("claude.template.md", "agents.template.md")

    # Shared helpers move from skills/_shared/ to the sibling ycc-shared/ dir.
    # A skill at ~/.agents/skills/<name>/ reaches it via ../../../ycc-shared/.
    output = output.replace("../../_shared/", "../../../ycc-shared/")

    # Portable bundle: the worktree root is runtime-selected (YAN-1111), not
    # fixed to Claude's. Only the marked default line changes; prose that names
    # `.claude/worktrees` as the Claude root is left alone.
    output = output.replace(WORKTREE_DEFAULT_MARKER_LINE, WORKTREE_DEFAULT_AGENTS_LINE)
    # Example paths must be resolved with ycc_worktree_root, never assume Claude.
    output = output.replace("/.claude/worktrees", "/<worktree-root>")

    # Plugin-root variable -> absolute install paths.
    output = rewrite_agents_plugin_paths(output)
    # Tilde does not expand inside double quotes (SC2088); use ${HOME} there —
    # shell and Markdown output only, never Python/JSON/YAML/... text.
    output = expand_quoted_home(output, ".agents/", output_suffix)

    # Slash-command and agent namespace references (/ycc:foo -> /foo).
    if rewrite_runtime_aliases:
        output = re.sub(
            r"/ycc:([a-zA-Z0-9-]+)",
            lambda match: f"/{map_namespaced_reference(match.group(1), aliases)}",
            output,
        )
        output = re.sub(
            r"\bycc:([a-zA-Z0-9-]+)\b",
            lambda match: map_namespaced_reference(match.group(1), aliases),
            output,
        )

    if output and not output.endswith("\n"):
        output += "\n"
    return restore_marked_verbatim_blocks(output, verbatim_blocks)


def transform_skill_markdown(raw: str, aliases: dict[str, str]) -> str:
    """Rewrite a SKILL.md with agentskills.io frontmatter: `name` + required
    `description` (compressed to <=1024 chars), optional `license`,
    `compatibility`, `metadata`, and `allowed-tools` passed through verbatim.

    Other Claude frontmatter keys (argument-hint, ...) are dropped.
    """
    frontmatter, body = parse_frontmatter(raw)
    name = str(frontmatter.get("name") or "skill")
    model_invocation_disabled(frontmatter, name)  # strict validation; flag is not emitted
    description = str(frontmatter.get("description") or "").strip()
    transformed_description = compress_skill_description(
        apply_agents_text_transforms(
            rewrite_agents_plugin_paths(description),
            aliases,
        ).strip()
    )
    transformed_body = apply_agents_text_transforms(
        rewrite_agents_plugin_paths(body),
        aliases,
    )

    payload: dict[str, object] = {
        "name": name,
        "description": transformed_description,
    }
    for optional_key in ("license", "compatibility", "metadata", "allowed-tools"):
        if optional_key in frontmatter and frontmatter[optional_key] not in (None, "", {}):
            payload[optional_key] = frontmatter[optional_key]

    # allowed-tools globs may embed ${CLAUDE_PLUGIN_ROOT}/skills/... paths;
    # re-point them to the ~/.agents install layout.
    tools = payload.get("allowed-tools")
    if isinstance(tools, str):
        payload["allowed-tools"] = rewrite_agents_plugin_paths(tools)
    elif isinstance(tools, list):
        payload["allowed-tools"] = [
            rewrite_agents_plugin_paths(item) if isinstance(item, str) else item for item in tools
        ]

    return dump_frontmatter(payload) + transformed_body
