#!/usr/bin/env python3
"""Opt-in YAN-1143 runtime smoke for the packed, relocated OpenCode npm package.

Packs the generated package, extracts it at an unrelated path, rewrites only
MCP transport data in that copy to a lab stdio stub, and drives an isolated
OpenCode V2 server (private loopback, fake provider). The generated adapter
(index.js) is executed unchanged; nothing replaces its registration code.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from opencode_config_hook_checks import check, snapshot
from opencode_config_hook_spike import Scenario

PLUGIN_ID = "yandy-r.ycc-opencode"
READ_TRIGGER = "READ-SHARED-"


class Provider(threading.Thread):
    """Loopback OpenAI-compatible fake that can force exactly one `read` tool call."""

    def __init__(self) -> None:
        super().__init__(daemon=True)
        self.bodies: list[dict[str, Any]] = []
        self.force_read: str | None = None
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
                outer.bodies.append(body)
                encoded = json.dumps(body.get("messages", []))
                call = None
                if (
                    outer.force_read
                    and READ_TRIGGER in encoded
                    and body.get("tools")
                    and not any(m.get("role") == "tool" for m in body.get("messages", []))
                ):
                    call = {
                        "id": "call_1",
                        "type": "function",
                        "function": {"name": "read", "arguments": json.dumps({"path": outer.force_read})},
                    }
                self.send_response(200)
                if body.get("stream"):
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    base = {"id": "npm", "object": "chat.completion.chunk", "created": 0, "model": "npm"}
                    delta: dict[str, object] = {"role": "assistant", "content": "OK"}
                    finish = "stop"
                    if call:
                        delta = {"role": "assistant", "tool_calls": [{"index": 0, **call}]}
                        finish = "tool_calls"
                    first = {**base, "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
                    last = {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}
                    self.wfile.write(("data: " + json.dumps(first) + "\n\n").encode())
                    self.wfile.write(("data: " + json.dumps(last) + "\n\ndata: [DONE]\n\n").encode())
                else:
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    message: dict[str, Any] = {"role": "assistant", "content": "OK"}
                    finish = "stop"
                    if call:
                        message = {"role": "assistant", "content": None, "tool_calls": [call]}
                        finish = "tool_calls"
                    payload = {
                        "id": "npm",
                        "object": "chat.completion",
                        "created": 0,
                        "model": "npm",
                        "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                    }
                    self.wfile.write(json.dumps(payload).encode())

            def log_message(self, *_args: Any) -> None:
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def run(self) -> None:
        self.server.serve_forever(poll_interval=0.1)

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.join(timeout=2)

    def wait_bodies(self, count: int, timeout: float = 40.0) -> list[dict[str, Any]]:
        """Block until `count` provider requests have been recorded."""
        deadline = time.monotonic() + timeout
        while len(self.bodies) < count and time.monotonic() < deadline:
            time.sleep(0.25)
        return list(self.bodies)


def texts(body: dict[str, Any]) -> list[str]:
    """Flatten every message content in one provider request into plain strings."""
    out: list[str] = []
    for message in body.get("messages", []):
        content = message.get("content")
        if isinstance(content, str):
            out.append(content)
        elif isinstance(content, list):
            out.extend(str(part.get("text", "")) for part in content if isinstance(part, dict))
    return out


def lab_env(lab: Path) -> dict[str, str]:
    """Minimal environment for npm/tar; no user config or registry auth."""
    user_rc = lab / "config/npm-user.npmrc"
    global_rc = lab / "config/npm-global.npmrc"
    user_rc.parent.mkdir(parents=True, exist_ok=True)
    user_rc.touch(exist_ok=True)
    global_rc.touch(exist_ok=True)
    return {
        "PATH": os.pathsep.join([*TOOL_DIRS, "/usr/local/bin:/usr/bin:/bin"]),
        "HOME": str(lab / "home"),
        "TMPDIR": str(lab / "tmp"),
        "NO_COLOR": "1",
        "npm_config_cache": str(lab / "cache/npm"),
        "npm_config_update_notifier": "false",
        "npm_config_fund": "false",
        "npm_config_audit": "false",
        # npm refuses user/global configs that resolve to the same file.
        "npm_config_userconfig": str(user_rc),
        "npm_config_globalconfig": str(global_rc),
    }


def pack_and_move(lab: Path, package_dir: Path, npm: str) -> tuple[dict[str, Any], Path]:
    """`npm pack` into the lab, then extract at a moved path with no lab-relative ties."""
    pack_dir = lab / "pack"
    pack_dir.mkdir()
    proc = subprocess.run(
        [npm, "pack", "--json", "--ignore-scripts", "--pack-destination", str(pack_dir)],
        cwd=package_dir,
        env=lab_env(lab),
        capture_output=True,
        text=True,
        timeout=180,
    )
    (lab / "npm-pack.log").write_text(proc.stdout + "\n--stderr--\n" + proc.stderr)
    if proc.returncode != 0:
        raise SystemExit(f"FAIL npm pack exited {proc.returncode}: {proc.stderr[:500]!r}")
    payload = json.loads(proc.stdout)
    # npm versions emit an array, a direct entry, or entries keyed by package spec.
    if isinstance(payload, list):
        info = payload[0]
    else:
        info = payload if "files" in payload else next(iter(payload.values()))
    tarball = pack_dir / info["filename"]
    check("npm pack tarball exists", True, tarball.is_file())
    moved = lab / "moved-site/node_modules/@yandy-r/ycc-opencode"
    moved.mkdir(parents=True)
    extract = subprocess.run(
        ["tar", "-xzf", str(tarball), "-C", str(moved), "--strip-components=1"],
        env=lab_env(lab),
        capture_output=True,
        text=True,
        timeout=60,
    )
    if extract.returncode != 0:
        raise SystemExit(f"FAIL extract: {extract.stderr[:500]!r}")
    return info, moved


def fixture_mcp_transports(moved: Path, stub: Path) -> list[str]:
    """Replace only MCP transport fields in the moved copy; registration code is untouched."""
    path = moved / "registration.json"
    registration = json.loads(path.read_text(encoding="utf-8"))
    servers = registration.get("mcp") or {}
    if isinstance(servers.get("servers"), dict):
        servers = servers["servers"]
    names = sorted(servers)
    for name in names:
        servers[name] = {"type": "local", "command": [sys.executable, str(stub)], "timeout": {"startup": 3000}}
    path.write_text(json.dumps(registration, indent=2) + "\n", encoding="utf-8")
    return names


def write_mcp_stub(lab: Path) -> Path:
    """Minimal stdio MCP initialize responder (same shape as the YAN-1125 spike)."""
    stub = lab / "fixtures/mcp-stub.py"
    stub.parent.mkdir(parents=True, exist_ok=True)
    stub.write_text(
        "import json,sys\n"
        "for line in sys.stdin:\n"
        " r=json.loads(line)\n"
        " if 'id' not in r: continue\n"
        " result={}\n"
        " if r.get('method')=='initialize':\n"
        "  result={'protocolVersion':r['params']['protocolVersion'],'capabilities':{},"
        "'serverInfo':{'name':'stub','version':'0'}}\n"
        " print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result}),flush=True)\n"
    )
    return stub


# Exact packed paths whose legacy-root literals are intentional (agreed with the generator owner):
# maintainer-only source-writing files describing the canonical repo (not package asset references).
SOURCE_WRITING_FILES: frozenset[str] = frozenset(
    {
        "skills/bundle-author/SKILL.md",
        "skills/bundle-author/references/surface-map.md",
        "skills/bundle-author/references/when-not-to-scaffold.md",
        "skills/bundle-author/references/templates/agent-template.md",
        "skills/bundle-author/references/templates/skill-template.md",
        "skills/bundle-author/scripts/scaffold-skill.sh",
    }
)


def verbatim_packed_paths() -> frozenset[str]:
    """Packed paths of the generator's VERBATIM_SKILL_FILES (`_shared/` stages as `shared/`)."""
    from generate_opencode_common import VERBATIM_SKILL_FILES  # PYTHONPATH is the scripts dir

    return frozenset(
        ("shared/" + name.removeprefix("_shared/")) if name.startswith("_shared/") else f"skills/{name}"
        for name in VERBATIM_SKILL_FILES
    )


