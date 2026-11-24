#!/usr/bin/env python3
"""Generate Google Antigravity plugins under packages/antigravity/ from ycc sources.

Antigravity (the App, the IDE and the ``agy`` CLI) loads plugins from
``~/.gemini/config/plugins/<plugin>/``. Each plugin root holds ``plugin.json``
(schema https://antigravity.google/schemas/v1/plugin.json; ``name`` required,
``additionalProperties: false``) plus default component folders:

    packages/antigravity/ycc/        skills/<name>/SKILL.md, ycc-shared/, agents/<name>.md
    packages/antigravity/ycc-mcp/    mcp_config.json  (top-level mcpServers)
    packages/antigravity/ycc-rules/  rules/ycc-<family>-<stem>.md  (trigger frontmatter)

Porting facts (vs Claude Code):
- Skills get no plugin-root variable; ``${CLAUDE_PLUGIN_ROOT}/skills/...`` is
  rewritten to the global install root ``~/.gemini/config/plugins/ycc``. The
  skills pass is the agents-target pass (generate_agents_skills.write_tree) with
  this install root, so ``_shared`` ships as the sibling ``ycc-shared/``.
- Skill frontmatter: ``name`` (must match the folder), ``description`` (<=1024),
  optional ``disable-model-invocation``, ``license``, ``compatibility``.
- Agent frontmatter: ``name``, ``description``, ``tools`` (Antigravity tool
  names; an unmapped name can hang a subagent, so the map is closed) and
  ``model`` (``inherit``/``flash``/``pro`` from models.json targets.antigravity).
- Rules need ``trigger`` frontmatter (``always_on``/``glob``/``model_decision``);
  a rule without a valid trigger is silently dropped by Antigravity.
- Remote MCP servers use ``serverUrl`` (Streamable HTTP); stdio servers keep
  command/args/env. Identity env pass-throughs (``FOO: ${FOO}``) are dropped:
  the server inherits the variable from the launching environment.

Source of truth: ycc/. Output is deterministic; ``--check`` fails on drift.
"""

from __future__ import annotations

import argparse
import json
import posixpath
import re
import stat
import sys
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml
from generate_agents_common import (
    apply_agents_text_transforms,
    dump_frontmatter,
    load_agent_aliases,
    parse_frontmatter,
)
from generate_agents_skills import SkillLayout
from generate_agents_skills import write_tree as write_skill_tree
from generate_omp_rules import build_rules as build_omp_rules
from mcp_secret_audit import PLACEHOLDER, audit_no_secret_literals, load_mcp_config

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOT = REPO_ROOT / "packages/antigravity"
SOURCE_PLUGIN_PATH = REPO_ROOT / "ycc/.claude-plugin/plugin.json"
SOURCE_AGENTS_DIR = REPO_ROOT / "ycc/agents"
SOURCE_MCP_PATH = REPO_ROOT / "mcp-configs/mcp.json"
SOURCE_RULES_DIR = REPO_ROOT / "ycc/rules"
MODELS_PATH = REPO_ROOT / "ycc/settings/models.json"

PLUGIN_SCHEMA = "https://antigravity.google/schemas/v1/plugin.json"
INSTALL_ROOT = "~/.gemini/config/plugins"
YCC_INSTALL_ROOT = f"{INSTALL_ROOT}/ycc"
# Antigravity worktrees live under their own repo-local root (see worktree-strategy.md).
WORKTREE_LINE = "printf '%s/.antigravity/worktrees\\n' \"$repo_root\""
AUTHOR = {"name": "yandy-r"}
REPOSITORY = "https://github.com/yandy-r/ystack"

PACKAGES: dict[str, tuple[str, str]] = {
    "ycc": ("ycc", "Planning, implementation, review, and git-workflow skills and agents."),
    "ycc-mcp": ("ycc MCP", "MCP server connections for the ycc skills and agents."),
    "ycc-rules": ("ycc rules", "Language and common coding rules for the ycc workflow."),
}

ANTIGRAVITY_SKILL_KEYS = ("license", "compatibility")
SKILL_LAYOUT = SkillLayout(
    install_root=YCC_INSTALL_ROOT,
    worktree_default_line=WORKTREE_LINE,
    optional_keys=ANTIGRAVITY_SKILL_KEYS,
    emit_invocation_flag=True,
)

