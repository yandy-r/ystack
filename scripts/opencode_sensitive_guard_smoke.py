#!/usr/bin/env python3
"""Opt-in isolated-host smoke for the ycc sensitive-file guard (YAN-1026, YAN-1260, YAN-1261).

Installs the generated file-copy bundle (agents, the ycc-sensitive-guard unit, and the generated
`plugins` entry) into a disposable OpenCode V2 config root, writes a synthetic
canary into secret-bearing fixture files, and drives real tool calls through a
loopback fake provider. Every provider request body is recorded; the canary
must never appear in one for a restricted specialist, while ordinary work and
an unrestricted agent keep working. Further scenarios load the generated npm
package directory instead of the file copy, load a package copy without the
guard under host-wide allow rules (the packaged agent rules must still hold),
ask restricted npm agents before external directories despite a host-wide
allow until the user answers "always" and again once that saved approval is
removed (the package's saved-approval probe sessions must not remain), and
run the file copy with the guard absent or removed by project config
(restricted specialists must have no search tool). Run through scripts/test-opencode-sensitive-guard.sh, never
directly against a real home.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from opencode_config_hook_checks import check, snapshot
from opencode_config_hook_spike import Api, Scenario, run_env
from opencode_sensitive_policy import load_policy

GUARD_ID = "yandy-r.ycc-sensitive-guard"
PACKAGE_ID = "yandy-r.ycc-opencode"
PROBE = re.compile(r"PROBE-[a-z0-9]+-\d+")
SEARCH_TOOLS = frozenset({"grep", "glob", "ycc_grep", "ycc_glob"})
# Host-wide rules a user might set in their own opencode.json.
HOST_ALLOW = [
    {"action": action, "resource": "*", "effect": "allow"} for action in ("read", "edit", "shell", "webfetch")
]
# Restricted specialists, from the same registry the generator and guard use.
RESTRICTED_AGENTS = frozenset(load_policy().restricted_agents)
SEARCH_AGENT = "ycc-sensitive-search"


@dataclass
class Probe:
    """One forced tool call made by one agent, and what must hold afterwards."""

    label: str
    agent: str
    tool: str
    arguments: dict[str, Any]
    expect: str  # "blocked"/"clean": canary absent | "control": control token present | "visible": canary present
    # | "unavailable": no search tool is offered and the forced call fails
    must_contain: str = ""
    must_not_contain: tuple[str, ...] = ()
    # Answer every permission prompt with this decision ("reject" declines with
    # feedback so the turn continues); the prompted actions land in `asked`.
    reply: str = ""
    must_ask: str = ""
    # The probe must not be prompted for this action.
    must_not_ask: str = ""
    # When set, the model may be offered only these tool names.
    offered_within: frozenset[str] = frozenset()
    # When set, classify() must report exactly this layer.
    layer_expected: str = ""
    # Runs against the scenario's server before the probe's session starts.
    before: Callable[[Scenario], None] | None = None
    key: str = ""
    result: str = ""
    layer: str = ""
    asked: list[str] = field(default_factory=list)
    bodies: list[dict[str, Any]] = field(default_factory=list)


class Provider(threading.Thread):
    """Loopback OpenAI-compatible fake that forces one scripted tool call per probe."""

    def __init__(self) -> None:
        super().__init__(daemon=True)
        self.bodies: list[dict[str, Any]] = []
        self.probes: dict[str, Probe] = {}
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
                outer.bodies.append(body)
                messages = body.get("messages", [])
                match = PROBE.search(json.dumps(messages))
                probe = outer.probes.get(match.group(0)) if match else None
                call = None
                if probe is not None:
                    probe.bodies.append(body)
                    tool_messages = [m for m in messages if m.get("role") == "tool"]
                    if tool_messages:
                        content = tool_messages[-1].get("content")
                        probe.result = content if isinstance(content, str) else json.dumps(content)
                    elif body.get("tools"):
                        call = {
                            "id": "call_" + probe.key.rsplit("-", 1)[-1],
                            "type": "function",
                            "function": {"name": probe.tool, "arguments": json.dumps(probe.arguments)},
                        }
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                base = {"id": "guard", "object": "chat.completion.chunk", "created": 0, "model": "guard"}
                delta: dict[str, Any] = {"role": "assistant", "content": "OK"}
                finish = "stop"
                if call:
                    delta = {"role": "assistant", "tool_calls": [{"index": 0, **call}]}
                    finish = "tool_calls"
                first = {**base, "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
                last = {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}
                self.wfile.write(("data: " + json.dumps(first) + "\n\n").encode())
                self.wfile.write(("data: " + json.dumps(last) + "\n\ndata: [DONE]\n\n").encode())

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


def base_config(provider: Provider, plugins: list[str]) -> dict[str, Any]:
    """Fake-provider config with the given V2 `plugins` list."""
    return {
        "plugins": plugins,
        "model": "fake/probe",
        "providers": {
            "fake": {
                "package": "@ai-sdk/openai-compatible",
                "settings": {"baseURL": provider.url + "/v1", "apiKey": "dummy-guard-key"},
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


def write_fixtures(lab: Path, work: Path, canary: str, control: str) -> None:
    """Synthetic project: canary in secret-bearing files, control token in source."""
    (work / "src").mkdir()
    (work / "src" / "app.ts").write_text(f"export const marker = '{control}';\n", encoding="utf-8")
    (work / ".env").write_text(f"API_TOKEN={canary}\n", encoding="utf-8")
    (work / "config").mkdir()
    (work / "config" / ".env.production").write_text(f"API_TOKEN={canary}\n", encoding="utf-8")
    (work / ".env.example").write_text(f"API_TOKEN=example-{control}\n", encoding="utf-8")
    (work / "notes.txt").symlink_to(".env")
    # Not gitignored, so a directory-wide search reaches it unless filtered.
    (work / "keys").mkdir()
    (work / "keys" / "server.pem").write_text(f"-----BEGIN KEY {canary}-----\n", encoding="utf-8")
    (work / ".gitignore").write_text("config/.env.production\n.env\n", encoding="utf-8")
    env = run_env(lab)
    subprocess.run(["git", "init", "-q", str(work)], env=env, check=True, timeout=30)


def install_file_copy(repo: Path, root: Path) -> None:
    """Mirror the bundle units install.sh ships plus the generated plugins entry."""
    bundle = repo / ".opencode-plugin"
    # No skills/ or shared/: the guard must work under --skills-home agents too.
    for unit in ("agents", "ycc-sensitive-guard"):
        shutil.copytree(bundle / unit, root / unit, symlinks=True)


def wait_ready(sc: Scenario, plugin_id: str | None, agents: tuple[str, ...]) -> None:
    """Wait until the guard-bearing plugin (if any) is active and the probe agents exist."""
    deadline = time.monotonic() + 60
    states: dict[str, str] = {}
    while time.monotonic() < deadline:
        if sc.process.poll() is not None:
            raise SystemExit(f"FAIL {sc.name} server exited")
        try:
            states = {p["id"]: p["state"]["status"] for p in sc.api.items("plugin") if p["source"]["type"] != "builtin"}
            ids = {a["id"] for a in sc.api.items("agent")}
        except (OSError, TimeoutError):
            states, ids = {}, set()
        except SystemExit as error:
            # The server answers 503 service_starting until boot finishes.
            if "service_starting" not in str(error):
                raise
            states, ids = {}, set()
        if (plugin_id is None or states.get(plugin_id) == "active") and ids and set(agents) <= ids:
            return
        if plugin_id is not None and states.get(plugin_id) == "failed":
            raise SystemExit(f"FAIL {sc.name}: plugin {plugin_id} failed: {states}")
        time.sleep(0.25)
    raise SystemExit(f"FAIL {sc.name}: not ready; plugins={states}")


def run_probe(sc: Scenario, provider: Provider, probe: Probe, index: int, session_dir: Path) -> None:
    """Create a session as the probe's agent, force its tool call, wait for the result."""
    if probe.before is not None:
        probe.before(sc)
    probe.key = f"PROBE-{sc.name.replace('-', '')}-{index}"
    provider.probes[probe.key] = probe
    body = {
        "title": probe.label,
        "agent": probe.agent,
        "location": {"directory": str(session_dir)},
        "model": {"providerID": "fake", "id": "probe"},
    }
    sid = sc.api.request("/api/session", body)["data"]["id"]
    sc.api.request(f"/api/session/{sid}/prompt", {"text": f"{probe.key}: run the scripted tool call."})
    deadline = time.monotonic() + 45
    while not probe.result and time.monotonic() < deadline:
        if probe.reply:
            for request in sc.api.request(f"/api/session/{sid}/permission")["data"]:
                probe.asked.append(request["action"])
                decision = {"decision": probe.reply}
                if probe.reply == "reject":
                    decision["message"] = "declined by the smoke"
                sc.api.request(f"/api/session/{sid}/permission/{request['id']}/reply", decision)
        time.sleep(0.2)
    if not probe.result:
        raise SystemExit(f"FAIL {probe.label}: no tool result reached the provider (agent {probe.agent})")
    # Let the final reply request land so every body of this turn is recorded.
    time.sleep(0.5)