def audit_package_paths(moved: Path, registration: dict[str, Any], lab: Path) -> None:
    """Reject legacy roots for shipped units; allow user runtime-state paths and exact descriptive files.

    Exclusions (VERBATIM_SKILL_FILES outputs and SOURCE_WRITING_FILES) are recorded, never silent.
    """
    legacy_unit = re.compile(
        r"(?:~/\.config/opencode|\$\{HOME\}/\.config/opencode|\$HOME/\.config/opencode|"
        r"/home/[^/\s]+/\.config/opencode|\$\{CLAUDE_PLUGIN_ROOT\}|"
        r"\$CLAUDE_PLUGIN_ROOT|\.opencode-plugin)/"
        r"(?:skills|shared|agents|commands|AGENTS\.md)(?=$|[/\s\"'`),:#}])"
        r"[^\s\"'`),#}]*"
    )
    allowed = verbatim_packed_paths() | SOURCE_WRITING_FILES
    failures: list[str] = []
    excluded: dict[str, int] = {}

    def inspect(value: Any, location: str, allowed_file: bool = False) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                inspect(child, f"{location}.{key}")
        elif isinstance(value, list):
            for index, child in enumerate(value):
                inspect(child, f"{location}[{index}]")
        elif isinstance(value, str):
            for number, line in enumerate(value.splitlines(), 1):
                for match in legacy_unit.finditer(line):
                    if allowed_file:
                        excluded[location] = excluded.get(location, 0) + 1
                    else:
                        failures.append(f"{location}:{number}: {match.group()}")

    inspect(registration, "registration.json")
    for file in sorted(moved.rglob("*")):
        if not file.is_file() or file.name == "registration.json":
            continue
        try:
            content = file.read_text(encoding="utf-8")
        except UnicodeError:
            continue
        rel = file.relative_to(moved).as_posix()
        inspect(content, rel, rel in allowed)
    (lab / "path-audit-exclusions.json").write_text(json.dumps(excluded, indent=2, sort_keys=True))
    print(f"observed: path audit exclusions {json.dumps(excluded, sort_keys=True)}")
    check("shipped units have no legacy install-root references", [], failures)


