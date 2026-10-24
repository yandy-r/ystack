#!/usr/bin/env python3
"""Generate the experimental opt-in opencode npm package (YAN-1143 / GitHub #318).

Model-driven, mirroring generate_claude_packages.py / generate_cursor_packages.py:
the package row (@yandy-r/ycc-opencode, runtime opencode, mechanism npm, status
included) selects the output; nothing is keyed on catalog visibility. The emitted
packages/opencode/ycc-opencode tree is relocatable: every asset the V2 plugin
adapter registers lives inside the package and the runtime template
(scripts/opencode_templates/package-index.js, copied verbatim as index.js)
resolves paths from import.meta.url, so no install-root literal is baked.

Sources of truth (never a second convention):
- skills/shared: generate_opencode_skills.write_tree(dest_root, dry_run)
- agents: generate_opencode_agents.transform_agent(stem, raw, aliases)
- commands: generate_opencode_commands.transform_command(stem, raw, ...)
- MCP: generate_opencode_common.translate_mcp_servers(mcp-configs/mcp.json)
- instructions: generate_opencode_plugin.build_agents_md()
- agent models: ycc/settings/models.json via generate_opencode_plugin
- version: model.version_source (ycc/.claude-plugin/plugin.json, lockstep)

Path policy. The file-copy transform bakes `~/.config/opencode/<unit>/...` (and
`${CLAUDE_PLUGIN_ROOT}/skills/...` in verbatim-free text) because opencode has no
plugin-root variable. In the package the units that ship (skills, shared,
agents, commands) are rewritten by the kind of file that holds the reference:

- Markdown under skills/ and shared/: a `{{package-root}}` token. The skill's
  read base is model guidance only — the shell runs snippets from the session
  cwd — so at setup the adapter copies the units into a disposable rendered
  tree and replaces the token with that tree's absolute root in every Markdown
  file; link targets stay relative because nothing executes them.
- Shell scripts: `${SCRIPT_DIR}/` plus the relative climb, which is
  cwd-independent by construction.
- Agent prompts (no base directory): the same `{{package-root}}` token,
  resolved against the rendered tree at setup.

References to runtime state that is not a package asset (session-data/,
sessions/, settings/, ...) keep their user-global paths, and
files in VERBATIM_SKILL_FILES stay byte-identical because they describe every
deployment target literally.

Commands are registered as `ycc:<skill>` (never bare) so the package cannot
shadow a host built-in (`/init`) or a user's own `/<skill>`; Markdown hints
follow the same namespace.

Spike YAN-1125 (opencode v2.0.29) fixes the API shapes; the floor is v2.0.30,
the runtime the package is exercised on. See the adapter template for the exact
contract and the coexistence semantics with the primary file-copy install.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from opencode_sensitive_policy import GUARD_DIRNAME, guard_payloads  # noqa: E402
from package_model import Package, PackageModel, RuntimePackage, load_package_model  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOT = Path("packages/opencode")
SOURCE_PLUGIN_PATH = Path("ycc/.claude-plugin/plugin.json")
SOURCE_MCP_PATH = Path("mcp-configs/mcp.json")
SOURCE_LICENSE_PATH = Path("LICENSE")
TEMPLATE_PATH = Path(__file__).resolve().parent / "opencode_templates" / "package-index.js"

# The base API was proven on v2.0.29 (YAN-1125). Full package command execution
# and shared-asset traversal are exercised on v2.0.30, which is the engine floor.
MIN_OPENCODE_VERSION = "2.0.30"

# Every component class the model may request. The adapter registers all of
# them; a model row asking for something outside this set must fail loudly
# rather than emit a package that silently skips a component.
SUPPORTED_COMPONENTS = frozenset({"skills", "agents", "commands", "shared", "mcp", "instructions"})

# Units that ship inside the package and therefore carry the package token.
PACKAGE_UNITS = frozenset({"skills", "shared", "agents", "commands"})

# Commands registered by this package are namespaced `ycc:<skill>` so the
# package never shadows a host built-in (e.g. /init) or a user's own bare
# /<skill>. Skills and agents keep source ids; only commands gain the prefix.
COMMAND_NAMESPACE = "ycc"

# Token the adapter replaces with the package root inside agent prompts.
PACKAGE_ROOT_TOKEN = "{{package-root}}"

_HOME_UNIT_PATTERN = re.compile(r"(?:~|\$\{HOME\}|\$HOME)/\.config/opencode/([A-Za-z0-9_.-]+)/")
_PLUGIN_UNIT_PATTERN = re.compile(r"\$\{CLAUDE_PLUGIN_ROOT\}/skills/([^\s\"'`]+)")


@dataclass(frozen=True)
class Payload:
    content: bytes
    executable: bool = False


# --- model selection ---------------------------------------------------------


def opencode_runtime(package: Package) -> RuntimePackage | None:
    return next((entry for entry in package.runtimes if entry.runtime == "opencode"), None)


def package_root(package: Package) -> Path:
    # npm-unscoped directory name (release_versions.py discovers
    # packages/opencode/<unscoped-key>/package.json for this model row).
    name = package.key.rsplit("/", 1)[-1]
    if name in {"", ".", ".."} or "/" in name:
        raise ValueError(f"unsafe opencode npm package directory: {package.key}")
    return OUTPUT_ROOT / name


def npm_packages(packages: tuple[Package, ...]) -> tuple[Package, ...]:
    """Select included/npm opencode packages independently of catalog visibility."""
    selected: list[Package] = []
    for package in packages:
        runtime = opencode_runtime(package)
        if runtime is None or runtime.mechanism != "npm":
            continue
        # Unsafe names fail even when excluded/deferred so stale output cannot
        # linger silently.
        package_root(package)
        if runtime.status != "included":
            continue
        unsupported = sorted(set(runtime.components) - SUPPORTED_COMPONENTS)
        if unsupported:
            raise ValueError(f"unsupported opencode npm components for {package.key}: {unsupported}")
        selected.append(package)
    return tuple(selected)


def npm_package_roots(packages: tuple[Package, ...]) -> tuple[Path, ...]:
    """Own every modeled opencode npm root, including excluded stale output."""
    return tuple(
        package_root(package)
        for package in packages
        if (runtime := opencode_runtime(package)) is not None and runtime.mechanism == "npm"
    )


# --- small helpers -----------------------------------------------------------


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def json_payload(value: Any) -> Payload:
    return Payload((json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))


def native_version(model: PackageModel) -> str:
    source = read_json(REPO_ROOT / model.version_source)
    version = source.get("version") if isinstance(source, dict) else None
    if not isinstance(version, str) or not version.strip():
        raise ValueError(f"{model.version_source}: missing nonempty version")
    return version


_BUNDLE_UNIT_PATTERN = re.compile(r"(?<![\w./${}-])\.opencode-plugin/(skills|agents)/([A-Za-z0-9_./-]*)")


def make_package_relative(text: str, prefix: str, known: frozenset[str] = frozenset()) -> str:
    """Rewrite file-copy baked unit paths so they start at `prefix`.

    `prefix` is whatever reaches the package root for the holding file: a
    relative climb for Markdown, `${SCRIPT_DIR}/` + climb for shell, or the
    package-root token for agent prompts. Only shipped units are rewritten.
    `.opencode-plugin/{skills,agents}/...` source-tree references are rewritten
    only when the target exists in `known` (package-relative POSIX files), so
    placeholders such as `<skill-name>` and repo-only paths are never altered.
    """

    def home(match: re.Match[str]) -> str:
        unit = match.group(1)
        return f"{prefix}{unit}/" if unit in PACKAGE_UNITS else match.group(0)

    def plugin(match: re.Match[str]) -> str:
        remainder = match.group(1)
        if remainder.startswith("_shared/"):
            return f"{prefix}shared/{remainder[len('_shared/') :]}"
        return f"{prefix}skills/{remainder}"

    def bundle(match: re.Match[str]) -> str:
        unit, tail = match.group(1), match.group(2)
        # A trailing '.' or '-' is sentence punctuation, not part of the path.
        target = tail.rstrip(".-")
        suffix = tail[len(target) :]
        if unit == "skills" and (target == "_shared" or target.startswith("_shared/")):
            target = f"shared/{target[len('_shared') :]}".replace("shared//", "shared/")
        else:
            target = f"{unit}/{target}"
        bare = target.rstrip("/")
        if bare not in known and not any(item.startswith(bare + "/") for item in known):
            return match.group(0)
        return f"{prefix}{target}{suffix}"

    output = _PLUGIN_UNIT_PATTERN.sub(plugin, _HOME_UNIT_PATTERN.sub(home, text))
    # `_shared` moves out of the skills directory into the package root.
    output = re.sub(r"(?:\.\./)+_shared/", lambda _: prefix + "shared/", output)
    output = _BUNDLE_UNIT_PATTERN.sub(bundle, output) if known else output
    return output


def climb(rel: Path) -> str:
    """`../` segments from a package-relative file up to the package root."""
    return "../" * (len(rel.parts) - 1)


def asset_prefix(rel: Path) -> str:
    """Anchor that makes a reference inside `rel` resolve to the package root.

    Skill/shell documents are executed or read from the session working
    directory, never from the file's own directory, so a relative anchor in
    Markdown breaks the moment a snippet is run. Markdown therefore carries the
    package-root token (expanded to an absolute rendered path at setup); shell
    scripts anchor on their own `${SCRIPT_DIR}`, which is cwd-independent.
    """
    if rel.suffix == ".sh":
        return "${SCRIPT_DIR}/" + climb(rel)
    if rel.suffix == ".md":
        return PACKAGE_ROOT_TOKEN + "/"
    return climb(rel)


_CLIMB_UNIT_PATTERN = re.compile(r"(?<![\w.$}{/-])((?:\.\./)+(?:shared|skills|agents)/[A-Za-z0-9_./-]+)")
_LINK_TARGET_TOKEN = re.compile(r"\]\(" + re.escape(PACKAGE_ROOT_TOKEN) + "/")


def finalize_markdown(text: str, rel: Path, names: frozenset[str] | None = None) -> str:
    """Keep Markdown link targets relative and namespace slash invocations.

    The model reads `/<skill>` hints from prompts; package commands are
    registered as `ycc:<skill>`, so every hint must use the registered name.
    """
    if rel.suffix != ".md":
        return text
    if rel.parts[0] != "agents":
        # Executable snippets must survive a foreign cwd, so any remaining
        # relative climb to a shipped unit becomes the package-root token;
        # link targets are restored to the climb below because nothing
        # executes them and relative links read cleaner.
        text = _CLIMB_UNIT_PATTERN.sub(
            lambda match: PACKAGE_ROOT_TOKEN + "/" + match.group(1).lstrip("./"),
            text,
        )
        text = _LINK_TARGET_TOKEN.sub(lambda _: "](" + climb(rel), text)
    return namespace_slash_commands(text, public_skill_names() if names is None else names)


def namespace_slash_commands(text: str, names: frozenset[str]) -> str:
    """Rewrite bare `/<skill>` command hints to `/ycc:<skill>`.

    Path-like uses (`a/plan`, `~/plan`, `/plan/x`, URLs) are left alone by the
    boundary lookarounds.
    """
    if not names:
        return text
    alternation = "|".join(re.escape(name) for name in sorted(names, key=len, reverse=True))
    return re.sub(
        rf"(?<![\w/.~$}}:{{>-])/({alternation})(?![\w/.-])",
        rf"/{COMMAND_NAMESPACE}:\1",
        text,
    )


# --- component payloads ------------------------------------------------------


def skills_payloads(root: Path) -> dict[Path, Payload]:
    """Stage the skills+shared tree once, then relocate it into the package."""
    import generate_opencode_skills as skills

    with tempfile.TemporaryDirectory() as tmp:
        staging = Path(tmp)
        skills.write_tree(staging, dry_run=False)
        names = public_skill_names()
        output: dict[Path, Payload] = {}
        for path in sorted(staging.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(staging)
            raw = path.read_bytes()
            if rel.as_posix() in verbatim_outputs(skills):
                content = raw
            else:
                try:
                    content = finalize_markdown(
                        make_package_relative(raw.decode("utf-8"), asset_prefix(rel)), rel, names
                    ).encode("utf-8")
                except UnicodeDecodeError:
                    content = raw
            output[root / rel] = Payload(content, bool(path.stat().st_mode & stat.S_IXUSR))
        return output


def public_skill_names() -> frozenset[str]:
    import generate_opencode_commands as commands
    from generate_opencode_common import SRC_SKILLS_DIR

    return frozenset(path.parent.name for path in commands.discover_skills(SRC_SKILLS_DIR))


def verbatim_outputs(skills: Any) -> frozenset[str]:
    """Staged paths of VERBATIM_SKILL_FILES (`_shared/` stages as `shared/`)."""
    return frozenset(
        ("shared/" + name.removeprefix("_shared/")) if name.startswith("_shared/") else f"skills/{name}"
        for name in skills.VERBATIM_SKILL_FILES
    )


def agents_payloads(root: Path) -> dict[Path, Payload]:
    """Emit agents/<id>.md with the same projection as the file-copy bundle."""
    import generate_opencode_agents as agents
    from generate_opencode_common import SRC_AGENTS_DIR, load_agent_aliases

    aliases = load_agent_aliases()
    output: dict[Path, Payload] = {}
    for src in sorted(SRC_AGENTS_DIR.glob("*.md")):
        text = make_package_relative(
            agents.transform_agent(src.stem, src.read_text(encoding="utf-8"), aliases),
            PACKAGE_ROOT_TOKEN + "/",
        )
        output[root / "agents" / src.name] = Payload(text.encode("utf-8"))
    return output


def context_payload(root: Path) -> dict[Path, Payload]:
    """Emit AGENTS.md; the adapter pushes it through the context hook."""
    import generate_opencode_plugin as plugin

    return {root / "AGENTS.md": Payload(plugin.build_agents_md().encode("utf-8"))}


def license_payload(root: Path) -> dict[Path, Payload]:
    return {root / "LICENSE": Payload((REPO_ROOT / SOURCE_LICENSE_PATH).read_bytes())}


def commands_data() -> list[dict[str, Any]]:
    """Project public skills into V2 command definitions (data, not callbacks).

    The adapter registers each entry through ctx.command and expands
    $ARGUMENTS with the invocation text, exactly like opencode's own
    configured-command plugin (packages/core/src/config/plugin/command.ts).
    A command is a prompt workflow, not an OS process.
    """
    import generate_opencode_commands as commands
    from generate_codex_common import parse_frontmatter
    from generate_opencode_common import SRC_SKILLS_DIR, load_agent_aliases, load_model_aliases

    aliases = load_agent_aliases()
    model_aliases = load_model_aliases()
    data: list[dict[str, Any]] = []
    for src in commands.discover_skills(SRC_SKILLS_DIR):
        stem = src.parent.name
        text = commands.transform_command(stem, src.read_text(encoding="utf-8"), aliases, model_aliases)
        frontmatter, body = parse_frontmatter(text)
        entry: dict[str, Any] = {
            "name": f"{COMMAND_NAMESPACE}:{stem}",
            "description": namespace_slash_commands(
                str(frontmatter.get("description") or f"{stem} command"), public_skill_names()
            ),
            "template": namespace_slash_commands(body.strip(), public_skill_names()),
        }
        if isinstance(frontmatter.get("agent"), str) and frontmatter["agent"].strip():
            entry["agent"] = frontmatter["agent"].strip()
        model = frontmatter.get("model")
        if isinstance(model, str) and "/" in model:
            entry["model"] = model
        data.append(entry)
    return data


def mcp_data() -> dict[str, Any]:
    """Translate mcp-configs/mcp.json into V2 server definitions (plain data).

    `{env:VAR}` placeholders stay in the data; the adapter resolves them from
    process.env at setup time, so no credential is ever stored or required at
    generation time.
    """
    from generate_opencode_common import translate_mcp_servers

    payload = read_json(REPO_ROOT / SOURCE_MCP_PATH)
    servers = payload.get("mcpServers") if isinstance(payload, dict) else None
    if not isinstance(servers, dict):
        raise ValueError(f"{SOURCE_MCP_PATH}: missing mcpServers object")
    translated = translate_mcp_servers(servers)
    for name, entry in translated.items():
        nodes = [entry]
        while nodes:
            node = nodes.pop()
            if isinstance(node, str) and re.search(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}", node):
                raise ValueError(f"{SOURCE_MCP_PATH}: server {name!r} kept an untranslated ${{VAR}} placeholder")
            if isinstance(node, list):
                nodes.extend(node)
            elif isinstance(node, dict):
                nodes.extend(node.values())
    return translated


# --- registration + manifest -------------------------------------------------


def skill_registrations(root: Path, output: dict[Path, Payload]) -> list[dict[str, Any]]:
    """One {id, name, description, [autoinvoke], path} per public skill.

    Derived from the generated SKILL.md files so registration cannot drift from
    the shipped content; Skill.Info.content is read from that file at runtime.
    """
    from generate_codex_common import parse_frontmatter

    registrations: list[dict[str, Any]] = []
    for rel in sorted(output):
        parts = rel.relative_to(root).parts
        if len(parts) != 3 or parts[0] != "skills" or parts[2] != "SKILL.md" or parts[1].startswith("_"):
            continue
        parsed, _ = parse_frontmatter(output[rel].content.decode("utf-8"))
        description = str(parsed.get("description") or "").strip()
        if not description:
            raise ValueError(f"{rel}: missing skill description")
        entry: dict[str, Any] = {
            "id": parts[1],
            "name": str(parsed.get("name") or parts[1]),
            "description": description,
            "path": "/".join(parts),
        }
        metadata = parsed.get("metadata")
        if isinstance(metadata, dict) and metadata.get("opencode/autoinvoke") == "false":
            entry["autoinvoke"] = False
        registrations.append(entry)
    return registrations


def agent_registrations(root: Path, output: dict[Path, Payload]) -> tuple[list[dict[str, Any]], dict[str, str]]:
    """One {id, name, description, mode, prompt, model, ...} per source agent.

    The prompt body stays in agents/<id>.md; the adapter sets it as the agent's
    system prompt. Models come from the same models.json source as the
    file-copy opencode.json. Built-in agents (general, explore) return as
    model defaults only: the package never rewrites their system prompts.
    """
    import generate_opencode_plugin as plugin
    from generate_codex_common import parse_frontmatter

    pins = plugin.validate_agent_models(plugin.load_model_settings()["agents"])
    registrations: list[dict[str, Any]] = []
    for rel in sorted(output):
        parts = rel.relative_to(root).parts
        if len(parts) != 2 or parts[0] != "agents":
            continue
        stem = Path(parts[1]).stem
        frontmatter, _ = parse_frontmatter(output[rel].content.decode("utf-8"))
        entry: dict[str, Any] = {
            "id": stem,
            "name": stem,
            "description": str(frontmatter.get("description") or f"{stem} agent"),
            "mode": str(frontmatter.get("mode") or "subagent"),
            "prompt": "/".join(parts),
            "model": pins[stem],
        }
        for field in ("permissions", "color", "steps", "hidden", "request"):
            if field in frontmatter:
                entry[field] = frontmatter[field]
        registrations.append(entry)
    sources = {entry["id"] for entry in registrations}
    return registrations, {agent_id: pins[agent_id] for agent_id in sorted(pins) if agent_id not in sources}


def registration_data(package: Package, root: Path, output: dict[Path, Payload]) -> dict[str, Any]:
    runtime = opencode_runtime(package)
    assert runtime is not None
    components = frozenset(runtime.components)

    registration: dict[str, Any] = {
        "assets": sorted(
            {path.relative_to(root).parts[0] for path in output if root in path.parents}
            & {"skills", "shared", "agents"}
        )
    }
    if "skills" in components:
        registration["skills"] = skill_registrations(root, output)
    if "agents" in components:
        registration["agents"], registration["agentModels"] = agent_registrations(root, output)
    if "commands" in components:
        registration["commands"] = commands_data()
    if "mcp" in components:
        registration["mcp"] = mcp_data()
    if "instructions" in components:
        registration["context"] = "AGENTS.md"
    return registration


def package_manifest(package: Package, model: PackageModel) -> dict[str, Any]:
    source = read_json(REPO_ROOT / SOURCE_PLUGIN_PATH)
    author = source.get("author") if isinstance(source, dict) else None
    if not isinstance(author, dict) or not isinstance(author.get("name"), str) or not author["name"].strip():
        raise ValueError(f"{SOURCE_PLUGIN_PATH}: missing author name")
    runtime = opencode_runtime(package)
    assert runtime is not None
    components = frozenset(runtime.components)
    # The adapter always imports the sensitive-file guard from its own directory.
    files = ["index.js", "registration.json", f"{GUARD_DIRNAME}/"]
    if components & {"skills", "shared"}:
        files.extend(["skills/", "shared/"])
    if "agents" in components:
        files.append("agents/")
    if "instructions" in components:
        files.append("AGENTS.md")
    files.append("README.md")
    manifest: dict[str, Any] = {
        "name": package.key,
        "version": native_version(model),
        "description": (
            "Experimental opt-in OpenCode V2 plugin registering the ycc bundle (skills, agents, "
            "commands, MCP servers, and session instructions) through its setup hook. The "
            "file-copy install remains the primary path."
        ),
        "type": "module",
        "main": "./index.js",
        "exports": {".": "./index.js"},
        "files": files,
        "keywords": ["opencode-plugin", "opencode", "experimental", "ycc"],
        "author": {"name": author["name"]},
        "license": "MIT",
        "engines": {"opencode": f">={MIN_OPENCODE_VERSION}"},
        "repository": {
            "type": "git",
            "url": "git+https://github.com/yandy-r/ystack.git",
            "directory": package_root(package).as_posix(),
        },
    }
    if runtime.requires:
        manifest["dependencies"] = {name: native_version(model) for name in runtime.requires}
    return manifest


def readme_payload(package: Package, model: PackageModel) -> Payload:
    text = f"""# {package.key}