# Claude tool -> Antigravity tool names (the standard names listed in the
# Antigravity hooks reference). Closed map: an unknown source tool fails the run.
# Scoped Bash(...) grants map to run_command; Antigravity scopes commands through
# commandExecutionPolicy (default: sandbox), not per-command patterns.
TOOL_MAP: dict[str, tuple[str, ...]] = {
    "Read": ("view_file", "list_dir"),
    "Grep": ("grep_search",),
    "Glob": ("find_by_name", "list_dir"),
    "Write": ("write_to_file",),
    "Edit": ("replace_file_content", "multi_replace_file_content"),
    "NotebookEdit": ("replace_file_content",),
    "Bash": ("run_command",),
    "WebFetch": ("read_url_content",),
    "WebSearch": ("search_web",),
}
ANTIGRAVITY_TOOLS = frozenset(tool for tools in TOOL_MAP.values() for tool in tools)
ANTIGRAVITY_MODELS = frozenset({"inherit", "flash", "pro"})
AGENT_KEYS = ("name", "description", "tools", "model")

RULE_TRIGGERS = frozenset({"always_on", "model_decision", "glob", "manual"})
RULE_MAX_BYTES = 24_000
_RULE_LINK_RE = re.compile(r"\]\(rule://(ycc-[a-z0-9-]+)\)")


@dataclass(frozen=True)
class Payload:
    content: bytes
    executable: bool = False


Tree = dict[Path, Payload]


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def json_payload(value: Any) -> Payload:
    return Payload((json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))


def lockstep_version() -> str:
    version = read_json(SOURCE_PLUGIN_PATH).get("version")
    if not isinstance(version, str) or not version.strip():
        raise ValueError(f"{SOURCE_PLUGIN_PATH}: missing nonempty version")
    return version


def plugin_manifest(key: str, version: str) -> dict[str, Any]:
    display, description = PACKAGES[key]
    return {
        "$schema": PLUGIN_SCHEMA,
        "name": key,
        "displayName": display,
        "version": version,
        "description": description,
        "author": dict(AUTHOR),
        "repository": REPOSITORY,
        "license": "MIT",
    }


# ---------------------------------------------------------------------------
# ycc: skills + ycc-shared + agents
# ---------------------------------------------------------------------------


def skill_tree() -> Tree:
    """Render skills through the shared flat-skills writer into a temp dir."""
    tree: Tree = {}
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for rel in sorted(write_skill_tree(root, dry_run=False, layout=SKILL_LAYOUT)):
            path = root / rel
            tree[rel] = Payload(path.read_bytes(), bool(path.stat().st_mode & stat.S_IXUSR))
    return tree


def agent_model_map() -> dict[str, str]:
    target = read_json(MODELS_PATH).get("targets", {}).get("antigravity")
    models = target.get("agentModels") if isinstance(target, dict) else None
    if not isinstance(models, dict) or not models:
        raise ValueError(f"{MODELS_PATH}: targets.antigravity.agentModels is required")
    for source, mapped in models.items():
        if mapped not in ANTIGRAVITY_MODELS:
            raise ValueError(
                f"{MODELS_PATH}: antigravity model for {source!r} must be one of {sorted(ANTIGRAVITY_MODELS)}"
            )
    return {str(k): str(v) for k, v in models.items()}


def source_tools(value: object, agent: str) -> list[str]:
    if value is None:
        return []
    items = [part.strip() for part in value.split(",")] if isinstance(value, str) else value
    if not isinstance(items, list) or not all(isinstance(item, str) for item in items):
        raise ValueError(f"agent {agent}: tools must be a string or list of strings")
    return [item for item in items if item]


def map_tools(tools: list[str], agent: str) -> list[str]:
    mapped: list[str] = []
    for tool in tools:
        base = tool.split("(", 1)[0].strip()
        if base.startswith("mcp__"):
            continue  # MCP tools arrive through the ycc-mcp plugin, not the tools list.
        if base not in TOOL_MAP:
            raise ValueError(f"agent {agent}: no Antigravity mapping for tool {tool!r}")
        for name in TOOL_MAP[base]:
            if name not in mapped:
                mapped.append(name)
    return mapped