def shared_script_reference(moved: Path, skills: list[dict[str, Any]]) -> tuple[dict[str, Any], str, Path]:
    """Find a packed skill script that sources a relative sibling shared/ helper (grounded contract).

    NpmGenerator final: skills/git-workflow/scripts/create-pr.sh sources
    SCRIPT_DIR/../../../shared/scripts/lib/forge.sh. The model read proves
    relative sibling consumption from the moved package; generated adapter
    code and registration.json are NOT rewritten, only MCP transports.
    """
    problems: list[str] = []
    found: tuple[dict[str, Any], str, Path] | None = None
    for skill in skills:
        skill_dir = moved / Path(skill["path"]).parent
        for script in sorted(skill_dir.rglob("*.sh")):
            text = script.read_text(encoding="utf-8")
            for href in sorted(set(re.findall(r"(?:\.\./)+shared/[\w./-]+\.sh", text))):
                target = (script.parent / href).resolve()
                if not target.is_relative_to(moved.resolve()) or not target.is_file():
                    problems.append(f"{script.relative_to(moved)}: {href} escapes moved package")
                elif found is None and target.stat().st_size > 0:
                    found = (skill, href, target)
    check("packed skill scripts source relocatable shared helpers", [], problems)
    if found is None:
        raise SystemExit("FAIL no packed skill script sources a sibling shared/ helper")
    return found