def offered_tools(probe: Probe) -> set[str]:
    """Tool names the model was offered in the probe's first request."""
    return {tool.get("function", {}).get("name") for body in probe.bodies[:1] for tool in body.get("tools", [])}


def classify(probe: Probe) -> str:
    text = probe.result
    if "ycc sensitive-file guard" in text:
        return "guard"
    if re.search(r"No tool named|not available", text):
        return "unavailable"
    if "ycc restricted-agent rules" in text:
        return "floor"
    if re.search(r"denied|not allowed|rule", text, re.IGNORECASE):
        return "native-deny"
    return "filtered" if probe.tool in SEARCH_TOOLS else "allowed"


def evaluate(probes: list[Probe], canary: str, control: str) -> None:
    for probe in probes:
        probe.layer = classify(probe)
        encoded = json.dumps(probe.bodies)
        if probe.expect in {"blocked", "clean", "unavailable"}:
            check(f"{probe.label}: canary absent from every provider body", False, canary in encoded)
        if probe.expect == "blocked" and probe.tool not in SEARCH_TOOLS:
            check(f"{probe.label}: call was rejected", True, probe.layer in {"guard", "floor", "native-deny"})
        elif probe.expect == "unavailable":
            check(f"{probe.label}: no search tool offered", set(), offered_tools(probe) & SEARCH_TOOLS)
            check(f"{probe.label}: forced call failed", "unavailable", probe.layer)
        elif probe.expect == "control":
            check(f"{probe.label}: control result reached the model", True, control in probe.result)
        elif probe.expect == "visible":
            check(f"{probe.label}: unrestricted agent unaffected (canary visible)", True, canary in probe.result)
        if probe.expect != "unavailable" and probe.agent in RESTRICTED_AGENTS and probe.tool in SEARCH_TOOLS:
            # Guarded search reaches the model under the built-in names only.
            offered = offered_tools(probe) & SEARCH_TOOLS
            check(f"{probe.label}: guarded search offered as grep/glob", {"grep", "glob"}, offered)
        if probe.agent not in RESTRICTED_AGENTS and probe.bodies:
            # Other agents are never offered the guarded tools.
            guarded = offered_tools(probe) & {"ycc_grep", "ycc_glob"}
            check(f"{probe.label}: no guarded search offered to {probe.agent}", set(), guarded)
        if probe.must_ask:
            check(f"{probe.label}: prompted for {probe.must_ask}", True, probe.must_ask in probe.asked)
        if probe.must_not_ask:
            check(f"{probe.label}: not prompted for {probe.must_not_ask}", False, probe.must_not_ask in probe.asked)
        if probe.layer_expected:
            check(f"{probe.label}: decided by {probe.layer_expected}", probe.layer_expected, probe.layer)
        if probe.offered_within:
            extra = offered_tools(probe) - probe.offered_within
            check(f"{probe.label}: offered only its own tools", set(), extra)
        if probe.must_contain:
            check(f"{probe.label}: result mentions {probe.must_contain!r}", True, probe.must_contain in probe.result)
        for needle in probe.must_not_contain:
            check(f"{probe.label}: result omits {needle!r}", False, needle in probe.result)