def antigravity_text(text: str, aliases: dict[str, str]) -> str:
    """The agents-target rewrite pass pointed at the Antigravity ycc plugin."""
    return apply_agents_text_transforms(
        text, aliases, install_root=YCC_INSTALL_ROOT, worktree_default_line=WORKTREE_LINE
    )


def transform_agent(raw: str, aliases: dict[str, str], models: Mapping[str, str]) -> str:
    frontmatter, body = parse_frontmatter(raw)
    name = str(frontmatter.get("name") or "").strip()
    description = " ".join(str(frontmatter.get("description") or "").split())
    if not name or not description:
        raise ValueError(f"agent {name or '<unnamed>'}: name and description are required")
    source_model = str(frontmatter.get("model") or "inherit")
    if source_model not in models:
        raise ValueError(f"agent {name}: model {source_model!r} has no targets.antigravity.agentModels entry")
    payload: dict[str, object] = {
        "name": name,
        "description": antigravity_text(description, aliases).strip(),
        "tools": map_tools(source_tools(frontmatter.get("tools"), name), name),
        "model": models[source_model],
    }
    return dump_frontmatter(payload) + antigravity_text(body, aliases)


def agent_tree() -> Tree:
    aliases = load_agent_aliases()
    models = agent_model_map()
    tree: Tree = {}
    for path in sorted(SOURCE_AGENTS_DIR.glob("*.md")):
        text = transform_agent(path.read_text(encoding="utf-8"), aliases, models)
        tree[Path("agents") / path.name] = Payload(text.encode("utf-8"))
    if not tree:
        raise ValueError(f"{SOURCE_AGENTS_DIR}: no agents found")
    return tree


# ---------------------------------------------------------------------------
# ycc-mcp: mcp_config.json
# ---------------------------------------------------------------------------


def is_identity_passthrough(key: str, value: object) -> bool:
    """True for ``KEY: ${KEY}``: the server inherits KEY from its environment anyway."""
    match = PLACEHOLDER.fullmatch(value) if isinstance(value, str) else None
    return match is not None and match.group(1) == key


def translate_server(name: str, server: Mapping[str, Any]) -> dict[str, Any]:
    kind = server.get("type")
    if kind not in {None, "stdio", "http", "streamable-http"}:
        raise ValueError(f"mcp server {name}: unsupported transport {kind!r} (Antigravity: stdio or Streamable HTTP)")
    if kind in {"http", "streamable-http"} or ("url" in server and "command" not in server):
        url = server.get("url")
        if not isinstance(url, str) or not url:
            raise ValueError(f"mcp server {name}: remote server needs a url")
        out: dict[str, Any] = {"serverUrl": url}
        if isinstance(server.get("headers"), dict):
            out["headers"] = dict(server["headers"])
        return out
    command = server.get("command")
    if not isinstance(command, str) or not command:
        raise ValueError(f"mcp server {name}: stdio server needs a command")
    out = {"command": command}
    if server.get("args"):
        out["args"] = list(server["args"])
    env = {key: value for key, value in (server.get("env") or {}).items() if not is_identity_passthrough(key, value)}
    if env:
        out["env"] = env
    return out


def mcp_tree() -> Tree:
    config = load_mcp_config(SOURCE_MCP_PATH.read_bytes(), str(SOURCE_MCP_PATH))
    audit_no_secret_literals(config, str(SOURCE_MCP_PATH))
    servers = {name: translate_server(name, server) for name, server in config["mcpServers"].items()}
    return {Path("mcp_config.json"): json_payload({"mcpServers": servers})}


# ---------------------------------------------------------------------------
# ycc-rules: rules/*.md with Antigravity trigger frontmatter
# ---------------------------------------------------------------------------