def session(sc: Scenario, title: str, permissions: bool = False) -> str:
    """Create a fresh session using the fake provider."""
    body: dict[str, Any] = {
        "title": title,
        "location": {"directory": str(sc.work)},
        "model": {"providerID": "fake", "id": "probe"},
    }
    if permissions:
        # v2.0.30 schema/src/permission.ts: Ruleset = Array({action, resource, effect}).
        # core/src/file-access.ts authorizeRead asserts external_directory then read.
        body["permissions"] = [
            {"action": "read", "resource": "*", "effect": "allow"},
            {"action": "shell", "resource": "*", "effect": "allow"},
            {"action": "external_directory", "resource": "*", "effect": "allow"},
        ]
    return str(sc.api.request("/api/session", body)["data"]["id"])


def config(moved: Path, provider: Provider, extra_plugins: list[str] | None = None) -> dict[str, Any]:
    """OpenCode config: relocated package directory as plural `plugins` entry."""
    return {
        "plugins": [moved.as_uri(), *(extra_plugins or [])],
        "model": "fake/probe",
        "providers": {
            "fake": {
                "package": "@ai-sdk/openai-compatible",
                "settings": {"baseURL": provider.url + "/v1", "apiKey": "dummy-npm-key"},
                "models": {
                    "probe": {
                        "name": "Probe",
                        "limit": {"context": 32000, "output": 512},
                        "capabilities": {"tools": True, "input": ["text"], "output": ["text"]},
                    }
                },
            }
        },
    }


def wait_ready(
    sc: Scenario, command_name: str, plugin_ids: tuple[str, ...] = (PLUGIN_ID,)
) -> dict[str, list[dict[str, Any]]]:
    """Wait for the package command AND every named plugin to leave its loading state.

    Command presence is not plugin readiness: file-copy commands share names, and V2 publishes plugin
    inventory entries after setup resolves. Timeouts list the observed plugin states and the server log tail.
    """
    deadline = time.monotonic() + 40
    plugins: dict[str, str] = {}
    commands = False
    while time.monotonic() < deadline:
        if sc.process.poll() is not None:
            raise SystemExit(f"FAIL {sc.name} server exited")
        try:
            commands = any(c.get("name") == command_name for c in sc.api.items("command"))
            plugins = {
                p["id"]: p["state"]["status"] for p in sc.api.items("plugin") if p["source"]["type"] != "builtin"
            }
            if commands and all(plugins.get(pid) in ("active", "failed") for pid in plugin_ids):
                return sc.capture()
        except (OSError, TimeoutError):
            pass
        time.sleep(0.25)
    log = sc.lab / f"server-{sc.name}.log"
    tail = "\n".join(log.read_text(errors="replace").splitlines()[-15:]) if log.exists() else "(no server log)"
    raise SystemExit(
        f"FAIL {sc.name}: not ready after 40s; command {command_name!r} registered={commands}; "
        f"expected plugins {list(plugin_ids)}, observed {plugins}\n--- server log tail ---\n{tail}"
    )