def file_copy_probes(work: Path) -> list[Probe]:
    env_path = str(work / ".env") + "\n"
    return [
        Probe("read .env", "pr-comment-fixer", "read", {"path": ".env"}, "blocked"),
        Probe("read nested gitignored .env", "pr-comment-fixer", "read", {"path": "config/.env.production"}, "blocked"),
        Probe("read symlink to .env", "pr-comment-fixer", "read", {"path": "notes.txt"}, "blocked"),
        Probe(
            "edit .env",
            "pr-comment-fixer",
            "edit",
            {"path": ".env", "oldString": "API_TOKEN=", "newString": "API_TOKEN=x"},
            "blocked",
        ),
        Probe("grep path .env", "pr-comment-fixer", "grep", {"pattern": "API_TOKEN", "path": ".env"}, "blocked"),
        Probe(
            "grep include gitignored file",
            "pr-comment-fixer",
            "grep",
            {"pattern": "API_TOKEN", "include": ".env.production"},
            "blocked",
        ),
        Probe("grep directory-wide", "pr-comment-fixer", "grep", {"pattern": "API_TOKEN"}, "blocked"),
        Probe(
            "glob hidden",
            "pr-comment-fixer",
            "glob",
            {"pattern": "**/.env*", "hidden": True},
            "blocked",
            must_contain=".env.example",
            must_not_contain=(env_path,),
        ),
        Probe(
            "shell interpreter prints .env",
            "pr-comment-fixer",
            "shell",
            {"command": "python3 -c \"print(open('.env').read())\""},
            "blocked",
        ),
        hidden_path_probe("", "native-deny"),
        Probe("shell prints .env", "review-fixer", "shell", {"command": "cat .env"}, "blocked"),
        Probe("shell ls glob", "review-fixer", "shell", {"command": "ls .e*"}, "blocked"),
        Probe("control grep src", "pr-comment-fixer", "grep", {"pattern": "marker", "path": "src"}, "control"),
        Probe("control grep directory-wide", "pr-comment-fixer", "grep", {"pattern": "marker"}, "control"),
        Probe("control read src", "pr-comment-fixer", "read", {"path": "src/app.ts"}, "control"),
        Probe(
            "control edit src",
            "pr-comment-fixer",
            "edit",
            {"path": "src/app.ts", "oldString": "export const", "newString": "export const /* edited */"},
            "clean",
        ),
        Probe("control read .env.example", "pr-comment-fixer", "read", {"path": ".env.example"}, "control"),
        Probe("control allowed shell", "review-fixer", "shell", {"command": "ls src"}, "clean", must_contain="app.ts"),
        Probe(
            "control validation shell",
            "pr-comment-fixer",
            "shell",
            {"command": "pytest --version"},
            "clean",
            layer_expected="allowed",
        ),
        Probe(
            "unrestricted agent grep .env", "code-finder", "grep", {"pattern": "API_TOKEN", "path": ".env"}, "visible"
        ),
        Probe(
            "internal search agent cannot be a subagent",
            "build",
            "subagent",
            {"agent": "ycc-sensitive-search", "description": "probe", "prompt": "search"},
            "clean",
            must_contain="cannot run as a subagent",
        ),
        # The internal search agent only runs inside the guarded tools.
        Probe(
            "internal search agent session has no tools",
            SEARCH_AGENT,
            "grep",
            {"pattern": "API_TOKEN"},
            "clean",
            must_contain="ycc sensitive-file guard",
        ),
    ]


