#!/usr/bin/env python3
"""Generate Muse Code plugins under packages/muse/ from ycc sources.

Muse Code (``muse``, Meta's terminal coding agent) installs plugin bundles with
``muse plugins install <path>`` into its own cache. It reads two manifest
families (verified against muse 1.4.25 with ``muse plugins validate``):

    packages/muse/ycc/       .claude-plugin/plugin.json (claude-compatible family):
                             skills/<name>/SKILL.md, ycc-shared/, agents/<name>.md
    packages/muse/ycc-mcp/   .muse-plugin/plugin.json (native family):
                             capabilities.mcpServers + mcp/<server>.sh launchers
    packages/muse/ycc-rules/ .muse-plugin/plugin.json (native family):
                             capabilities.skills -> rules/<rule>/SKILL.md

Porting facts (vs Claude Code):
- The native manifest rejects an ``agents`` capability and, when present, wins
  over ``.claude-plugin``; only the claude-compatible family imports
  ``agents/*.md``. So ``ycc`` ships the Claude manifest and ``ycc-mcp`` the
  native one (Claude-format ``.mcp.json`` accepts stdio servers only).
- Muse caches each install under a content digest, so skills get no stable
  plugin root: ``${CLAUDE_PLUGIN_ROOT}/skills/...`` is rewritten to the owned
  copy ``~/.local/share/ycc/muse/ycc`` that ``install.sh --target muse`` keeps
  (and installs from). ``_shared`` ships as the sibling ``ycc-shared/``.
- Skill frontmatter: ``name``, ``description``, ``disable-model-invocation``
  (Muse lists it as ``user-invocable-only``) and ``argument-hint``.
  ``allowed-tools`` is dropped: Muse grants nothing for it and warns.
- Commands: the claude-compatible family imports ``commands/<name>.md``. Every
  public skill (not ``user-invocable: false``) gets one thin entrypoint that tells
  Muse to load ``plugin:ycc:<skill>`` and follow it with ``$ARGUMENTS``.
- Agent frontmatter: ``name`` (``^[a-z]+(-[a-z]+)*$``), ``description``,
  ``tools`` and an optional ``model``. Muse projects Claude tool names except
  ``Glob`` (its ``search`` tool covers globbing, so ``Glob`` is dropped) and
  silently refuses an agent whose ``color`` is outside its palette, so
  ``color`` is never emitted. ``model`` comes from models.json
  ``targets.muse.agentModels``; ``inherit`` omits it.
- Native MCP: stdio ``command`` is argv, and any element containing ``/`` is
  resolved as a plugin-relative file, so every stdio server runs through a
  generated ``mcp/<id>.sh`` launcher. Remote servers use ``transport: http``.
  Server ids must match ``^[a-z0-9][a-z0-9._-]{0,79}$`` (camelCase is
  rewritten to kebab-case).

- Rules: Muse plugins have no rules family. ``ycc-rules`` ships each flat ycc
  rule as a skill (``rules/<rule>/SKILL.md``) whose description is the rule's
  "When ..." trigger plus its file globs, so Muse loads it on relevance, like a
  ``model_decision`` / glob rule elsewhere. OMP-only edit-trigger rules are
  omitted; always-on guidance also reaches Muse through ``--rules`` (AGENTS.md).

Source of truth: ycc/. Output is deterministic; ``--check`` fails on drift.
"""

from __future__ import annotations

import argparse
import json
import posixpath
import re
import shlex
import stat
import sys
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from generate_agents_common import (
    apply_agents_text_transforms,
    dump_frontmatter,
    load_agent_aliases,
    parse_frontmatter,
)
from generate_agents_skills import SkillLayout
from generate_agents_skills import write_tree as write_skill_tree
from generate_omp_rules import build_rules as build_omp_rules
from mcp_secret_audit import audit_no_secret_literals, load_mcp_config

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOT = REPO_ROOT / "packages/muse"
SOURCE_PLUGIN_PATH = REPO_ROOT / "ycc/.claude-plugin/plugin.json"
SOURCE_AGENTS_DIR = REPO_ROOT / "ycc/agents"
SOURCE_SKILLS_DIR = REPO_ROOT / "ycc/skills"
SOURCE_MCP_PATH = REPO_ROOT / "mcp-configs/mcp.json"
MODELS_PATH = REPO_ROOT / "ycc/settings/models.json"
SOURCE_RULES_DIR = REPO_ROOT / "ycc/rules"