def relocated(
    lab: Path, binary: str, moved: Path, reg: dict[str, Any], provider: Provider, marker: str
) -> dict[str, Any]:
    """Registration of all component classes, argument-carrying command, and shared-helper read."""
    command = next((c for c in reg["commands"] if "$ARGUMENTS" in c.get("template", "")), None)
    if command is None:
        raise SystemExit("FAIL no packed command template consumes $ARGUMENTS")
    baseline = Scenario(lab, binary, "baseline", {"update": "disable", "snapshots": False})
    try:
        baseline.ready()
        builtin_init = next(c["description"] for c in baseline.capture()["command"] if c["name"] == "init")
    finally:
        baseline.close()
    sc = Scenario(lab, binary, "relocated", config(moved, provider))
    try:
        data = wait_ready(sc, command["name"])
        plugins = {p["id"]: p["state"]["status"] for p in data["plugin"] if p["source"]["type"] != "builtin"}
        check("package plugin active", {PLUGIN_ID: "active"}, plugins)
        # Package commands are namespaced and cannot clobber the host built-in /init.
        for cmd in reg["commands"]:
            check(f"command {cmd['name']} is ycc-namespaced", True, cmd["name"].startswith("ycc:"))
        check(
            "package preserves host init description",
            builtin_init,
            next((c["description"] for c in data["command"] if c["name"] == "init"), "<missing>"),
        )
        for skill in reg["skills"]:
            runtime = [s for s in data["skill"] if s["id"] == skill["id"]]
            check(f"skill {skill['id']} registered once", 1, len(runtime))
            rendered_path = Path(runtime[0]["path"]).resolve()
            rendered_root = rendered_path.parents[2]
            check(f"skill {skill['id']} renders inside isolated lab", True, rendered_root.is_relative_to(lab))
            check(f"skill {skill['id']} asset suffix preserved", True, str(rendered_path).endswith("/" + skill["path"]))
            check(f"skill {skill['id']} rendered file exists", True, rendered_path.is_file())
        for agent in reg["agents"]:
            runtime = [a for a in data["agent"] if a["id"] == agent["id"]]
            check(f"agent {agent['id']} registered once", 1, len(runtime))
            check(f"agent {agent['id']} description", agent["description"], runtime[0]["description"])
            check(f"agent {agent['id']} mode", agent.get("mode", "subagent"), runtime[0]["mode"])
        for cmd in reg["commands"]:
            runtime = [c for c in data["command"] if c["name"] == cmd["name"]]
            check(f"command {cmd['name']} registered once", 1, len(runtime))
        check("namespaced ycc:init registered", True, any(c["name"] == "ycc:init" for c in data["command"]))
        check("registration assets copy units", ["agents", "shared", "skills"], reg.get("assets"))
        mcp_names = {m["name"]: m["status"]["status"] for m in data["mcp"]}
        for name in fixture_names:
            check(f"mcp {name} registered", True, name in mcp_names)

        # Commands: native execute callback with an argument string reaches the session prompt.
        args = f"{marker} alpha beta"
        sid = session(sc, "command")
        provider.bodies.clear()
        response = sc.api.request(f"/api/session/{sid}/command", {"name": command["name"], "text": args})
        check("command callback returns", None, response)
        bodies = provider.wait_bodies(1)
        expected = command["template"].replace("$ARGUMENTS", args)
        check("provider request carries expanded template", True, any(expected in t for b in bodies for t in texts(b)))
        (lab / "command-bodies.json").write_text(json.dumps(bodies, indent=2))

        # Context hook: AGENTS.md reaches the system prompt in a package-only configuration.
        agents_md = (moved / reg["context"]).read_text(encoding="utf-8")
        probe = [ln for ln in agents_md.splitlines() if len(ln.strip()) > 40][1].strip()
        check("package instructions in system request", True, any(probe in t for b in bodies for t in texts(b)))

        # Shared helper: model read of the sibling helper that a packed skill script sources via ../shared.
        skill, href, target = shared_script_reference(moved, reg["skills"])
        runtime_skill = Path(next(s["path"] for s in data["skill"] if s["id"] == skill["id"]))
        rendered_root = runtime_skill.parents[2]
        rendered_helper = (rendered_root / target.relative_to(moved)).resolve()
        want = [ln for ln in rendered_helper.read_text(encoding="utf-8").splitlines() if len(ln.strip()) > 20][
            0
        ].strip()
        provider.force_read = str(rendered_helper)
        provider.bodies.clear()
        sid = session(sc, "shared", permissions=True)
        sc.api.request(f"/api/session/{sid}/prompt", {"text": READ_TRIGGER + marker, "skills": [{"id": skill["id"]}]})
        deadline = time.monotonic() + 45
        seen: list[dict[str, Any]] = []
        while time.monotonic() < deadline:
            seen = list(provider.bodies)
            if any(m.get("role") == "tool" for b in seen for m in b.get("messages", [])):
                break
            time.sleep(0.25)
        provider.force_read = None
        (lab / "shared-bodies.json").write_text(json.dumps(seen, indent=2))
        tool_texts = [str(m.get("content")) for b in seen for m in b.get("messages", []) if m.get("role") == "tool"]
        check("read tool returned shared helper content", True, any(want in t for t in tool_texts))
        skill_dir = runtime_skill.parent
        # Markdown-embedded shell snippet: execute the adapter-rendered forge.sh source line from a
        # foreign workspace cwd via the session shell tool, then call a pure helper. The rendered
        # {{package-root}} tree is discovered from the runtime skill path (parents[2]), not hardcoded.
        forge_md = rendered_root / "shared" / "references" / "forge-detection.md"
        expected_source = f'source "{rendered_root}/shared/scripts/lib/forge.sh"'
        rendered_lines = forge_md.read_text(encoding="utf-8").splitlines()
        check("rendered forge-detection carries token expansion", True, expected_source in rendered_lines)
        sid = session(sc, "forge", permissions=True)
        shell = (
            expected_source
            + f' && forge_host_from_url "https://example.test/a/b.git" > "{sc.work / "forge-host.txt"}" 2>&1'
        )
        sc.api.request(f"/api/session/{sid}/shell", {"command": shell})
        deadline = time.monotonic() + 30
        host_file = sc.work / "forge-host.txt"
        while time.monotonic() < deadline and not host_file.exists():
            time.sleep(0.25)
        check(
            "markdown snippet ran from foreign cwd",
            "example.test",
            host_file.read_text(encoding="utf-8").strip() if host_file.exists() else "<no output>",
        )
        check(
            "skill base directory surfaced to model",
            True,
            any("Base directory for this skill: " + str(skill_dir) in t for b in seen for t in texts(b)),
        )
        return {
            "plugins": plugins,
            "counts": {k: len(reg[k]) for k in ("skills", "agents", "commands")},
            "mcp": mcp_names,
            "command": command["name"],
            "shared_read": f"{skill['id']} -> {href}",
            "forge_snippet": {"cwd": str(sc.work), "root": str(rendered_root)},
        }
    finally:
        sc.close()