def external_search_probes(work: Path, canary: str) -> list[Probe]:
    """A search outside the project asks as the restricted agent, even when the
    host allows external directories; the prompt is declined here."""
    outside = work.parent / f"{work.name}-outside"
    outside.mkdir(exist_ok=True)
    (outside / "secret.txt").write_text(f"OUTSIDE {canary}\n", encoding="utf-8")
    return [
        Probe(
            "external search asks the restricted agent",
            "pr-comment-fixer",
            "grep",
            {"pattern": "OUTSIDE", "path": str(outside)},
            "clean",
            reply="reject",
            must_ask="external_directory",
        ),
        Probe(
            "external glob asks the restricted agent",
            "review-fixer",
            "glob",
            {"pattern": "*", "path": str(outside)},
            "clean",
            reply="reject",
            must_ask="external_directory",
            must_not_contain=("secret.txt",),
        ),
    ]


# Title of the child sessions the npm package creates to ask the host whether
# saved approvals cover a directory (scripts/opencode_templates/package-index.js).
SAVED_APPROVAL_PROBE_TITLE = "ycc saved-approval probe"


def remove_saved_external_approvals(sc: Scenario) -> None:
    """Remove every saved external_directory approval, as a user would in OpenCode."""
    saved = [item for item in sc.api.request("/api/permission/saved")["data"] if item["action"] == "external_directory"]
    check("saved external_directory approval present before removal", True, len(saved) > 0)
    for item in saved:
        sc.api.request(f"/api/permission/saved/{item['id']}", method="DELETE")
    left = [item for item in sc.api.request("/api/permission/saved")["data"] if item["action"] == "external_directory"]
    check("saved external_directory approvals removed", [], left)