# The owned copies install.sh keeps (and installs from); see scripts/muse_install.py.
INSTALL_ROOT = "~/.local/share/ycc/muse"
YCC_INSTALL_ROOT = f"{INSTALL_ROOT}/ycc"
# Muse worktrees live under their own repo-local root (see worktree-strategy.md).
WORKTREE_LINE = "printf '%s/.muse/worktrees\\n' \"$repo_root\""
AUTHOR = {"name": "yandy-r"}
REPOSITORY = "https://github.com/yandy-r/ystack"

PACKAGES: dict[str, tuple[str, str]] = {
    "ycc": ("ycc", "Planning, implementation, review, and git-workflow skills and agents."),
    "ycc-mcp": ("ycc MCP", "MCP server connections for the ycc skills and agents."),
    "ycc-rules": ("ycc rules", "Language and common coding rules for the ycc workflow."),
}
# Which manifest family each package uses (see the module docstring).
CLAUDE_FAMILY = frozenset({"ycc"})

MUSE_SKILL_KEYS = ("argument-hint",)
SKILL_LAYOUT = SkillLayout(
    install_root=YCC_INSTALL_ROOT,
    worktree_default_line=WORKTREE_LINE,
    optional_keys=MUSE_SKILL_KEYS,
    emit_invocation_flag=True,
)

# Claude tool -> the Claude tool names Muse projects onto its own tools
# (read_file, search, write_file, edit_file, bash, web_fetch, web_search).
# Closed map: an unknown source tool fails the run. Glob has no projection
# (Muse's search covers globbing); scoped Bash(...) grants become plain Bash.
TOOL_MAP: dict[str, tuple[str, ...]] = {
    "Read": ("Read",),
    "Grep": ("Grep",),
    "Glob": ("Grep",),
    "Write": ("Write",),
    "Edit": ("Edit",),
    "NotebookEdit": ("Edit",),
    "Bash": ("Bash",),
    "WebFetch": ("WebFetch",),
    "WebSearch": ("WebSearch",),
}
MUSE_TOOLS = frozenset(tool for tools in TOOL_MAP.values() for tool in tools)
MUSE_MODELS = frozenset({"inherit", "opus", "sonnet", "haiku"})
AGENT_KEYS = ("name", "description", "tools", "model")
AGENT_NAME = re.compile(r"^[a-z]+(?:-[a-z]+)*$")
CAPABILITY_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")


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


def claude_manifest(key: str, version: str) -> dict[str, Any]:
    """claude-compatible manifest; Muse imports only name/version/description."""
    _display, description = PACKAGES[key]
    return {"name": key, "version": version, "description": description}