def coexistence(
    lab: Path, binary: str, repo: Path, moved: Path, reg: dict[str, Any], provider: Provider
) -> dict[str, Any]:
    """File-copy install beside the package: post-group config replays over plugin state.

    Verified runtime semantics (opencode v2.0.30, PackageReview finding 3): Config* plugins run in
    the `post` group, replaying AFTER the package on every state rebuild, so unqualified file-copy
    commands/agents overwrite package entries with the same name; package commands are namespaced
    `ycc:<name>` and therefore survive untouched. Identity is asserted, not cardinality.
    """
    bundle = repo / ".opencode-plugin"
    root = lab / "config/opencode"
    root.mkdir(parents=True, exist_ok=True)
    installed: list[Path] = []
    for entry in ("skills", "agents", "commands", "shared", "AGENTS.md"):
        source = bundle / entry
        if source.exists():
            dest = root / entry
            if source.is_dir():
                shutil.copytree(source, dest, symlinks=True)
            else:
                shutil.copy2(source, dest)
            installed.append(dest)
    # Mark the lab file-copy surface with unique identities so the winner is observable.
    marker = "filecopy-" + secrets.token_hex(6)
    marked_agent = reg["agents"][0]["id"]
    agent_file = root / "agents" / f"{marked_agent}.md"
    agent_file.write_text(
        f"---\ndescription: {marker} agent\nmode: subagent\n---\n\n{marker} agent prompt\n",
        encoding="utf-8",
    )
    unqualified = next(c["name"].removeprefix("ycc:") for c in reg["commands"] if "$ARGUMENTS" in c["template"])
    command_file = root / "commands" / f"{unqualified}.md"
    command_file.write_text(
        f"---\ndescription: {marker} command\n---\n\n{marker} file-copy executable template\n\n$ARGUMENTS\n",
        encoding="utf-8",
    )
    # File-copy install mirrors install.sh --target opencode: skills land under
    # ~/.config/opencode and are surfaced through the proven `skills` config key
    # (spike scenario config-skills-dir); nothing auto-discovers them.
    coexist_config = config(moved, provider)
    coexist_config["skills"] = [str(root / "skills")]
    namespaced = f"ycc:{unqualified}"
    agents_md = (moved / reg["context"]).read_text(encoding="utf-8")
    probe = [ln for ln in agents_md.splitlines() if len(ln.strip()) > 40][1].strip()
    sc = Scenario(lab, binary, "coexistence", coexist_config)
    try:
        data = wait_ready(sc, namespaced)
        commands = {c["name"]: c for c in data["command"]}
        # Identity, not cardinality: file-copy post-group overwrites the unqualified name.
        check(
            f"file-copy {unqualified} wins with marked description",
            marker + " command",
            commands.get(unqualified, {}).get("description"),
        )
        check(f"namespaced package {namespaced} survives", True, namespaced in commands)
        check(
            "namespaced description differs from file-copy",
            True,
            commands[namespaced].get("description") != marker + " command",
        )
        agents = {a["id"]: a for a in data["agent"]}
        check(
            f"file-copy agent {marked_agent} wins with marked description",
            marker + " agent",
            agents.get(marked_agent, {}).get("description"),
        )
        check(
            "file-copy marked agent prompt survives post-group replay",
            True,
            marker + " agent prompt" in json.dumps(agents.get(marked_agent, {})),
        )
        provider.bodies.clear()
        sid = session(sc, "filecopy-command")
        args = marker + " executable arguments"
        sc.api.request(f"/api/session/{sid}/command", {"name": unqualified, "text": args})
        command_bodies = provider.wait_bodies(1)
        check(
            "unqualified file-copy callback executes marked template with arguments",
            True,
            any(marker + " file-copy executable template" in t and args in t for b in command_bodies for t in texts(b)),
        )
        (lab / "filecopy-command-bodies.json").write_text(json.dumps(command_bodies, indent=2))
        check(
            "package plugin still active",
            "active",
            next((p["state"]["status"] for p in data["plugin"] if p["id"] == PLUGIN_ID), "<not listed>"),
        )
        # Skills: file-copy config `set` wins over the package skill of the same id.
        origins = {
            s["id"]: s["path"]
            for s in data["skill"]
            if s["id"] in {k["id"] for k in reg["skills"]} and s["path"].startswith(str(root))
        }
        check("file-copy skill registration wins (config dir origin)", True, bool(origins))
        provider.bodies.clear()
        sid = session(sc, "coexist")
        sc.api.request(f"/api/session/{sid}/prompt", {"text": "Reply OK only."})
        bodies = provider.wait_bodies(1)
        (lab / "coexistence-bodies.json").write_text(json.dumps(bodies, indent=2))
        per_request = [sum(t.count(probe) for t in texts(b)) for b in bodies]
        check("instruction text present in at least one request", True, any(per_request))
        check("instruction text never duplicated within a request", True, all(n <= 1 for n in per_request))
        return {
            "installed": [str(p.relative_to(lab)) for p in installed],
            "origins": origins,
            "marker": marker,
            "hits": per_request,
        }
    finally:
        sc.close()
        for path in installed:
            shutil.rmtree(path) if path.is_dir() else path.unlink()


