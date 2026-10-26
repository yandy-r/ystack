#!/usr/bin/env python3
"""Scripted-model driver for scripts/test-omp-scripted-sessions.sh (opt-in live OMP harness).

A loopback OpenAI-compatible provider answers every omp request from a fixed script, so a real
omp session runs real tools (bash, write, read, task subagents, MCP) with no model and no
network. A request is matched to a script by the last `SCRIPT-<name>` marker in its user
messages; step N answers the request that already holds N assistant messages. Steps past the
end of a script, and requests with no marker, answer the text `DONE`.

  session [--rpc PROMPT --approve yes|no] OUT AGENT_DIR PACKAGE -- OMP_ARGV...
      start the provider, write AGENT_DIR/models.yml (provider ycc-scripted: main, slow,
      task; provider ycc-down: a refused 127.0.0.1:9 endpoint), run omp, record OUT JSON:
      rc, stdout/stderr tails, rpc frames, and one entry per provider request (script key,
      step, model, the tool results and rule reminders that followed the last assistant turn).
      --rpc runs omp --mode rpc, sends PROMPT and answers each `Allow tool` select.
  check-script OUT PACKAGE KEY...  every step of each KEY got the result its script expects
  check-agents OUT PACKAGE       every ycc agent ran to completion on the model its
                                 frontmatter role selects (@slow, @task, else the main model)
  check-skills OUT PACKAGE       every ycc skill read through skill:// from the installed cache,
                                 in one batch with no compaction request in between
  check-ttsr SESSION_DIR         one ycc-python-trigger and one ycc-golang-trigger
                                 ttsr_injection entry for the whole session
  check-rpc OUT [--approve yes|no] the rpc session asked one `Allow tool: bash` select, the
                                 answer took effect, and the session reached agent_end
  check-json OUT                 --mode json emitted agent_end
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

PROVIDER = "ycc-scripted"
DOWN_PROVIDER = "ycc-down"
MODELS = ("main", "slow", "task")
# Agent frontmatter role -> scripted model id (the harness maps modelRoles the same way).
ROLE_MODEL = {"@slow": "slow", "@task": "task", None: "main"}
MARKER = re.compile(r"SCRIPT-[a-z0-9-]+")
RULE = re.compile(r'<system-reminder reason="rule_violation" rule="([^"]+)"')
GUARD = "ycc scope guard: "
SIDE_EFFECT = "guard-side-effect"
PLUGIN_DIR_SIDE_EFFECT = "plugin-dir-side-effect"
PERMISSION_FILE = "permission-probe"
NAME_LINE = re.compile(r"^name:\s*(\S+)\s*$", re.MULTILINE)
MODEL_LINE = re.compile(r"^model:\s*['\"]?([^'\"\n]+)['\"]?\s*$", re.MULTILINE)
SESSION_TIMEOUT = 240
# Declared for every scripted model so a whole-package read batch never trips compaction.
CONTEXT_WINDOW = 2_000_000
MAX_TOKENS = 8192


class SmokeError(Exception):
    """A recorded omp session that contradicts the expected ycc behavior."""


@dataclass(frozen=True)
class Step:
    """One scripted assistant turn: tool calls, and the result substring each must return."""

    calls: tuple[tuple[str, dict[str, Any]], ...]
    expect: str = ""
    # Rule reminders that must (and only those that may) follow this step's results.
    reminders: tuple[str, ...] = ()


@dataclass
class Recorder:
    requests: list[dict[str, Any]] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)


def text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(str(part.get("text", "")) if isinstance(part, dict) else str(part) for part in content)
    return json.dumps(content)


def frontmatter(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        raise SmokeError(f"{path}: no frontmatter")
    return text[4 : text.index("\n---", 4)]


def agents(package: Path) -> dict[str, str]:
    """Agent name -> scripted model its frontmatter role selects."""
    found: dict[str, str] = {}
    for path in sorted((package / "agents").glob("*.md")):
        head = frontmatter(path)
        name = NAME_LINE.search(head)
        model = MODEL_LINE.search(head)
        if name is None:
            raise SmokeError(f"{path}: no name")
        role = model.group(1).strip() if model else None
        if role not in ROLE_MODEL:
            raise SmokeError(f"{path}: model {role!r} has no scripted role mapping")
        found[name.group(1)] = ROLE_MODEL[role]
    if not found:
        raise SmokeError(f"{package}/agents: no agents")
    return found


def skills(package: Path) -> dict[str, str]:
    """Skill frontmatter name -> its directory, for every SKILL.md the package ships."""
    found: dict[str, str] = {}
    for path in sorted((package / "skills").glob("*/SKILL.md")):
        name = NAME_LINE.search(frontmatter(path))
        if name is None:
            raise SmokeError(f"{path}: no name")
        found[name.group(1)] = path.parent.name
    if not found:
        raise SmokeError(f"{package}/skills: no skills")
    return found


def spawn(key: str, *tasks: tuple[str, str]) -> Step:
    """A main-session turn that runs `tasks` ((agent, script key)) as one task batch."""
    items = [
        {"agent": agent, "name": f"Probe{index}", "task": f"{sub} run", "solutionSpace": "scripted probe"}
        for index, (agent, sub) in enumerate(tasks)
    ]
    return Step((("task", {"context": f"{key} scripted probe", "tasks": items}),), 'status="completed"')


def device(tool: str) -> tuple[str, dict[str, Any]]:
    return ("write", {"path": f"xd://{tool}", "content": "{}"})


def build_scripts(package: Path) -> dict[str, list[Step]]:
    guard = GUARD
    scripts: dict[str, list[Step]] = {
        # YAN-1540: git-cleanup declares bash `git`/`gh`/`glab` and no MCP tools.
        "SCRIPT-guard-git-cleanup": [
            Step((("bash", {"command": "git --version"}),), "git version"),
            Step(
                (("bash", {"command": f"git --version && touch {SIDE_EFFECT}"}),),
                f'{guard}"touch {SIDE_EFFECT}" is outside the allowed prefixes',
            ),
            Step((("mcp__ycc_mcp_smoke_ping", {}),), f"{guard}this agent declares no MCP tools"),
            Step((device("mcp__ycc_mcp_smoke_ping"),), f"{guard}this agent declares no MCP tools"),
        ],
        # library-docs-writer declares context7 resolve-library-id and query-docs only, and no
        # bash tool at all (its `tools:` list omits it, so omp never offers bash).
        "SCRIPT-guard-docs-writer": [
            Step((("mcp__ycc_mcp_context7_resolve_library_id", {}),), "STUB-OK context7/resolve-library-id"),
            Step((device("mcp__ycc_mcp_context7_query_docs"),), "STUB-OK context7/query-docs"),
            Step((device("mcp__ycc_mcp_smoke_ping"),), f"{guard}mcp__ycc_mcp_smoke_ping is not a declared MCP tool"),
            Step((("bash", {"command": "true"}),), "Tool bash not found"),
        ],
        # The main session is never guarded.
        "SCRIPT-guard-main": [
            Step((("bash", {"command": "touch main-unguarded && echo MAIN-OK"}),), "MAIN-OK"),
            Step((("mcp__ycc_mcp_smoke_ping", {}),), "STUB-OK smoke/ping"),
        ],
        # `--plugin-dir` alone loads agents but not the scope guard extension.
        "SCRIPT-plugin-dir-git-cleanup": [
            Step((("bash", {"command": f"git --version && touch {PLUGIN_DIR_SIDE_EFFECT}"}),), "git version"),
        ],
        # YAN-1546: once-per-session TTSR reminders for the ycc-<family>-trigger rules.
        "SCRIPT-ttsr": [
            Step((("write", {"path": "first.py", "content": "x = 1\n"}),), "", ("ycc-python-trigger",)),
            Step((("write", {"path": "second.py", "content": "y = 2\n"}),), "", ()),
            Step((("write", {"path": "third.go", "content": "package third\n"}),), "", ("ycc-golang-trigger",)),
        ],
        "SCRIPT-permission": [Step((("bash", {"command": f"touch {PERMISSION_FILE}"}),))],
        "SCRIPT-skills": [
            Step(tuple(("read", {"path": f"skill://{name}"}) for name in skills(package)), "[Skill file: ")
        ],
    }
    scripts["SCRIPT-main-guard"] = [
        spawn("guard", ("git-cleanup", "SCRIPT-guard-git-cleanup"), ("library-docs-writer", "SCRIPT-guard-docs-writer"))
    ]
    scripts["SCRIPT-main-plugin-dir"] = [spawn("plugin-dir", ("git-cleanup", "SCRIPT-plugin-dir-git-cleanup"))]
    scripts["SCRIPT-main-agents"] = [spawn("agents", *((name, f"SCRIPT-agent-{name}") for name in agents(package)))]
    return scripts


def tool_names(body: dict[str, Any]) -> set[str]:
    return {str(t.get("function", {}).get("name")) for t in body.get("tools") or []}


def after_last_assistant(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    last = max((i for i, m in enumerate(messages) if m.get("role") == "assistant"), default=-1)
    return messages[last + 1 :]


def answer(scripts: dict[str, list[Step]], body: dict[str, Any], recorder: Recorder) -> dict[str, Any]:
    messages: list[dict[str, Any]] = body.get("messages") or []
    users = " ".join(text_of(m.get("content")) for m in messages if m.get("role") == "user")
    keys = MARKER.findall(users)
    key = keys[-1] if keys else ""
    step = sum(1 for m in messages if m.get("role") == "assistant")
    tail = after_last_assistant(messages)
    entry = {
        "key": key,
        "step": step,
        "model": body.get("model"),
        "results": [text_of(m.get("content")) for m in tail if m.get("role") == "tool"],
        "reminders": [
            rule for m in tail if m.get("role") != "tool" for rule in RULE.findall(text_of(m.get("content")))
        ],
        "tools": sorted(tool_names(body)),
    }
    with recorder.lock:
        recorder.requests.append(entry)
    steps = scripts.get(key, [])
    if step >= len(steps):
        return {"role": "assistant", "content": "DONE"}
    calls = [
        {
            "index": index,
            "id": f"call_{key[7:]}_{step}_{index}",
            "type": "function",
            "function": {"name": name, "arguments": json.dumps(args)},
        }
        for index, (name, args) in enumerate(steps[step].calls)
    ]
    return {"role": "assistant", "tool_calls": calls}


def provider(scripts: dict[str, list[Step]], recorder: Recorder) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            delta = answer(scripts, body, recorder)
            finish = "tool_calls" if "tool_calls" in delta else "stop"
            base = {"id": "scripted", "object": "chat.completion.chunk", "created": 0, "model": body.get("model")}
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for choice in ({"delta": delta, "finish_reason": None}, {"delta": {}, "finish_reason": finish}):
                self.wfile.write(f"data: {json.dumps({**base, 'choices': [{'index': 0, **choice}]})}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")

        def log_message(self, *_args: Any) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True).start()
    return server


def models_yml(port: int) -> str:
    """models.yml (JSON is valid YAML) for the scripted provider and a refused endpoint."""

    def block(url: str, ids: tuple[str, ...]) -> dict[str, Any]:
        api = "openai-completions"
        # Without an explicit window omp assumes 128k tokens. S5 returns every SKILL.md in one
        # turn (~570 KB), which overflows that and starts a compaction that races the tool batch
        # and replaces late results with "No result provided" (YAN-1606).
        models = [
            {
                "id": i,
                "name": i,
                "api": api,
                "reasoning": False,
                "input": ["text"],
                "contextWindow": CONTEXT_WINDOW,
                "maxTokens": MAX_TOKENS,
            }
            for i in ids
        ]
        return {"baseUrl": url, "apiKey": "none", "api": api, "auth": "none", "models": models}

    providers = {
        PROVIDER: block(f"http://127.0.0.1:{port}/v1", MODELS),
        DOWN_PROVIDER: block("http://127.0.0.1:9/v1", ("down",)),
    }
    return json.dumps({"providers": providers}, indent=2) + "\n"


def run_rpc(argv: list[str], prompt: str, approve: bool) -> tuple[int, str, str, list[dict[str, Any]]]:
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert proc.stdin is not None and proc.stdout is not None and proc.stderr is not None
    frames: list[dict[str, Any]] = []
    stderr: list[str] = []
    reader = threading.Thread(target=lambda: stderr.extend(proc.stderr or []), daemon=True)
    reader.start()
    timer = threading.Timer(SESSION_TIMEOUT, proc.kill)
    timer.start()
    try:
        proc.stdin.write(json.dumps({"id": "prompt", "type": "prompt", "message": prompt}) + "\n")
        proc.stdin.flush()
        for line in proc.stdout:
            if not line.strip():
                continue
            frame = json.loads(line)
            frames.append(frame)
            if frame.get("type") == "extension_ui_request" and frame.get("method") == "select":
                if str(frame.get("title", "")).startswith("Allow tool"):
                    reply = {
                        "type": "extension_ui_response",
                        "id": frame["id"],
                        "value": "Approve" if approve else "Deny",
                    }
                    proc.stdin.write(json.dumps(reply) + "\n")
                    proc.stdin.flush()
            if frame.get("type") == "agent_end":
                break
        proc.stdin.close()
        rc = proc.wait(timeout=30)
    finally:
        timer.cancel()
        if proc.poll() is None:
            proc.kill()
        reader.join(timeout=5)
    return rc, "", "".join(stderr), frames


def session(out: Path, agent_dir: Path, package: Path, rpc: str | None, approve: bool, argv: list[str]) -> str:
    if not argv:
        raise SmokeError("session: no omp argv")
    recorder = Recorder()
    server = provider(build_scripts(package), recorder)
    try:
        agent_dir.mkdir(parents=True, exist_ok=True)
        (agent_dir / "models.yml").write_text(models_yml(server.server_port), encoding="utf-8")
        started = time.monotonic()
        frames: list[dict[str, Any]] = []
        if rpc is not None:
            rc, stdout, stderr, frames = run_rpc(argv, rpc, approve)
        else:
            done = subprocess.run(
                argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=SESSION_TIMEOUT, check=False
            )
            rc, stdout, stderr = done.returncode, done.stdout, done.stderr
        elapsed = round(time.monotonic() - started, 1)
    finally:
        server.shutdown()
        server.server_close()
    with recorder.lock:
        requests = list(recorder.requests)
    payload = {
        "rc": rc,
        "seconds": elapsed,
        "stdout": stdout[-8000:],
        "stderr": stderr[-8000:],
        "frames": frames,
        "requests": requests,
    }
    out.write_text(json.dumps(payload, indent=1), encoding="utf-8")
    return f"session rc={rc} in {elapsed}s, {len(requests)} provider requests"


def load(out: Path) -> dict[str, Any]:
    try:
        data = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise SmokeError(f"{out}: unreadable session record: {exc}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("requests"), list):
        raise SmokeError(f"{out}: not a session record")
    return data


def requests_for(data: dict[str, Any], key: str) -> list[dict[str, Any]]:
    return [r for r in data["requests"] if r.get("key") == key]


def check_script(out: Path, package: Path, keys: list[str]) -> str:
    data = load(out)
    scripts = build_scripts(package)
    checked = 0
    for key in keys:
        steps = scripts.get(key)
        if steps is None:
            raise SmokeError(f"no script {key}")
        seen = requests_for(data, key)
        for index, step in enumerate(steps):
            reply = [r for r in seen if r.get("step") == index + 1]
            if not reply:
                raise SmokeError(
                    f"{key} step {index}: omp never returned its result (requests: {[r['step'] for r in seen]})"
                )
            results: list[str] = reply[0]["results"]
            if len(results) != len(step.calls):
                raise SmokeError(f"{key} step {index}: {len(results)} results for {len(step.calls)} calls: {results}")
            bad = [r[:300] for r in results if step.expect not in r]
            if bad:
                raise SmokeError(f"{key} step {index}: expected {step.expect!r} in every result, got {bad}")
            reminders = reply[0]["reminders"]
            if sorted(reminders) != sorted(step.reminders):
                raise SmokeError(f"{key} step {index}: reminders {reminders}, expected {list(step.reminders)}")
            checked += 1
    return f"scripts {', '.join(keys)}: {checked} steps returned the expected result"


def check_agents(out: Path, package: Path) -> str:
    data = load(out)
    expected = agents(package)
    main = requests_for(data, "SCRIPT-main-agents")
    final = [r for r in main if r.get("step") == 1]
    if not final:
        raise SmokeError("the agents task batch never returned")
    report = "\n".join(final[0]["results"])
    completed = set(re.findall(r'agent="([^"]+)" status="completed"', report))
    missing = sorted(set(expected) - completed)
    if missing:
        raise SmokeError(f"agents not completed: {missing}; report head {report[:600]!r}")
    wrong = {}
    for name, model in expected.items():
        models = {r.get("model") for r in requests_for(data, f"SCRIPT-agent-{name}")}
        if models != {model}:
            wrong[name] = (sorted(str(m) for m in models), model)
    if wrong:
        raise SmokeError(f"agent model roles: {wrong}")
    counts = {m: sum(1 for v in expected.values() if v == m) for m in MODELS}
    return f"agents: all {len(expected)} ycc agents completed; models by role {counts}"


def check_skills(out: Path, package: Path) -> str:
    data = load(out)
    names = skills(package)
    # Every request must belong to the script. An unmarked request means omp compacted the
    # session mid-batch, which can drop late results as "No result provided" (YAN-1606).
    stray = sorted({str(r.get("key")) for r in data["requests"]} - {"SCRIPT-skills"})
    if stray:
        raise SmokeError(f"requests outside SCRIPT-skills (omp compacted the session?): keys {stray}")
    reply = [r for r in requests_for(data, "SCRIPT-skills") if r.get("step") == 1]
    if not reply:
        raise SmokeError("the skill reads never returned")
    results: list[str] = reply[0]["results"]
    if len(results) != len(names):
        raise SmokeError(f"{len(results)} skill results for {len(names)} skills")
    bad = []
    for (name, directory), result in zip(names.items(), results, strict=True):
        head = result.split("\n", 1)[0]
        cached = "/plugins/cache/plugins/ycc___ycc___" in head
        if not (head.startswith("[Skill file: ") and cached and head.endswith(f"/skills/{directory}/SKILL.md]")):
            bad.append((name, head[:200]))
        elif f"name: {name}" not in result:
            bad.append((name, "body lacks its frontmatter name"))
    if bad:
        raise SmokeError(f"skills not read from the installed ycc cache: {bad}")
    return f"skills: all {len(names)} ycc skills read through skill:// from the installed ycc@ycc cache"


def check_ttsr(session_dir: Path) -> str:
    files = sorted(session_dir.rglob("*.jsonl"))
    if len(files) != 1:
        raise SmokeError(f"{session_dir}: expected one session file, found {[str(f) for f in files]}")
    injected: list[str] = []
    for line in files[0].read_text(encoding="utf-8").splitlines():
        entry = json.loads(line) if line.strip() else {}
        if entry.get("type") == "ttsr_injection":
            injected.extend(entry.get("injectedRules") or [])
    if sorted(injected) != ["ycc-golang-trigger", "ycc-python-trigger"]:
        raise SmokeError(f"ttsr_injection rules {injected}, expected one ycc-python-trigger and one ycc-golang-trigger")
    return "ttsr: one ycc-python-trigger entry for two .py writes, one ycc-golang-trigger for the .go write"


def check_rpc(out: Path, approve: bool) -> str:
    data = load(out)
    frames: list[dict[str, Any]] = data.get("frames") or []
    asks = [
        f
        for f in frames
        if f.get("type") == "extension_ui_request" and str(f.get("title", "")).startswith("Allow tool: bash")
    ]
    if len(asks) != 1:
        raise SmokeError(f"expected one `Allow tool: bash` select, got {len(asks)}")
    options = asks[0].get("options")
    if not isinstance(options, list) or "Approve" not in options or "Deny" not in options:
        raise SmokeError(f"approval select options {options}")
    if not any(f.get("type") == "agent_end" for f in frames):
        raise SmokeError("rpc session never reached agent_end")
    reply = [r for r in requests_for(data, "SCRIPT-permission") if r.get("step") == 1]
    result = reply[0]["results"][0] if reply and reply[0]["results"] else ""
    if not approve and "denied" not in result:
        raise SmokeError(f"denied call returned {result[:200]!r}")
    return f"rpc: one approval select {options}, answered {'Approve' if approve else 'Deny'}, agent_end reached"


def check_json(out: Path) -> str:
    data = load(out)
    types = [json.loads(line).get("type") for line in str(data.get("stdout", "")).splitlines() if line.startswith("{")]
    if "agent_end" not in types:
        raise SmokeError(f"--mode json emitted no agent_end (last types {types[-5:]})")
    return f"json: {len(types)} events ending in {types[-1]}"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="omp_scripted_smoke", description=(__doc__ or "").split("\n", 1)[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("session")
    p.add_argument("out", type=Path)
    p.add_argument("agent_dir", type=Path)
    p.add_argument("package", type=Path)
    p.add_argument("--rpc")
    p.add_argument("--approve", choices=("yes", "no"), default="no")
    p.add_argument("argv", nargs=argparse.REMAINDER)
    p = sub.add_parser("check-script")
    p.add_argument("out", type=Path)
    p.add_argument("package", type=Path)
    p.add_argument("keys", nargs="+")
    for name in ("check-agents", "check-skills"):
        p = sub.add_parser(name)
        p.add_argument("out", type=Path)
        p.add_argument("package", type=Path)
    p = sub.add_parser("check-ttsr")
    p.add_argument("session_dir", type=Path)
    p = sub.add_parser("check-rpc")
    p.add_argument("out", type=Path)
    p.add_argument("--approve", choices=("yes", "no"), default="no")
    p = sub.add_parser("check-json")
    p.add_argument("out", type=Path)
    ns = parser.parse_args(argv[1:])
    handlers: dict[str, Callable[[], str]] = {
        "session": lambda: session(
            ns.out,
            ns.agent_dir,
            ns.package,
            ns.rpc,
            ns.approve == "yes",
            ns.argv[1:] if ns.argv[:1] == ["--"] else ns.argv,
        ),
        "check-script": lambda: check_script(ns.out, ns.package, ns.keys),
        "check-agents": lambda: check_agents(ns.out, ns.package),
        "check-skills": lambda: check_skills(ns.out, ns.package),
        "check-ttsr": lambda: check_ttsr(ns.session_dir),
        "check-rpc": lambda: check_rpc(ns.out, ns.approve == "yes"),
        "check-json": lambda: check_json(ns.out),
    }
    try:
        message = handlers[ns.command]()
    except (SmokeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
        print(f"omp_scripted_smoke {ns.command}: {exc}", file=sys.stderr)
        return 1
    print(message)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