Experimental, opt-in [OpenCode](https://opencode.ai) V2 plugin carrying the ycc bundle
(version {native_version(model)}). It is unlisted and never the default install: the
`install.sh --target opencode` file copy remains the primary path.

Requires OpenCode `>={MIN_OPENCODE_VERSION}` (V2 plugin API; V1 hook plugins are not supported).

## Enable

Add the package to the V2 `plugins` array in your own `opencode.json`, pinned to an exact release:

```json
{{ "plugins": ["{package.key}@{native_version(model)}"] }}
```

Pin the version instead of using the bare name. Right after a release, the registry can briefly serve
stale `latest` metadata, and early placeholder versions of this package (`0.0.0-*`) were never
loadable plugins. Bump the pin when you upgrade.

A local checkout loads with a directory entry (`"file:///abs/path/to/{package_root(package).as_posix()}"`),
not the `index.js` file.

## What it registers

`setup()` awaits one registration per component class, all from package-local assets:

- **Skills** (`skills/<id>/SKILL.md`): at setup the Markdown, scripts, and shared helpers are copied to a
  temporary rendered tree whose absolute root replaces `{{{{package-root}}}}` in shell snippets, so a snippet
  runs from any working directory; the tree is removed when the plugin unloads.
- **Agents** (`agents/<id>.md` prompts, permissions, color, model pins from `ycc/settings/models.json`).
- **Commands**: each public skill becomes `/ycc:<id>`; `$ARGUMENTS` is expanded and the result is forwarded
  as a prompt (a workflow command, not an OS process).
- **MCP servers**: plain data from `mcp-configs/mcp.json`; `{{env:VAR}}` placeholders resolve from the
  environment at setup time.
- **Instructions**: `AGENTS.md` pushed through the session `context` hook.
- **Sensitive-file guard** (`ycc-sensitive-guard/`, the same plugin the file-copy install loads): for the
  restricted specialists in its `policy.json` it checks tool calls against the sensitive-file policy,
  filters search results, and provides their only search tools (`ycc_grep`/`ycc_glob`, shown to them as
  `grep`/`glob`) after checking the caller's own permissions.
- **Restricted-agent floor**: OpenCode appends your own top-level `permissions` after a package agent's
  rules, so for the restricted specialists the package re-applies their packaged rules: a permission request
  those rules deny is denied, and a tool whose permission they deny outright is neither offered nor run. It
  never loosens or re-prompts a decision. Shell interpreters and build tools in their allowlists still run
  project code, which the guard does not bound.

## Coexistence with the file-copy install

Skills, agents, and MCP servers are registered under their source ids. OpenCode applies file-copy config
(`~/.config/opencode`) after user plugins, so a same-id file-copy skill, agent, or command replaces (agents:
field-blends over) the package definition; the package's `editor.get` skip only sees registrations loaded
before it, and MCP config servers genuinely win. Package commands are always `ycc:<skill>` and never collide
with the bare file-copy `/<skill>` commands or host built-ins such as `/init`. The context hook does not push
instructions already present in the request.
Provider and variant settings (`providers`) are user configuration and are not carried by this package.
"""
    return Payload(text.encode("utf-8"))


def adapter_payload(root: Path) -> dict[Path, Payload]:
    """Copy the maintained adapter template verbatim as the package entry."""
    return {root / "index.js": Payload(TEMPLATE_PATH.read_bytes())}


# --- output plumbing (guard, write, prune, check) ----------------------------


def guard_managed_paths(dest_root: Path, inventory: set[Path], owned_roots: tuple[Path, ...]) -> None:
    """Reject managed symlinks and file/directory conflicts before writing."""
    if dest_root.is_symlink() or (dest_root.exists() and not dest_root.is_dir()):
        raise ValueError(f"output root must be a non-symlink directory: {dest_root}")
    for rel in (*inventory, *owned_roots):
        for depth in range(1, len(rel.parts) + 1):
            prefix = Path(*rel.parts[:depth])
            path = dest_root / prefix
            if path.is_symlink():
                raise ValueError(f"managed-path symlink is not allowed: {prefix}")
            if prefix != rel and path.exists() and not path.is_dir():
                raise ValueError(f"managed parent is not a directory: {prefix}")
        if rel in inventory and (dest_root / rel).exists() and not (dest_root / rel).is_file():
            raise ValueError(f"managed output is not a regular file: {rel}")
    for rel in owned_roots:
        path = dest_root / rel
        if path.exists() and not path.is_dir():
            raise ValueError(f"managed root is not a directory: {rel}")
        if path.is_dir():
            for directory, dirs, filenames in os.walk(path, followlinks=False):
                for name in dirs + filenames:
                    candidate = Path(directory) / name
                    if candidate.is_symlink():
                        raise ValueError(f"managed-path symlink is not allowed: {candidate.relative_to(dest_root)}")


def owned_files(dest_root: Path, roots: tuple[Path, ...]) -> set[Path]:
    files: set[Path] = set()
    for rel in roots:
        root = dest_root / rel
        if root.is_file():
            files.add(rel)
        if root.is_dir():
            files.update(path.relative_to(dest_root) for path in root.rglob("*") if path.is_file())
    return files


def extra_paths(dest_root: Path, inventory: set[Path], roots: tuple[Path, ...]) -> set[Path]:
    found = owned_files(dest_root, roots) - inventory
    for rel in roots:
        root = dest_root / rel
        if root.exists() and not any(rel in path.parents for path in inventory):
            found.add(rel)
        if root.is_dir():
            for directory in root.rglob("*"):
                relative = directory.relative_to(dest_root)
                if directory.is_dir() and not any(relative in path.parents for path in inventory):
                    found.add(relative)
    return found


def prune_output(dest_root: Path, inventory: set[Path], roots: tuple[Path, ...]) -> None:
    for rel in sorted(owned_files(dest_root, roots) - inventory):
        (dest_root / rel).unlink()
    for rel in roots:
        root = dest_root / rel
        for path in sorted(root.rglob("*"), key=lambda path: len(path.parts), reverse=True) if root.is_dir() else []:
            if path.is_dir() and not any(path.iterdir()):
                path.rmdir()
        if root.is_dir() and not any(root.iterdir()) and not any(rel in path.parents for path in inventory):
            root.rmdir()


def write_payloads(dest_root: Path, output: dict[Path, Payload], roots: tuple[Path, ...], dry_run: bool) -> set[Path]:
    inventory = set(output)
    guard_managed_paths(dest_root, inventory, roots)
    if dry_run:
        for rel in sorted(output):
            print(f"Would write {rel}")
        for rel in sorted(extra_paths(dest_root, inventory, roots)):
            print(f"Would remove {rel}")
        return inventory
    for rel, payload in sorted(output.items()):
        path = dest_root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists() or path.read_bytes() != payload.content:
            path.write_bytes(payload.content)
        path.chmod(0o755 if payload.executable else 0o644)
    prune_output(dest_root, inventory, roots)
    return inventory


def check_payloads(dest_root: Path, output: dict[Path, Payload], roots: tuple[Path, ...]) -> list[str]:
    inventory = set(output)
    guard_managed_paths(dest_root, inventory, roots)
    diffs: list[str] = []
    for rel, payload in sorted(output.items()):
        path = dest_root / rel
        if not path.is_file():
            diffs.append(f"missing file: {rel}")
            continue
        if path.read_bytes() != payload.content:
            diffs.append(f"drift: {rel}")
        if bool(path.stat().st_mode & stat.S_IXUSR) != payload.executable:
            diffs.append(f"executable-bit drift: {rel}")
    diffs.extend(f"extra in output: {rel}" for rel in sorted(extra_paths(dest_root, inventory, roots)))
    return diffs


# --- build / write / check ----------------------------------------------------


# These maintainer-only source-writing artifacts describe the repository's
# generated trees, not the installed package. Other bundle-author files still
# participate in concrete asset relocation.
REPOSITORY_LAYOUT_FILES = frozenset(
    {
        "skills/bundle-author/SKILL.md",
        "skills/bundle-author/references/surface-map.md",
        "skills/bundle-author/references/when-not-to-scaffold.md",
        "skills/bundle-author/references/templates/agent-template.md",
        "skills/bundle-author/references/templates/skill-template.md",
        "skills/bundle-author/scripts/scaffold-skill.sh",
    }
)


def relocate_bundle_references(root: Path, output: dict[Path, Payload]) -> None:
    """Relocate concrete legacy bundle refs after all component paths exist."""
    import generate_opencode_skills as skills

    known = frozenset(path.relative_to(root).as_posix() for path in output if root in path.parents)
    preserved = verbatim_outputs(skills) | REPOSITORY_LAYOUT_FILES
    names = public_skill_names()
    for path in tuple(output):
        if root not in path.parents:
            continue
        rel = path.relative_to(root)
        if rel.as_posix() in preserved:
            continue
        payload = output[path]
        try:
            text = payload.content.decode("utf-8")
        except UnicodeDecodeError:
            continue
        prefix = PACKAGE_ROOT_TOKEN + "/" if rel.parts[0] == "agents" else asset_prefix(rel)
        rewritten = finalize_markdown(make_package_relative(text, prefix, known), rel, names)
        output[path] = Payload(rewritten.encode("utf-8"), payload.executable)


def build_output() -> tuple[dict[Path, Payload], tuple[Path, ...]]:
    """Resolve every source and metadata value before any destination mutation."""
    model = load_package_model()
    roots = npm_package_roots(model.packages)
    output: dict[Path, Payload] = {}
    for package in npm_packages(model.packages):
        root = package_root(package)
        runtime = opencode_runtime(package)
        assert runtime is not None
        components = frozenset(runtime.components)
        if components & {"skills", "shared"}:
            output.update(skills_payloads(root))
        if "agents" in components:
            output.update(agents_payloads(root))
        relocate_bundle_references(root, output)
        if "instructions" in components:
            output.update(context_payload(root))
        output.update(adapter_payload(root))
        output.update({root / GUARD_DIRNAME / rel: Payload(content) for rel, content in guard_payloads().items()})
        output.update(license_payload(root))
        output[root / "README.md"] = readme_payload(package, model)
        output[root / "registration.json"] = json_payload(registration_data(package, root, output))
        output[root / "package.json"] = json_payload(package_manifest(package, model))
    return output, roots


def write_all(dest_root: Path, dry_run: bool = False) -> set[Path]:
    output, roots = build_output()
    return write_payloads(dest_root, output, roots, dry_run)


def run_check(dest_root: Path | None = None) -> int:
    target = REPO_ROOT if dest_root is None else dest_root
    output, roots = build_output()
    diffs = check_payloads(target, output, roots)
    if diffs:
        print("opencode npm package drift; run ./scripts/generate-opencode-package.sh", file=sys.stderr)
        for diff in diffs:
            print(f"  {diff}", file=sys.stderr)
    return int(bool(diffs))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check", action="store_true", help="Exit 1 if generated output drifts")
    modes.add_argument("--dry-run", action="store_true", help="Print what would be written without mutation")
    args = parser.parse_args(argv)
    try:
        if args.check:
            return run_check()
        write_all(REPO_ROOT, args.dry_run)
        if not args.dry_run:
            print(f"Wrote opencode npm package under {OUTPUT_ROOT}")
        return 0
    except (OSError, ValueError, RuntimeError, SystemExit) as exc:
        print(f"generate_opencode_package: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