def npm_external_allow_probes(work: Path, control: str) -> list[Probe]:
    """On npm a host-wide external-directory allow still asks a restricted
    agent; once answered "always" the same directory is not asked again, and
    once that saved approval is removed it is asked again."""
    outside = work.parent / f"{work.name}-outside"
    outside.mkdir(exist_ok=True)
    (outside / "notes.txt").write_text(f"OUTSIDE {control}\n", encoding="utf-8")
    search = {"pattern": "OUTSIDE", "path": str(outside)}
    return [
        Probe(
            "npm external allow: restricted agent asks",
            "pr-comment-fixer",
            "grep",
            search,
            "control",
            reply="always",
            must_ask="external_directory",
        ),
        # Any prompt here is declined, which would drop the control result.
        Probe(
            "npm external allow: saved approval is not asked again",
            "review-fixer",
            "grep",
            search,
            "control",
            reply="reject",
            must_not_ask="external_directory",
        ),
        Probe(
            "npm external allow: removed saved approval is asked again",
            "pr-comment-fixer",
            "grep",
            search,
            "clean",
            reply="reject",
            must_ask="external_directory",
            before=remove_saved_external_approvals,
        ),
        Probe(
            "npm external allow: unrestricted agent keeps the host allow",
            "code-finder",
            "grep",
            {"pattern": "OUTSIDE", "path": str(outside)},
            "control",
            reply="reject",
            must_not_ask="external_directory",
        ),
    ]


# An interpreter one-liner whose secret path (keys/server.pem) is only built at
# runtime, so the guard's command-text check cannot see it.
HIDDEN_PATH_ONE_LINER = (
    "python3 -c \"import base64;print(open(base64.b64decode('a2V5cy9zZXJ2ZXIucGVt').decode()).read())\""
)


def hidden_path_probe(prefix: str, layer: str = "") -> Probe:
    """Fixer specialists may not run interpreters, so native rules deny the call."""
    return Probe(
        f"{prefix}shell interpreter builds secret path",
        "pr-comment-fixer",
        "shell",
        {"command": HIDDEN_PATH_ONE_LINER},
        "blocked",
        layer_expected=layer,
    )


# Tools a restricted specialist's packaged rules allow, as the model sees them.
PACKAGED_TOOLS = frozenset({"read", "edit", "write", "patch", "shell", "grep", "glob"})


def host_wildcard_probes() -> list[Probe]:
    """A host-wide `* * allow` offers and runs nothing beyond the packaged tools."""
    return [
        Probe(
            "npm wildcard: control read src",
            "pr-comment-fixer",
            "read",
            {"path": "src/app.ts"},
            "control",
            offered_within=PACKAGED_TOOLS,
        ),
        Probe(
            "npm wildcard: webfetch outside allowlist",
            "pr-comment-fixer",
            "webfetch",
            {"url": "http://127.0.0.1:9/"},
            "blocked",
            offered_within=PACKAGED_TOOLS,
        ),
        Probe(
            "npm wildcard: question outside allowlist",
            "review-fixer",
            "question",
            {"questions": [{"question": "q?", "header": "h", "options": [{"label": "a", "description": "a"}]}]},
            "blocked",
        ),
        Probe(
            "npm wildcard: subagent outside allowlist",
            "pr-comment-fixer",
            "subagent",
            {"agent": "code-finder", "description": "probe", "prompt": "x"},
            "blocked",
        ),
        Probe("npm wildcard: read .env", "pr-comment-fixer", "read", {"path": ".env"}, "blocked"),
        Probe("npm wildcard: unrestricted agent read .env", "code-finder", "read", {"path": ".env"}, "visible"),
    ]


