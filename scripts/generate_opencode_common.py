#!/usr/bin/env python3
"""
Shared helpers for opencode-native generation.

opencode is the AI coding agent at https://opencode.ai (repo: anomalyco/opencode,
formerly sst/opencode). It reads skills from .opencode/skills/<name>/SKILL.md,
agents from .opencode/agents/<name>.md, commands from .opencode/commands/<name>.md,
rules from AGENTS.md, and config + MCP from opencode.json.

Key porting facts (vs Claude Code):
- No ${CLAUDE_PLUGIN_ROOT} variable. Generated paths use absolute ~/.config/opencode/...
- V2 agent permissions use native action names and ordered rules.
- Slash commands use bare namespace (/foo, not /ycc:foo), same as Cursor.
- Skill frontmatter is strict: only name, description, license, compatibility, metadata.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

# Re-use frontmatter + description-compression helpers from the Codex generator.
# Both surfaces share a 1024-char description limit and the same stripped-YAML
# conventions, so there is no reason to duplicate the helpers.
from generate_codex_common import (
    compress_skill_description,
    dump_frontmatter,
    expand_quoted_home,
    fix_mcp_malformed_tokens,
    parse_frontmatter,
    protect_marked_verbatim_blocks,
    restore_marked_verbatim_blocks,
    strip_preamble_before_frontmatter,
)

__all__ = [
    "REPO_ROOT",
    "YCC_DIR",
    "SRC_SKILLS_DIR",
    "SRC_AGENTS_DIR",
    "SOURCE_PLUGIN_PATH",
    "SOURCE_MCP_PATH",
    "SOURCE_AGENTS_MD_CANDIDATES",
    "OPENCODE_PLUGIN_ROOT",
    "OPENCODE_SKILLS_DIR",
    "OPENCODE_AGENTS_DIR",
    "OPENCODE_COMMANDS_DIR",
    "OPENCODE_CONFIG_PATH",
    "OPENCODE_AGENTS_MD_PATH",
    "HOME_INSTALL_OPENCODE_ROOT",
    "SHELL_SUFFIXES",
    "VERBATIM_SKILL_FILES",
    "MODEL_ALIASES_PATH",
    "MODEL_ALIASES_LOCAL_PATH",
    "apply_opencode_text_transforms",
    "rewrite_plugin_paths",
    "compress_skill_description",
    "dump_frontmatter",
    "fix_mcp_malformed_tokens",
    "load_agent_aliases",
    "normalize_agent_color",
    "is_model_drop_sentinel",
    "load_model_aliases",
    "map_model",
    "parse_frontmatter",
    "strip_preamble_before_frontmatter",
    "translate_mcp_servers",
]

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
YCC_DIR = REPO_ROOT / "ycc"
SRC_SKILLS_DIR = YCC_DIR / "skills"
SRC_AGENTS_DIR = YCC_DIR / "agents"

SOURCE_PLUGIN_PATH = YCC_DIR / ".claude-plugin" / "plugin.json"
SOURCE_MCP_PATH = REPO_ROOT / "mcp-configs" / "mcp.json"

# opencode's bundle-level AGENTS.md is derived from the repo's AGENTS.md (which
# in turn points at CLAUDE.md). We read whichever of these exists; AGENTS.md
# wins because it is opencode's native rules filename.
SOURCE_AGENTS_MD_CANDIDATES = (
    REPO_ROOT / "AGENTS.md",
    REPO_ROOT / "CLAUDE.md",
)

OPENCODE_PLUGIN_ROOT = REPO_ROOT / ".opencode-plugin"
OPENCODE_SKILLS_DIR = OPENCODE_PLUGIN_ROOT / "skills"
OPENCODE_AGENTS_DIR = OPENCODE_PLUGIN_ROOT / "agents"
OPENCODE_COMMANDS_DIR = OPENCODE_PLUGIN_ROOT / "commands"
OPENCODE_CONFIG_PATH = OPENCODE_PLUGIN_ROOT / "opencode.json"
OPENCODE_AGENTS_MD_PATH = OPENCODE_PLUGIN_ROOT / "AGENTS.md"

# Install-time location on the user's machine. opencode has no ${PLUGIN_ROOT}
# variable, so any absolute path inside generated content rewrites to here.
HOME_INSTALL_OPENCODE_ROOT = "~/.config/opencode"
SHELL_SUFFIXES = frozenset({".sh", ".bash"})

# Path to the committed model-alias table and the optional user override file.
MODEL_ALIASES_PATH = REPO_ROOT / "scripts" / "opencode_model_aliases.json"
MODEL_ALIASES_LOCAL_PATH = REPO_ROOT / "scripts" / "opencode_model_aliases.local.json"

# opencode agent colors must be hex colors or one of its theme color tokens.
# Claude agent metadata commonly uses simple color names; normalize those names
# at generation time so ycc/agents can remain the source of truth for all targets.
OPENCODE_THEME_COLORS: frozenset[str] = frozenset(
    {
        "primary",
        "secondary",
        "accent",
        "success",
        "warning",
        "error",
        "info",
    }
)

CLAUDE_COLOR_TO_OPENCODE_HEX: dict[str, str] = {
    "blue": "#3B82F6",
    "cyan": "#06B6D4",
    "green": "#22C55E",
    "magenta": "#D946EF",
    "orange": "#F97316",
    "pink": "#EC4899",
    "purple": "#8B5CF6",
    "red": "#EF4444",
    "yellow": "#EAB308",
}


def normalize_agent_color(value: object) -> str | None:
    """Return an opencode-valid color value or ``None`` if it cannot be mapped."""
    if not isinstance(value, str):
        return None

    color = value.strip()
    if not color:
        return None

    lowered = color.lower()
    if lowered in OPENCODE_THEME_COLORS:
        return lowered
    if lowered in CLAUDE_COLOR_TO_OPENCODE_HEX:
        return CLAUDE_COLOR_TO_OPENCODE_HEX[lowered]
    if re.fullmatch(r"#[0-9a-fA-F]{6}", color):
        return color
    if re.fullmatch(r"[0-9a-fA-F]{6}", color):
        return f"#{color}"
    return None


# ---------------------------------------------------------------------------
# Skill-tree files copied verbatim. They describe / check all four deployment
# targets literally, so blind text replacement would corrupt them. Paths are
# source-relative to ycc/skills/.
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Agent aliases — mirror of generate_codex_common.load_agent_aliases but
# kept local so the opencode generator can evolve independently.
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# Model alias loader
# ---------------------------------------------------------------------------


def load_model_aliases() -> dict[str, str]:
    """Load the committed model alias table and, if present, merge the
    user-local override file on top. The ``$comment`` key is stripped.

    Missing committed table is a hard error — the generator should never run
    without it.
    """
    if not MODEL_ALIASES_PATH.is_file():
        raise SystemExit(
            f"opencode model alias file not found: {MODEL_ALIASES_PATH}. "
            "Restore scripts/opencode_model_aliases.json before running the generator."
        )

    with MODEL_ALIASES_PATH.open("r", encoding="utf-8") as handle:
        aliases = json.load(handle)
    if not isinstance(aliases, dict):
        raise SystemExit(f"{MODEL_ALIASES_PATH} must be a JSON object; got {type(aliases).__name__}.")

    if MODEL_ALIASES_LOCAL_PATH.is_file():
        try:
            with MODEL_ALIASES_LOCAL_PATH.open("r", encoding="utf-8") as handle:
                local = json.load(handle)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"{MODEL_ALIASES_LOCAL_PATH} is not valid JSON: {exc}") from exc
        if not isinstance(local, dict):
            raise SystemExit(f"{MODEL_ALIASES_LOCAL_PATH} must be a JSON object; got {type(local).__name__}.")
        aliases = {**aliases, **local}

    aliases.pop("$comment", None)
    # Only keep string->string entries; silently drop anything else rather than
    # emitting invalid opencode frontmatter.
    return {k: v for k, v in aliases.items() if isinstance(k, str) and isinstance(v, str)}


# Claude Code shorthands that explicitly mean "use the invoking agent's model"
# or "use the global default". opencode already implements that behavior when
# the `model` field is absent, so these values drop cleanly without a warning.
MODEL_DROP_SENTINELS: frozenset[str] = frozenset({"inherit", "default", ""})


def map_model(value: str | None, aliases: dict[str, str]) -> str | None:
    """Resolve a Claude-style model shorthand to an opencode ``provider/model``
    identifier. Returns ``None`` if the value is missing, empty, or unmapped.

    A ``None`` return signals the generator to drop the ``model`` frontmatter
    key, causing opencode to fall back to the global default configured in
    ``opencode.json``.
    """
    if not value:
        return None
    cleaned = value.strip()
    if cleaned in MODEL_DROP_SENTINELS:
        return None
    # Pass-through for values that already look like opencode provider/model ids.
    if "/" in cleaned:
        return cleaned
    return aliases.get(cleaned)


def is_model_drop_sentinel(value: str | None) -> bool:
    """Return True if ``value`` is a known placeholder that should be dropped
    without warning (e.g. ``inherit``, ``default``). Used by the agents and
    commands generators to silence expected-unmapped warnings.
    """
    if not value:
        return True
    return value.strip() in MODEL_DROP_SENTINELS


# ---------------------------------------------------------------------------
# Text transforms
# ---------------------------------------------------------------------------


def rewrite_plugin_paths(text: str) -> str:
    """Rewrite ``${CLAUDE_PLUGIN_ROOT}/skills/<path>`` references to absolute
    opencode install paths, since opencode has no plugin-root variable.

    ``_shared/`` is relocated to ``shared/`` to match the installed layout.
    """
    pattern = r"\$\{CLAUDE_PLUGIN_ROOT\}/skills/([^\"`\s]+)"

    def replace(match: re.Match[str]) -> str:
        path_text = match.group(1)
        if path_text.startswith("_shared/"):
            return f"{HOME_INSTALL_OPENCODE_ROOT}/shared/{path_text[len('_shared/') :]}"
        return f"{HOME_INSTALL_OPENCODE_ROOT}/skills/{path_text}"

    return re.sub(pattern, replace, text)


def apply_opencode_text_transforms(
    text: str,
    aliases: dict[str, str],
    *,
    rewrite_source_paths: bool = True,
    rewrite_runtime_aliases: bool = True,
    output_suffix: str = ".md",
) -> str:
    """Apply the opencode-native rewrite pass.

    Targets: product names, config paths, plugin-root variable, slash-command
    namespace, Task-tool orchestration phrasing, and Claude-only tool names.
    The order mirrors the Codex transform so tests can compare outputs.
    ``output_suffix`` gates the quoted-home rewrite to shell and Markdown files
    (see generate_codex_common.expand_quoted_home).
    """
    text, verbatim_blocks = protect_marked_verbatim_blocks(text)
    output = fix_mcp_malformed_tokens(text)

    # Product / file naming
    output = output.replace("CLAUDE.md", "AGENTS.md")
    output = output.replace("claude.template.md", "agents.template.md")
    output = output.replace(".claude-plugin/", ".opencode-plugin/")
    output = output.replace('".claude-plugin"', '".opencode-plugin"')
    output = output.replace("'.claude-plugin'", "'.opencode-plugin'")
    if rewrite_source_paths:
        output = re.sub(r"\bycc/skills/", ".opencode-plugin/skills/", output)
        output = re.sub(r"\bycc/agents/", ".opencode-plugin/agents/", output)

    # Repo-local worktree roots MUST be rewritten before generic config paths.
    output = output.replace("/.claude/worktrees", "/.opencode/worktrees")
    # Home / config paths (XDG) remain user-global for settings and hooks.
    output = output.replace("~/.claude/", "~/.config/opencode/")
    output = re.sub(r"\$\{HOME\}/\.claude/", r"${HOME}/.config/opencode/", output)
    output = re.sub(r"\$HOME/\.claude/", r"$HOME/.config/opencode/", output)
    output = output.replace("/.claude/", "/.config/opencode/")
    output = output.replace("../../_shared/scripts", "../../../shared/scripts")
    output = rewrite_plugin_paths(output)
    # Tilde does not expand inside double quotes (SC2088); use ${HOME} there —
    # shell and Markdown output only, never Python/JSON/YAML/... text.
    output = expand_quoted_home(output, ".config/opencode/", output_suffix)

    # Product wording (opencode is the product's own lowercase branding).
    #
    # Carve-out: the phrase "Claude Code only" appears in flag descriptions
    # where the feature genuinely requires Claude Code's Team/Task primitives
    # (which opencode does not expose). Preserve that advisory verbatim so we
    # don't mis-advertise those flags as opencode features.
    _CLAUDE_ONLY_SENTINEL = "\x00CLAUDE_CODE_ONLY_ADVISORY\x00"
    output = output.replace("Claude Code only", _CLAUDE_ONLY_SENTINEL)
    output = output.replace("Claude Code", "opencode")
    output = output.replace("Claude CLI", "opencode")
    output = output.replace("Claude home directory", "opencode home directory")
    output = output.replace("main Claude session", "main opencode session")
    output = output.replace("the main Claude session", "the main opencode session")
    output = output.replace("Restart Claude CLI", "Restart opencode")
    output = output.replace("Claude CLI logs", "opencode logs")
    output = output.replace(
        "set up Claude CLI environment",
        "set up the opencode environment",
    )
    output = output.replace("closing Claude Code", "closing opencode")
    output = output.replace("a live Claude Code session", "a live opencode session")
    output = re.sub(
        r"\bClaude API with structured output\b",
        "LLM API with structured output",
        output,
    )

    # Slash-command and agent namespace references
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

    # Claude-specific tool/agent phrasing -> opencode-native wording.
    def _dispatch_phrase(name: str) -> str:
        resolved = map_namespaced_reference(name, aliases)
        return f"Mention `@{resolved}` or invoke it via the built-in `task` tool"

    output = re.sub(
        r'Use the Task tool with \*\*`subagent_type: "([^"]+)"`\*\*',
        lambda match: _dispatch_phrase(match.group(1)),
        output,
    )
    output = re.sub(
        r'Use the Agent tool with `subagent_type: "([^"]+)"`',
        lambda match: _dispatch_phrase(match.group(1)),
        output,
    )
    output = re.sub(
        r'`subagent_type: "([^"]+)"`',
        lambda match: f"`@{map_namespaced_reference(match.group(1), aliases)}`",
        output,
    )
    output = re.sub(
        r", each with `team_name=\"[^\"]+\"`",
        "",
        output,
    )
    output = output.replace("Task tool calls", "parallel subagent invocations")
    output = output.replace("Task tool call", "subagent invocation")
    output = output.replace("Task tool", "opencode `task` tool")
    output = output.replace("Agent tool calls", "parallel subagent invocations")
    output = output.replace("Agent tool call", "subagent invocation")
    output = output.replace("Agent tool", "opencode `task` tool")
    output = output.replace("TodoWrite", "the todo tracker")
    output = output.replace("AskUserQuestion", "ask the user")
    output = output.replace("TeamCreate", "spawn coordinated subagents")
    output = output.replace("TeamDelete", "end the coordinated run")
    output = output.replace("TaskCreate", "track the task")
    output = output.replace("TaskUpdate", "update the todo tracker")
    output = output.replace("TaskList", "the todo tracker")
    output = output.replace("TaskGet", "the task details")
    output = output.replace("SendMessage", "send follow-up instructions")
    output = output.replace('message={type: "shutdown_request"}', "a shutdown request")

    # Restore the Claude-Code-only advisory phrase so it survives the transform.
    output = output.replace(_CLAUDE_ONLY_SENTINEL, "Claude Code only")

    if output and not output.endswith("\n"):
        output += "\n"
    return restore_marked_verbatim_blocks(output, verbatim_blocks)


# ---------------------------------------------------------------------------
# MCP translation: Claude Code shape -> opencode shape
# ---------------------------------------------------------------------------


def translate_opencode_env(value: Any) -> Any:
    """Translate shell-style env placeholders to opencode config variables.

    The shared MCP source uses ``${TOKEN_NAME}``, which works for Claude/Codex
    but is a literal string in opencode. opencode expects ``{env:TOKEN_NAME}``.
    """
    if isinstance(value, str):
        return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", r"{env:\1}", value)
    if isinstance(value, list):
        return [translate_opencode_env(item) for item in value]
    if isinstance(value, dict):
        return {key: translate_opencode_env(item) for key, item in value.items()}
    return value


def translate_mcp_servers(servers: dict[str, Any]) -> dict[str, Any]:
    """Translate a Claude Code ``mcpServers`` mapping to opencode's ``mcp``
    mapping.

    Critical shape differences:
    - Claude uses ``{command, args, env}``; opencode merges command+args into a
      single ``command: [...]`` array and renames ``env`` to ``environment``.
    - Remote servers in opencode require ``type: "remote"`` and use ``headers``
      / ``oauth`` / ``url`` fields directly.
    - OpenCode V2 gates a server with ``disabled: true``; the V1 ``enabled``
      field is not part of the V2 server shape.
    """
    translated: dict[str, Any] = {}
    for name, raw in servers.items():
        if not isinstance(raw, dict):
            # Preserve non-dict entries verbatim so unusual shapes pass through
            # untouched when the user hand-edits mcp-configs/mcp.json later.
            translated[name] = raw
            continue

        # Already opencode-shaped? Pass through.
        if raw.get("type") in {"local", "remote"}:
            translated[name] = translate_opencode_env(dict(raw))
            continue

        # Remote-looking (has a URL)?
        if "url" in raw:
            entry: dict[str, Any] = {"type": "remote", "url": raw["url"]}
            if "headers" in raw:
                entry["headers"] = raw["headers"]
            if "oauth" in raw:
                entry["oauth"] = raw["oauth"]
            if "timeout" in raw:
                entry["timeout"] = raw["timeout"]
            if raw.get("enabled") is False or raw.get("disabled") is True:
                entry["disabled"] = True
            translated[name] = translate_opencode_env(entry)
            continue

        # Local: merge command + args, rename env -> environment.
        command_head = raw.get("command")
        args = raw.get("args") or []
        if isinstance(command_head, list):
            command_array = list(command_head) + list(args)
        elif isinstance(command_head, str):
            command_array = [command_head, *args]
        else:
            # Nothing to run — preserve shape but mark so a later validator
            # catches it.
            command_array = []

        entry = {"type": "local", "command": command_array}
        if "env" in raw:
            entry["environment"] = raw["env"]
        if "timeout" in raw:
            entry["timeout"] = raw["timeout"]
        if raw.get("enabled") is False or raw.get("disabled") is True:
            entry["disabled"] = True
        translated[name] = translate_opencode_env(entry)
    return translated