def isolation(lab: Path, binary: str, moved: Path, reg: dict[str, Any], provider: Provider) -> dict[str, Any]:
    """A throwing unrelated plugin fails alone; the package stays active."""
    broken = lab / "fixtures/broken-plugin"
    broken.mkdir(parents=True)
    (broken / "package.json").write_text('{"type":"module","main":"index.js"}')
    (broken / "index.js").write_text(
        'export default { id: "lab.broken", async setup() { throw new Error("intentional lab failure") } };\n'
    )
    command = reg["commands"][0]
    sc = Scenario(lab, binary, "isolation", config(moved, provider, [broken.as_uri()]))
    try:
        data = wait_ready(sc, command["name"], (PLUGIN_ID, "lab.broken"))
        states = {p["id"]: p["state"] for p in data["plugin"] if p["source"]["type"] != "builtin"}
        check("broken sibling failed", "failed", states.get("lab.broken", {}).get("status"))
        check("failure names the lab error", True, "intentional lab failure" in json.dumps(states["lab.broken"]))
        check("package plugin active beside failure", "active", states[PLUGIN_ID]["status"])
        for kind, key, field in (("skill", "skills", "id"), ("agent", "agents", "id"), ("command", "commands", "name")):
            ids = {r[field] for r in data[kind]}
            missing = sorted({i[field] for i in reg[key]} - ids)
            check(f"all packed {key} still registered", [], missing)
        return {"states": {k: v["status"] for k, v in states.items()}}
    finally:
        sc.close()