def npm_probes() -> list[Probe]:
    return [
        Probe("npm: grep path .env", "pr-comment-fixer", "grep", {"pattern": "API_TOKEN", "path": ".env"}, "blocked"),
        Probe("npm: grep directory-wide", "pr-comment-fixer", "grep", {"pattern": "API_TOKEN"}, "blocked"),
        Probe("npm: read symlink to .env", "pr-comment-fixer", "read", {"path": "notes.txt"}, "blocked"),
        Probe("npm: control grep src", "pr-comment-fixer", "grep", {"pattern": "marker", "path": "src"}, "control"),
    ]


def host_allow_probes(prefix: str) -> list[Probe]:
    """Host-wide allow rules must not loosen a restricted specialist's own rules."""
    return [
        Probe(f"{prefix}: read .env", "pr-comment-fixer", "read", {"path": ".env"}, "blocked"),
        Probe(f"{prefix}: read nested .env", "pr-comment-fixer", "read", {"path": "config/.env.production"}, "blocked"),
        Probe(f"{prefix}: read key file", "pr-comment-fixer", "read", {"path": "keys/server.pem"}, "blocked"),
        Probe(
            f"{prefix}: edit .env",
            "pr-comment-fixer",
            "edit",
            {"path": ".env", "oldString": "API_TOKEN=", "newString": "API_TOKEN=x"},
            "blocked",
        ),
        Probe(f"{prefix}: shell outside allowlist", "review-fixer", "shell", {"command": "cat .env"}, "blocked"),
        hidden_path_probe(f"{prefix}: "),
        Probe(
            f"{prefix}: webfetch outside allowlist",
            "pr-comment-fixer",
            "webfetch",
            {"url": "http://127.0.0.1:9/"},
            "blocked",
        ),
        Probe(f"{prefix}: control read src", "pr-comment-fixer", "read", {"path": "src/app.ts"}, "control"),
        Probe(f"{prefix}: unrestricted agent read .env", "code-finder", "read", {"path": ".env"}, "visible"),
    ]


def guard_absent_probes(prefix: str) -> list[Probe]:
    """Without the guard a restricted specialist has no search tool at all."""
    return [
        Probe(
            f"{prefix}: grep directory-wide", "pr-comment-fixer", "grep", {"pattern": "API_TOKEN|BEGIN"}, "unavailable"
        ),
        Probe(
            f"{prefix}: grep key dir", "pr-comment-fixer", "grep", {"pattern": "BEGIN", "path": "keys"}, "unavailable"
        ),
        Probe(f"{prefix}: glob key files", "review-fixer", "glob", {"pattern": "**/*.pem"}, "unavailable"),
        Probe(f"{prefix}: guarded grep name", "pr-comment-fixer", "ycc_grep", {"pattern": "API_TOKEN"}, "unavailable"),
        Probe(f"{prefix}: guarded glob name", "pr-comment-fixer", "ycc_glob", {"pattern": "**/*"}, "unavailable"),
        Probe(f"{prefix}: native read .env", "pr-comment-fixer", "read", {"path": ".env"}, "blocked"),
        hidden_path_probe(f"{prefix}: ", "native-deny"),
        Probe(f"{prefix}: control read src", "pr-comment-fixer", "read", {"path": "src/app.ts"}, "control"),
        Probe(
            f"{prefix}: unrestricted agent grep",
            "code-finder",
            "grep",
            {"pattern": "BEGIN", "path": "keys"},
            "visible",
        ),
    ]


def guard_stubbed_package(repo: Path, lab: Path) -> Path:
    """Lab copy of the generated package whose setup skips the guard plugin,
    so only the agents' own rules (and the permission floor) protect them."""
    dest = lab / "packages" / "ycc-opencode-noguard"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(repo / "packages/opencode/ycc-opencode", dest, symlinks=True)
    index = dest / "index.js"
    text = index.read_text(encoding="utf-8")
    call = "      await registerSensitiveGuard(ctx);\n"
    check("package setup registers the guard once", 1, text.count(call))
    index.write_text(text.replace(call, ""), encoding="utf-8")
    return dest