def antigravity_rule(name: str, text: str) -> str | None:
    """Convert one flat OMP-shaped rule into Antigravity form; None drops it."""
    match = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
    if not match:
        raise ValueError(f"{name}: generated rule lacks frontmatter")
    data = yaml.safe_load(match.group(1)) or {}
    body = text[match.end() :]
    if "condition" in data:
        return None  # OMP TTSR edit triggers; Antigravity glob rules already attach on match.
    out: dict[str, object]
    if data.get("alwaysApply") is True:
        out = {"trigger": "always_on", "description": data["description"]}
    elif data.get("globs"):
        out = {"trigger": "glob", "description": data["description"], "globs": ",".join(data["globs"])}
    else:
        out = {"trigger": "model_decision", "description": data["description"]}
    # rule://ycc-x links become sibling file links in the flat rules/ folder.
    body = _RULE_LINK_RE.sub(lambda m: f"]({m.group(1)}.md)", body)
    rendered = dump_frontmatter(out) + body
    if len(rendered.encode("utf-8")) > RULE_MAX_BYTES:
        raise ValueError(
            f"{name}: {len(rendered.encode('utf-8'))} bytes exceeds Antigravity's {RULE_MAX_BYTES}-byte rule limit"
        )
    return rendered


def rules_tree() -> Tree:
    tree: Tree = {}
    for name, text in sorted(build_omp_rules(SOURCE_RULES_DIR).items()):
        rendered = antigravity_rule(name, text)
        if rendered is not None:
            tree[Path("rules") / name] = Payload(rendered.encode("utf-8"))
    return tree


# ---------------------------------------------------------------------------
# Assembly, write, check
# ---------------------------------------------------------------------------


def build() -> Tree:
    """Return every generated file, keyed by path relative to OUTPUT_ROOT."""
    version = lockstep_version()
    components: dict[str, Tree] = {
        "ycc": {**skill_tree(), **agent_tree()},
        "ycc-mcp": mcp_tree(),
        "ycc-rules": rules_tree(),
    }
    tree: Tree = {}
    for key, files in components.items():
        tree[Path(key) / "plugin.json"] = json_payload(plugin_manifest(key, version))
        for rel, payload in files.items():
            tree[Path(key) / rel] = payload
    return tree


def write(tree: Tree, root: Path = OUTPUT_ROOT) -> None:
    for rel, payload in tree.items():
        out = root / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        if not out.exists() or out.read_bytes() != payload.content:
            out.write_bytes(payload.content)
        mode = 0o755 if payload.executable else 0o644
        if stat.S_IMODE(out.stat().st_mode) != mode:
            out.chmod(mode)
    # Prune files this generator no longer emits, then empty directories.
    for key in PACKAGES:
        package_dir = root / key
        if not package_dir.is_dir():
            continue
        for path in sorted(package_dir.rglob("*"), key=lambda p: len(p.parts), reverse=True):
            rel = path.relative_to(root)
            if path.is_file() and rel not in tree:
                path.unlink()
            elif path.is_dir() and not any(path.iterdir()):
                path.rmdir()


def check(tree: Tree, root: Path = OUTPUT_ROOT) -> list[str]:
    diffs: list[str] = []
    for rel, payload in sorted(tree.items()):
        path = root / rel
        if not path.is_file():
            diffs.append(f"missing: {rel}")
        elif path.read_bytes() != payload.content:
            diffs.append(f"drift: {rel}")
        elif bool(path.stat().st_mode & stat.S_IXUSR) != payload.executable:
            diffs.append(f"mode: {rel}")
    for key in PACKAGES:
        package_dir = root / key
        if package_dir.is_dir():
            diffs += [
                f"extra: {path.relative_to(root)}"
                for path in sorted(package_dir.rglob("*"))
                if path.is_file() and path.relative_to(root) not in tree
            ]
    return diffs


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check", action="store_true", help="exit 1 if packages/antigravity drifts from generator output"
    )
    mode.add_argument("--dry-run", action="store_true", help="print the files that would be written")
    args = parser.parse_args(argv)
    try:
        tree = build()
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if args.check:
        diffs = check(tree)
        for line in diffs:
            print(f"  {line}", file=sys.stderr)
        if diffs:
            print(
                "Antigravity packages are out of date. Run: ./scripts/generate-antigravity-packages.sh", file=sys.stderr
            )
            return 1
        return 0
    if args.dry_run:
        for rel in sorted(tree):
            print(f"Would write {posixpath.join('packages/antigravity', rel.as_posix())}")
        return 0
    write(tree)
    print(f"Wrote {len(tree)} files under {OUTPUT_ROOT.relative_to(REPO_ROOT)} ({', '.join(PACKAGES)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