fixture_names: list[str] = []
TOOL_DIRS: list[str] = []


def main() -> None:
    """Run the pack, relocate, register, execute, coexist, and isolate matrix."""
    global fixture_names
    lab, binary, real_home = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    package_dir, npm, repo, node_bin = Path(sys.argv[4]), sys.argv[5], Path(sys.argv[6]), sys.argv[7]
    # Keep version-managed node/npm (mise/pnpm/nvm) on the scrubbed lab PATH
    # without user configs: only the two resolved tool directories are prepended.
    seen: set[str] = set()
    for tool in (npm, node_bin):
        directory = os.path.dirname(os.path.realpath(tool))
        if directory and directory not in seen and Path(directory).is_dir():
            TOOL_DIRS.append(directory)
            seen.add(directory)
    before = snapshot(real_home)
    marker = "yan1143-" + secrets.token_hex(6)
    print(f"marker={marker}")
    results: dict[str, Any] = {"marker": marker}
    provider = Provider()
    provider.start()
    try:
        version = subprocess.run(
            [binary, "--version"],
            env={"PATH": "/usr/bin:/bin", "HOME": str(lab / "home")},
            text=True,
            capture_output=True,
            timeout=15,
            check=True,
        ).stdout.strip()
        results["opencode"] = version
        # v2.0.30 is the observed binary; v2.0.29 is not exercised by this harness.
        parsed = re.fullmatch(r"opencode v(2)\.(\d+)\.(\d+)", version)
        check(
            "OpenCode V2 >=2.0.30 binary",
            True,
            parsed is not None and tuple(int(n) for n in parsed.groups()) >= (2, 0, 30),
        )
        info, moved = pack_and_move(lab, package_dir, npm)
        packed = {f["path"] for f in info["files"]}
        for required in ("package.json", "index.js", "registration.json", "AGENTS.md"):
            check(f"tarball contains {required}", True, required in packed)
        check(
            "tarball is self-contained skills+shared",
            True,
            any(p.startswith("skills/") for p in packed) and any(p.startswith("shared/") for p in packed),
        )
        manifest = json.loads((moved / "package.json").read_text(encoding="utf-8"))
        check("engines floor matches exercised runtime", ">=2.0.30", manifest["engines"]["opencode"])
        reg = json.loads((moved / "registration.json").read_text(encoding="utf-8"))
        audit_package_paths(moved, reg, lab)
        fixture_names = fixture_mcp_transports(moved, write_mcp_stub(lab))
        results["tarball"] = {"filename": info["filename"], "files": len(packed), "version": manifest["version"]}
        results["relocated"] = relocated(lab, binary, moved, reg, provider, marker)
        results["coexistence"] = coexistence(lab, binary, repo, moved, reg, provider)
        results["isolation"] = isolation(lab, binary, moved, reg, provider)
        results["binary_sha256"] = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
        (lab / "results.json").write_text(json.dumps(results, indent=2))
        print("observed: " + json.dumps(results))
    finally:
        provider.close()
        check("real config metadata/hash unchanged", before, snapshot(real_home))
    print("assert_npm_package: all expectations verified")


if __name__ == "__main__":
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    main()