def session_location_probes(work: Path) -> list[Probe]:
    """Relative names only reach the fixtures through the session location.

    `notes.txt` is a symlink to `.env` (native rules alone allow it), and the
    directory-wide grep must be filtered against the session directory.
    """
    env_path = str(work / ".env") + "\n"
    return [
        Probe("session: read symlink to .env", "pr-comment-fixer", "read", {"path": "notes.txt"}, "blocked"),
        Probe("session: grep directory-wide", "pr-comment-fixer", "grep", {"pattern": "API_TOKEN"}, "blocked"),
        Probe(
            "session: glob hidden",
            "pr-comment-fixer",
            "glob",
            {"pattern": "**/.env*", "hidden": True},
            "blocked",
            must_contain=".env.example",
            must_not_contain=(env_path,),
        ),
        Probe("session: shell ls glob", "review-fixer", "shell", {"command": "ls .e*"}, "blocked"),
        Probe("session: control read src", "pr-comment-fixer", "read", {"path": "src/app.ts"}, "control"),
        Probe(
            "session: control edit src",
            "pr-comment-fixer",
            "edit",
            {"path": "src/app.ts", "oldString": "export const", "newString": "export const /* edited */"},
            "clean",
        ),
    ]


def scenario(
    lab: Path,
    binary: str,
    provider: Provider,
    name: str,
    config: dict[str, Any],
    plugin_id: str | None,
    probes_for: Any,
    canary: str,
    control: str,
    install: Any = None,
    separate_session: bool = False,
    project_config: dict[str, Any] | None = None,
) -> list[Probe]:
    """Run one scenario. With separate_session the server runs in an empty
    directory and every session is created in a different project directory,
    so the guard must resolve paths against the session location. A
    project_config is written as that project's opencode.json before any
    session uses it."""
    root = lab / "config/opencode"
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)
    if install:
        install(root)
    sc = Scenario(lab, binary, name, config)
    work = lab / "projects" / name if separate_session else sc.work
    work.mkdir(parents=True, exist_ok=True)
    try:
        write_fixtures(lab, work, canary, control)
        if project_config is not None:
            (work / "opencode.json").write_text(json.dumps(project_config, indent=2), encoding="utf-8")
        probes: list[Probe] = probes_for(work)
        wait_ready(sc, plugin_id, tuple(sorted({p.agent for p in probes})))
        for index, probe in enumerate(probes):
            run_probe(sc, provider, probe, index, work)
        evaluate(probes, canary, control)
        if plugin_id == PACKAGE_ID:
            sessions = sc.api.request("/api/session?" + urllib.parse.urlencode({"limit": "500"}))["data"]
            probes_left = [s["id"] for s in sessions if s.get("title") == SAVED_APPROVAL_PROBE_TITLE]
            check(f"{name}: no saved-approval probe session remains", [], probes_left)
        if probes_for in (file_copy_probes, session_location_probes):
            check(".env unchanged on disk", f"API_TOKEN={canary}\n", (work / ".env").read_text(encoding="utf-8"))
            check("control edit applied", True, "/* edited */" in (work / "src/app.ts").read_text(encoding="utf-8"))
        if project_config is not None:
            located = Api(int(sc.api.base.rsplit(":", 1)[1]), work)
            states = {p["id"]: p["state"]["status"] for p in located.items("plugin")}
            check(f"{name}: guard not active in the project", False, states.get(GUARD_ID) == "active")
        return probes
    finally:
        sc.close()