def native_manifest(
    key: str, version: str, mcp_servers: list[dict[str, Any]], skills: list[dict[str, Any]] | None = None
) -> dict[str, Any]:
    display, description = PACKAGES[key]
    return {
        "schemaVersion": 1,
        "name": key,
        "displayName": display,
        "version": version,
        "description": description,
        "compat": {"source": "native", "manifestDir": ".muse-plugin"},
        "capabilities": {
            "skills": skills or [],
            "commands": [],
            "hooks": [],
            "mcpServers": mcp_servers,
            "reminders": [],
        },
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
    target = read_json(MODELS_PATH).get("targets", {}).get("muse")
    models = target.get("agentModels") if isinstance(target, dict) else None
    if not isinstance(models, dict) or not models:
        raise ValueError(f"{MODELS_PATH}: targets.muse.agentModels is required")
    for source, mapped in models.items():
        if mapped not in MUSE_MODELS:
            raise ValueError(f"{MODELS_PATH}: muse model for {source!r} must be one of {sorted(MUSE_MODELS)}")
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
            raise ValueError(f"agent {agent}: no Muse mapping for tool {tool!r}")
        for name in TOOL_MAP[base]:
            if name not in mapped:
                mapped.append(name)
    return mapped


def muse_text(text: str, aliases: dict[str, str]) -> str:
    """The agents-target rewrite pass pointed at the owned Muse ycc copy."""
    return apply_agents_text_transforms(
        text, aliases, install_root=YCC_INSTALL_ROOT, worktree_default_line=WORKTREE_LINE
    )


def transform_agent(raw: str, aliases: dict[str, str], models: Mapping[str, str]) -> str:
    frontmatter, body = parse_frontmatter(raw)
    name = str(frontmatter.get("name") or "").strip()
    description = " ".join(str(frontmatter.get("description") or "").split())
    if not name or not description:
        raise ValueError(f"agent {name or '<unnamed>'}: name and description are required")
    if not AGENT_NAME.fullmatch(name):
        raise ValueError(f"agent {name}: Muse agent names must match {AGENT_NAME.pattern}")
    source_model = str(frontmatter.get("model") or "inherit")
    if source_model not in models:
        raise ValueError(f"agent {name}: model {source_model!r} has no targets.muse.agentModels entry")
    payload: dict[str, object] = {
        "name": name,
        "description": muse_text(description, aliases).strip(),
        "tools": map_tools(source_tools(frontmatter.get("tools"), name), name),
    }
    if models[source_model] != "inherit":
        payload["model"] = models[source_model]
    return dump_frontmatter(payload) + muse_text(body, aliases)


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


def public_skill(name: str) -> bool:
    """True unless the source skill is ``_``-prefixed or ``user-invocable: false``."""
    if name.startswith("_"):
        return False
    frontmatter, _body = parse_frontmatter((SOURCE_SKILLS_DIR / name / "SKILL.md").read_text(encoding="utf-8"))
    return frontmatter.get("user-invocable") is not False


def command_tree(skills: Tree) -> Tree:
    """One ``commands/<skill>.md`` entrypoint per public skill."""
    tree: Tree = {}
    for rel, payload in sorted(skills.items()):
        if rel.parts[0] != "skills" or rel.name != "SKILL.md" or len(rel.parts) != 3:
            continue
        name = rel.parts[1]
        if not public_skill(name):
            continue
        frontmatter, _body = parse_frontmatter(payload.content.decode("utf-8"))
        head: dict[str, object] = {"description": frontmatter["description"]}
        if frontmatter.get("argument-hint"):
            head["argument-hint"] = frontmatter["argument-hint"]
        body = (
            f"Load the `plugin:ycc:{name}` skill (`read_skill`) and follow its instructions"
            " with these arguments:\n\n$ARGUMENTS\n"
        )
        tree[Path("commands") / f"{name}.md"] = Payload((dump_frontmatter(head) + "\n" + body).encode("utf-8"))
    if not tree:
        raise ValueError(f"{SOURCE_SKILLS_DIR}: no public skills found")
    return tree


# ---------------------------------------------------------------------------
# ycc-mcp: native mcpServers + stdio launchers
# ---------------------------------------------------------------------------


def server_id(name: str) -> str:
    """Muse capability id for a source server name (camelCase -> kebab-case)."""
    kebab = re.sub(r"(?<=[a-z0-9])([A-Z])", r"-\1", name).lower()
    if not CAPABILITY_ID.fullmatch(kebab):
        raise ValueError(f"mcp server {name}: id {kebab!r} is not a valid Muse capability id")
    return kebab


def launcher(command: str, args: list[str]) -> Payload:
    line = shlex.join([command, *args])
    text = (
        "#!/bin/sh\n"
        "# Generated by scripts/generate_muse_packages.py: Muse resolves any argv element\n"
        "# containing '/' as a plugin file, so the server command runs from here.\n"
        f'exec {line} "$@"\n'
    )
    return Payload(text.encode("utf-8"), executable=True)


def translate_server(name: str, server: Mapping[str, Any]) -> tuple[dict[str, Any], Tree]:
    """Return the native mcpServers entry and any launcher files for one server."""
    sid = server_id(name)
    kind = server.get("type")
    if kind not in {None, "stdio", "http", "streamable-http"}:
        raise ValueError(f"mcp server {name}: unsupported transport {kind!r} (Muse: stdio or HTTP)")
    if kind in {"http", "streamable-http"} or ("url" in server and "command" not in server):
        url = server.get("url")
        if not isinstance(url, str) or not url:
            raise ValueError(f"mcp server {name}: remote server needs a url")
        entry: dict[str, Any] = {"id": sid, "transport": "http", "url": url}
        if isinstance(server.get("headers"), dict) and server["headers"]:
            entry["headers"] = dict(server["headers"])
        return entry, {}
    command = server.get("command")
    if not isinstance(command, str) or not command:
        raise ValueError(f"mcp server {name}: stdio server needs a command")
    args = [str(arg) for arg in server.get("args") or []]
    script = Path("mcp") / f"{sid}.sh"
    entry = {"id": sid, "transport": "stdio", "command": ["sh", script.as_posix()]}
    env = server.get("env") or {}
    if env:
        # Muse starts stdio servers with a small env allowlist plus this map, so the
        # ${VAR} pass-throughs stay (Muse expands them from its own environment).
        entry["env"] = dict(env)
    return entry, {script: launcher(command, args)}


def mcp_tree() -> tuple[list[dict[str, Any]], Tree]:
    config = load_mcp_config(SOURCE_MCP_PATH.read_bytes(), str(SOURCE_MCP_PATH))
    audit_no_secret_literals(config, str(SOURCE_MCP_PATH))
    entries: list[dict[str, Any]] = []
    files: Tree = {}
    for name, server in config["mcpServers"].items():
        entry, extra = translate_server(name, server)
        if any(existing["id"] == entry["id"] for existing in entries):
            raise ValueError(f"mcp server {name}: duplicate Muse id {entry['id']!r}")
        entries.append(entry)
        files.update(extra)
    return sorted(entries, key=lambda item: str(item["id"])), files


# ---------------------------------------------------------------------------
# ycc-rules: one native skill per flat ycc rule
# ---------------------------------------------------------------------------

RULE_LINK = re.compile(r"\]\(rule://(ycc-[a-z0-9-]+)\)")
SKILL_DESCRIPTION_MAX = 1024


def rule_skill(name: str, text: str) -> tuple[str, str] | None:
    """Convert one flat OMP-shaped rule into (skill id, SKILL.md); None drops it."""
    frontmatter, body = parse_frontmatter(text)
    if "condition" in frontmatter:
        return None  # OMP TTSR edit triggers; the glob rules carry the same guidance.
    rule_id = name.removesuffix(".md")
    if not CAPABILITY_ID.fullmatch(rule_id):
        raise ValueError(f"rule {name}: {rule_id!r} is not a valid Muse capability id")
    description = " ".join(str(frontmatter.get("description") or "").split())
    if not description:
        raise ValueError(f"rule {name}: description is required")
    globs = frontmatter.get("globs") or []
    if frontmatter.get("alwaysApply") is True:
        description = f"{description} Applies to every change."
    elif globs:
        description = f"{description} Applies to files matching {', '.join(str(g) for g in globs)}."
    if len(description) > SKILL_DESCRIPTION_MAX:
        raise ValueError(f"rule {name}: description exceeds {SKILL_DESCRIPTION_MAX} characters")
    # rule://ycc-x links point at the sibling rule skills.
    body = RULE_LINK.sub(lambda m: f"](../{m.group(1)}/SKILL.md)", body)
    return rule_id, dump_frontmatter({"name": rule_id, "description": description}) + body


def rules_tree() -> tuple[list[dict[str, Any]], Tree]:
    entries: list[dict[str, Any]] = []
    tree: Tree = {}
    for name, text in sorted(build_omp_rules(SOURCE_RULES_DIR).items()):
        converted = rule_skill(name, text)
        if converted is None:
            continue
        rule_id, rendered = converted
        rel = Path("rules") / rule_id / "SKILL.md"
        entries.append({"id": rule_id, "path": rel.as_posix(), "enabledDefault": True})
        tree[rel] = Payload(rendered.encode("utf-8"))
    if not tree:
        raise ValueError(f"{SOURCE_RULES_DIR}: no rules found")
    return entries, tree


# ---------------------------------------------------------------------------
# Assembly, write, check
# ---------------------------------------------------------------------------


def build() -> Tree:
    """Return every generated file, keyed by path relative to OUTPUT_ROOT."""
    version = lockstep_version()
    servers, launchers = mcp_tree()
    tree: Tree = {Path("ycc/.claude-plugin/plugin.json"): json_payload(claude_manifest("ycc", version))}
    skills = skill_tree()
    for rel, payload in {**skills, **command_tree(skills), **agent_tree()}.items():
        tree[Path("ycc") / rel] = payload
    tree[Path("ycc-mcp/.muse-plugin/plugin.json")] = json_payload(native_manifest("ycc-mcp", version, servers))
    for rel, payload in launchers.items():
        tree[Path("ycc-mcp") / rel] = payload
    rule_entries, rule_files = rules_tree()
    tree[Path("ycc-rules/.muse-plugin/plugin.json")] = json_payload(
        native_manifest("ycc-rules", version, [], rule_entries)
    )
    for rel, payload in rule_files.items():
        tree[Path("ycc-rules") / rel] = payload
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
    mode.add_argument("--check", action="store_true", help="exit 1 if packages/muse drifts from generator output")
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
            print("Muse packages are out of date. Run: ./scripts/generate-muse-packages.sh", file=sys.stderr)
            return 1
        return 0
    if args.dry_run:
        for rel in sorted(tree):
            print(f"Would write {posixpath.join('packages/muse', rel.as_posix())}")
        return 0
    write(tree)
    print(f"Wrote {len(tree)} files under {OUTPUT_ROOT.relative_to(REPO_ROOT)} ({', '.join(PACKAGES)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