def main() -> None:
    lab, binary, real_home, repo = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4])
    before = snapshot(real_home)
    canary = "CANARY" + secrets.token_hex(10)
    control = "CONTROL" + secrets.token_hex(6)
    provider = Provider()
    provider.start()
    summary: dict[str, Any] = {}
    try:
        version = subprocess.run(
            [binary, "--version"], env=run_env(lab), text=True, capture_output=True, timeout=15, check=True
        ).stdout.strip()
        check("OpenCode V2 binary", True, version.startswith("opencode v2."))
        summary["opencode"] = version
        bundle_config = json.loads((repo / ".opencode-plugin/opencode.json").read_text(encoding="utf-8"))
        guard_entries = [p for p in bundle_config["plugins"] if isinstance(p, str) and p.startswith("./")]
        check("bundle config declares the guard plugin", ["./ycc-sensitive-guard"], guard_entries)
        results = scenario(
            lab,
            binary,
            provider,
            "file-copy",
            base_config(provider, guard_entries),
            GUARD_ID,
            file_copy_probes,
            canary,
            control,
            install=lambda root: install_file_copy(repo, root),
        )
        # The server runs in an empty directory; every session lives elsewhere.
        results += scenario(
            lab,
            binary,
            provider,
            "session-location",
            base_config(provider, guard_entries),
            GUARD_ID,
            session_location_probes,
            canary,
            control,
            install=lambda root: install_file_copy(repo, root),
            separate_session=True,
        )
        # Host-wide external-directory approval on the file copy: guarded search
        # still asks as the restricted agent, whose own `ask` comes last there.
        # The npm floor re-raises it (npm-external-allow below).
        external_allow = {"permissions": [{"action": "external_directory", "resource": "*", "effect": "allow"}]}
        results += scenario(
            lab,
            binary,
            provider,
            "file-copy-external-allow",
            base_config(provider, guard_entries) | external_allow,
            GUARD_ID,
            lambda work: external_search_probes(work, canary),
            canary,
            control,
            install=lambda root: install_file_copy(repo, root),
        )
        package = repo / "packages/opencode/ycc-opencode"
        results += scenario(
            lab,
            binary,
            provider,
            "npm-package",
            base_config(provider, [package.as_uri()]),
            PACKAGE_ID,
            lambda _work: npm_probes(),
            canary,
            control,
        )
        results += scenario(
            lab,
            binary,
            provider,
            "npm-external-allow",
            base_config(provider, [package.as_uri()]) | external_allow,
            PACKAGE_ID,
            lambda work: npm_external_allow_probes(work, control),
            canary,
            control,
        )
        # Host-wide allow rules in the user's own config: the shipped package
        # (both layers) and a lab copy without the guard (agent rules only).
        results += scenario(
            lab,
            binary,
            provider,
            "npm-package-host-allow",
            base_config(provider, [package.as_uri()]) | {"permissions": HOST_ALLOW},
            PACKAGE_ID,
            lambda _work: host_allow_probes("npm host-allow"),
            canary,
            control,
        )
        stubbed = guard_stubbed_package(repo, lab)
        results += scenario(
            lab,
            binary,
            provider,
            "npm-noguard-host-allow",
            base_config(provider, [stubbed.as_uri()]) | {"permissions": HOST_ALLOW},
            PACKAGE_ID,
            lambda _work: host_allow_probes("npm no-guard host-allow"),
            canary,
            control,
        )
        wildcard = {"permissions": [{"action": "*", "resource": "*", "effect": "allow"}]}
        results += scenario(
            lab,
            binary,
            provider,
            "npm-host-wildcard",
            base_config(provider, [package.as_uri()]) | wildcard,
            PACKAGE_ID,
            lambda _work: host_wildcard_probes(),
            canary,
            control,
        )
        # Both installs, the file-copy guard loaded first: restricted agents keep
        # their guarded search under the built-in names.
        results += scenario(
            lab,
            binary,
            provider,
            "both-installs",
            base_config(provider, [*guard_entries, package.as_uri()]),
            PACKAGE_ID,
            lambda _work: npm_probes(),
            canary,
            control,
            install=lambda root: install_file_copy(repo, root),
        )
        # File copy without the guard: not configured, or removed by a project config.
        results += scenario(
            lab,
            binary,
            provider,
            "file-copy-guard-absent",
            base_config(provider, []),
            None,
            lambda _work: guard_absent_probes("guard absent"),
            canary,
            control,
            install=lambda root: install_file_copy(repo, root),
        )
        results += scenario(
            lab,
            binary,
            provider,
            "file-copy-guard-removed",
            base_config(provider, guard_entries),
            None,
            lambda _work: guard_absent_probes("guard removed by project"),
            canary,
            control,
            install=lambda root: install_file_copy(repo, root),
            separate_session=True,
            project_config={"plugins": [f"-{GUARD_ID}"]},
        )
        restricted = [p for p in results if p.agent != "code-finder"]
        check(
            "canary absent from all restricted-agent bodies",
            True,
            all(canary not in json.dumps(p.bodies) for p in restricted),
        )
        summary["probes"] = [
            {"probe": p.label, "agent": p.agent, "tool": p.tool, "expect": p.expect, "layer": p.layer} for p in results
        ]
        summary["provider_requests"] = len(provider.bodies)
        (lab / "summary.json").write_text(json.dumps(summary, indent=2))
        print("summary: " + json.dumps(summary, indent=2))
    finally:
        provider.close()
        check("real config metadata/hash unchanged", before, snapshot(real_home))
    print("assert_sensitive_guard: all expectations verified")


if __name__ == "__main__":
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    main()
