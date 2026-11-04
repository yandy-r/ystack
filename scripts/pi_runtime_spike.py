#!/usr/bin/env python3
"""Fixtures, RPC driver and assertions for scripts/test-pi-runtime-contract-spike.sh (YAN-1182).

Nothing here talks to a model. The harness runs `fixtures`, `seed-home`, `sanitize` and the
assertions on the host, and runs `rpc` inside the sandbox (env -i, bwrap private netns), where
it starts `pi`.

  fixtures ROOT MCP_JSON AGENT_MD   write every fixture tree, extension and stub under ROOT
  seed-home AGENT_DIR ROOT          seed a user agent dir: null model, skills, context files, agents
  sanitize ROOT HOME FILE...        replace ROOT with <SANDBOX>, HOME with <HOME>, strip ANSI escapes
  rpc FRAMES CMD...                 run CMD (`pi --mode rpc ...`), send each JSONL frame of FRAMES
                                    in order and wait for its response; a prompt that starts a run
                                    is awaited until `agent_settled`. All stdout records are echoed.
  probe KIND FILE ARG...            assert on a probe file written by the probe extension:
                                    commands-has|commands-lacks NAME...; prompt-has|prompt-lacks TEXT...;
                                    tools-has|tools-lacks NAME...; trusted true|false;
                                    skill-desc NAME DESC; context-has|context-lacks PATH_SUFFIX...;
                                    active-tools NAME... (exact set, `-` for none);
                                    command-scope NAME SCOPE ORIGIN (exactly one such command);
                                    paths-has|paths-lacks SUBSTRING... (command source paths);
                                    seen-has TEXT... (FILE is the `.prompts` or `.hooks` list)
  json KIND FILE ARG...             assert on a JSON file: packages-eq ENTRY... (settings.json
                                    `packages`, `-` for none); mcp-server NAME STATE EXPOSURE TOOLS
                                    (TOOLS comma-joined, empty for none); mcp-states STATE COUNT;
                                    mcp-errors-has TEXT; mcp-errors-none
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")

STUB_MCP = """import json, sys
name = sys.argv[1]
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("id") is None:
        continue
    if m.get("method") == "initialize":
        r = {"protocolVersion": m["params"].get("protocolVersion", "2024-11-05"),
             "capabilities": {"tools": {}}, "serverInfo": {"name": name, "version": "0"}}
    elif m.get("method") == "tools/list":
        r = {"tools": [{"name": name + "_ping", "description": "marker " + name,
                        "inputSchema": {"type": "object", "properties": {}}}]}
    else:
        r = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}) + "\\n")
    sys.stdout.flush()
"""

# Records the effective session state as JSON (no model call). PI_SPIKE_WAIT_MCP=1 waits up to
# 5 s for MCP tools to register. before_agent_start logs each expanded prompt and aborts runs on
# the null model, so no provider request is made.
PROBE_TS = """import { writeFileSync } from "node:fs";
const out = process.env.PI_SPIKE_PROBE_OUT ?? "/dev/null";
const prompts: string[] = [];
export default function (pi: any) {
  pi.on("before_agent_start", async (event: any, ctx: any) => {
    prompts.push(String(event.prompt ?? ""));
    writeFileSync(out + ".prompts", JSON.stringify(prompts));
    if (ctx.model?.provider === "spike-null") ctx.abort();
  });
  pi.registerCommand("spike-probe", {
    description: "PROBEMARK",
    handler: async (_args: string, ctx: any) => {
      const hasMcp = () => pi.getAllTools().some((t: any) => String(t.name).startsWith("mcp__"));
      for (let i = 0; i < 50 && process.env.PI_SPIKE_WAIT_MCP === "1" && !hasMcp(); i++) {
        await new Promise((r) => setTimeout(r, 100));
      }
      const opts = ctx.getSystemPromptOptions ? ctx.getSystemPromptOptions() : {};
      writeFileSync(out, JSON.stringify({
        trusted: ctx.isProjectTrusted(),
        systemPrompt: ctx.getSystemPrompt(),
        tools: pi.getAllTools().map((t: any) => t.name),
        active: pi.getActiveTools(),
        context: (opts.contextFiles ?? []).map((f: any) => f.path),
        commands: pi.getCommands().map((c: any) => ({ name: c.name, source: c.source,
          scope: c.sourceInfo?.scope, origin: c.sourceInfo?.origin, path: c.sourceInfo?.path })),
      }, null, 1));
    },
  });
}
"""

# Scripted in-process provider (pi-ai faux): the first user message selects the script.
FAUX_TS = """import { fauxProvider, fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
const text = (m: any) => typeof m?.content === "string" ? m.content
  : (m?.content ?? []).map((c: any) => c.text ?? "").join("");
export default function (pi: any) {
  const faux = fauxProvider({ provider: "spike-faux", models: [{ id: "scripted" }] });
  const step = (ctx: any) => {
    const msgs = ctx.messages ?? [];
    const first = text(msgs.find((m: any) => m.role === "user"));
    const last = msgs[msgs.length - 1];
    if (first.includes("CHILDTASK")) return fauxAssistantMessage("CHILD-DONE");
    if (last?.role === "toolResult") return fauxAssistantMessage("PARENT-DONE " + text(last).slice(0, 300));
    if (first.includes("HOOKTASK")) {
      return fauxAssistantMessage([fauxToolCall("bash", { command: "touch " + process.env.PI_SPIKE_MARKER })],
        { stopReason: "toolUse" });
    }
    const agent = first.includes("DELEGATE-YCC") ? "code-reviewer" : "scout";
    return fauxAssistantMessage([fauxToolCall("subagent", { agent, task: "CHILDTASK" })], { stopReason: "toolUse" });
  };
  faux.setResponses(Array.from({ length: 64 }, () => step));
  pi.registerProvider(faux.provider);
}
"""

HOOKS_TS = """import { writeFileSync } from "node:fs";
const out = (process.env.PI_SPIKE_PROBE_OUT ?? "/dev/null") + ".hooks";
const seen: string[] = [];
const note = (s: string) => { seen.push(s); writeFileSync(out, JSON.stringify(seen)); };
export default function (pi: any) {
  pi.registerMcpServer("extmcp", { command: "python3", args: [process.env.PI_SPIKE_STUB, "extmcp"] });
  pi.on("session_start", async (_e: any, ctx: any) => {
    note("session_start");
    ctx.ui.setStatus("ycc", "STATUSMARK");
  });
  pi.on("tool_call", async (e: any) => {
    note("tool_call:" + e.toolName);
    return { block: true, reason: "BLOCKED-BY-SPIKE" };
  });
  pi.on("tool_result", async (e: any) => { note("tool_result:" + e.toolName); });
  pi.on("agent_settled", async () => { note("agent_settled"); });
}
"""

CHAIN_TS = """export default function (pi: any) {
  pi.registerCommand("ycc:ext-chain", { description: "EXTCHAIN",
    handler: async (args: string) => { pi.sendUserMessage("/skill:ph " + args, { expandPromptTemplates: true }); } });
}
"""


def skill(root: Path, name: str, description: str | None, extra: str = "", body: str = "body\n") -> None:
    lines = [f"name: {name}"]
    if description is not None:
        lines.append(f"description: {description}")
    if extra:
        lines.append(extra)
    write(root / name / "SKILL.md", "---\n" + "\n".join(lines) + "\n---\n" + body)


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def ext(*commands: tuple[str, str]) -> str:
    body = " ".join(
        f'pi.registerCommand("{name}", {{ description: "{desc}", handler: async () => {{}} }});'
        for name, desc in commands
    )
    return f"export default function (pi: any) {{ {body} }}\n"


def fixtures(root: Path, mcp_json: Path, agent_md: Path) -> None:
    write(root / "stub.py", STUB_MCP)
    for name, text in (
        ("probe.ts", PROBE_TS),
        ("faux.ts", FAUX_TS),
        ("hooks.ts", HOOKS_TS),
        ("chain.ts", CHAIN_TS),
        ("broken.ts", 'export default function () { throw new Error("BROKENEXT"); }\n'),
    ):
        write(root / "ext" / name, text)

    # Conventional-directory package (no `pi` manifest).
    pkg = root / "pkg"
    skill(pkg / "skills", "spike-skill", "SKILLMARK")
    skill(pkg / "skills", "dup", "PKG-DUP")
    write(pkg / "prompts/spike-tpl.md", "---\ndescription: TPLMARK\n---\nTPL all=$ARGUMENTS first=$1 rest=${@:2}\n")
    write(pkg / "prompts/ycc:colon-tpl.md", "COLONTPL $ARGUMENTS\n")
    write(pkg / "prompts/ycc:chain.md", "---\ndescription: chain\n---\n/skill:ph $ARGUMENTS\n")
    write(pkg / "extensions/index.ts", ext(("spike-ext", "EXTMARK"), ("ycc:colon-ext", "COLONEXT")))
    write(pkg / "package.json", json.dumps({"name": "ycc-spike", "version": "0.0.1", "keywords": ["pi-package"]}))

    # Manifest package: package.json#pi replaces conventional discovery for every type.
    mpkg = root / "mpkg"
    skill(mpkg / "skills", "conv-skill", "CONVMARK")
    write(mpkg / "prompts/conv-tpl.md", "CONVTPL\n")
    skill(mpkg / "res/skills", "man-skill", "MANMARK")
    write(mpkg / "src/ext.ts", ext(("man-ext", "MANEXT")))
    write(
        mpkg / "package.json",
        json.dumps(
            {
                "name": "ycc-spike-manifest",
                "version": "0.0.1",
                "pi": {"extensions": ["./src/ext.ts"], "skills": ["./res/skills"]},
            }
        ),
    )

    # One git repo carrying two package subtrees (a monorepo layout).
    mono = root / "mono"
    skill(mono / "packages/pi/ycc/skills", "mono-skill", "MONOSKILL")
    skill(mono / "packages/pi/ycc-rules/skills", "rule-skill", "RULESKILL")
    write(
        mono / "package.json",
        json.dumps(
            {
                "name": "ycc",
                "private": True,
                "scripts": {"prepare": "node -e \"require('fs').writeFileSync(process.env.PI_SPIKE_PREPARE, '')\""},
                "pi": {"skills": ["packages/pi/ycc/skills", "packages/pi/ycc-rules/skills"]},
            }
        ),
    )

    # A git package with a runtime dependency (npm runs offline and must fail).
    dep = root / "dep"
    skill(dep / "skills", "dep-skill", "DEPSKILL")
    write(dep / "package.json", json.dumps({"name": "dep", "version": "0.0.1", "dependencies": {"left-pad": "1.3.0"}}))

    # Broken extension package.
    write(root / "bpkg/extensions/index.ts", 'export default function () { throw new Error("BROKENPKG"); }\n')

    # Project with every trust-gated resource plus context files.
    proj = root / "proj"
    skill(proj / ".pi/skills", "proj-skill", "PROJSKILL")
    skill(proj / ".agents/skills", "agents-proj", "AGENTSPROJ")
    write(proj / ".pi/prompts/proj-tpl.md", "PROJTPL\n")
    write(proj / ".pi/extensions/proj.ts", ext(("proj-ext", "PROJEXT")))
    write(
        proj / ".pi/mcp.json",
        json.dumps({"mcpServers": {"projmcp": {"command": "python3", "args": [str(root / "stub.py"), "projmcp"]}}}),
    )
    write(proj / ".pi/settings.json", json.dumps({"defaultThinkingLevel": "high"}))
    write(proj / ".pi/APPEND_SYSTEM.md", "PROJAPPEND\n")
    write(proj / "AGENTS.md", "PROJAGENTSMD\n")
    write(proj / "CLAUDE.md", "PROJCLAUDEMD\n")
    write(root / "ctxonly/AGENTS.md", "CTXONLYAGENTS\n")

    # Inputs copied from the checkout: the shipped ycc-mcp server set and one ycc agent verbatim.
    servers = json.loads(mcp_json.read_text())
    for server in servers["mcpServers"].values():
        server["enabled"] = False
    write(root / "ycc-mcp.json", json.dumps(servers))
    shutil.copyfile(agent_md, root / "code-reviewer.md")


def seed_home(agent: Path, root: Path) -> None:
    """User agent dir shared by most cases: null model, user skills, context files, agents."""
    write(
        agent / "models.json",
        json.dumps(
            {
                "providers": {
                    "spike-null": {
                        "baseUrl": "http://127.0.0.1:9/v1",
                        "api": "openai-completions",
                        "apiKey": "none",
                        "models": [{"id": "null-model"}],
                    }
                }
            }
        ),
    )
    write(
        agent / "settings.json",
        json.dumps({"defaultProvider": "spike-null", "defaultModel": "null-model", "retry": {"enabled": False}}),
    )
    home = agent.parent.parent
    skills = agent / "skills"
    skill(skills, "dup2", "USER-DUP2")
    skill(skills, "Bad_Name", "BADNAME")
    skill(skills, "nodesc", None)
    skill(skills, "hidden", "HIDDENSKILL", "disable-model-invocation: true")
    skill(skills, "longdesc", "L" * 1100)
    skill(skills, "ph", "PHMARK", body="PHBODY root=${CLAUDE_PLUGIN_ROOT} args=$ARGUMENTS\n")
    skill(home / ".agents/skills", "dup2", "AGENTS-DUP2")
    skill(home / ".agents/skills", "dup", "AGENTS-DUP")
    skill(home / ".agents/skills", "agents-user", "AGENTSUSER")
    write(agent / "AGENTS.md", "USERAGENTSMD\n")
    write(agent / "APPEND_SYSTEM.md", "USERAPPEND\n")
    write(
        agent / "agents/scout.md", "---\nname: scout\ndescription: Spike scout\ntools: read, ls\n---\nYou are scout.\n"
    )
    shutil.copyfile(root / "code-reviewer.md", agent / "agents/code-reviewer.md")


def rpc(frames_path: Path, cmd: list[str]) -> int:
    frames = [json.loads(line) for line in frames_path.read_text().splitlines() if line.strip()]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    assert proc.stdin is not None and proc.stdout is not None
    stdout = proc.stdout

    def records() -> Iterator[dict[str, Any]]:
        while line := stdout.readline():
            sys.stdout.buffer.write(line)
            sys.stdout.flush()
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict):
                yield rec

    stream = records()
    for frame in frames:
        proc.stdin.write(json.dumps(frame).encode() + b"\n")
        proc.stdin.flush()
        started = False
        for rec in stream:
            if rec.get("type") == "response" and rec.get("id") == frame.get("id"):
                started = (rec.get("data") or {}).get("disposition") == "started"
                if not started:
                    break
            elif started and rec.get("type") == "agent_settled":
                break
    proc.stdin.close()
    for _ in stream:
        pass
    return proc.wait()


def fail(msg: str) -> int:
    print(f"assertion failed: {msg}", file=sys.stderr)
    return 1


def probe(kind: str, path: Path, args: list[str]) -> int:
    if not path.is_file():
        return fail(f"{path.name} was not written")
    data = json.loads(path.read_text())
    if kind == "seen-has":
        missing = [a for a in args if not any(a in str(s) for s in data)]
        return fail(f"{missing} not in {data}") if missing else 0
    names = [c["name"] for c in data["commands"]]
    prompt = data["systemPrompt"]
    checks: dict[str, tuple[list[str], bool]] = {
        "commands-has": (names, True),
        "commands-lacks": (names, False),
        "tools-has": (data["tools"], True),
        "tools-lacks": (data["tools"], False),
    }
    if kind in checks:
        pool, want = checks[kind]
        bad = [a for a in args if (a in pool) != want]
        return fail(f"{kind} {bad}; have {pool}") if bad else 0
    if kind in ("prompt-has", "prompt-lacks"):
        bad = [a for a in args if (a in prompt) != (kind == "prompt-has")]
        return fail(f"{kind} {bad}") if bad else 0
    if kind in ("context-has", "context-lacks"):
        bad = [a for a in args if any(p.endswith(a) for p in data["context"]) != (kind == "context-has")]
        return fail(f"{kind} {bad}; have {data['context']}") if bad else 0
    if kind == "trusted":
        return 0 if str(data["trusted"]).lower() == args[0] else fail(f"trusted={data['trusted']}")
    if kind == "active-tools":
        want = [] if args == ["-"] else args
        return 0 if sorted(data["active"]) == sorted(want) else fail(f"active={data['active']}")
    if kind == "skill-desc":
        needle = f"<name>{args[0]}</name>\n    <description>{args[1]}</description>"
        return 0 if needle in prompt else fail(f"skill {args[0]} not listed with {args[1]}")
    if kind == "command-scope":
        hits = [(c["scope"], c["origin"]) for c in data["commands"] if c["name"] == args[0]]
        return 0 if hits == [(args[1], args[2])] else fail(f"{args[0]} scope/origin={hits}")
    if kind in ("paths-has", "paths-lacks"):
        paths = [str(c.get("path")) for c in data["commands"]]
        bad = [a for a in args if any(a in p for p in paths) != (kind == "paths-has")]
        return fail(f"{kind} {bad}; have {paths}") if bad else 0
    return fail(f"unknown probe kind {kind}")


def json_check(kind: str, path: Path, args: list[str]) -> int:
    data = json.loads(path.read_text())
    if kind == "packages-eq":
        want = [] if args == ["-"] else args
        got = [p if isinstance(p, str) else p.get("source") for p in data.get("packages", [])]
        return 0 if got == want else fail(f"packages={got}")
    servers = {s["name"]: s for s in data.get("servers", [])}
    if kind == "mcp-server":
        server = servers.get(args[0], {})
        got = [server.get("state"), server.get("exposure"), ",".join(server.get("tools", []))]
        return 0 if got == args[1:4] else fail(f"{args[0]} state/exposure/tools={got}")
    if kind == "mcp-states":
        states = [s["state"] for s in servers.values()]
        ok = len(states) == int(args[1]) and set(states) == {args[0]}
        return 0 if ok else fail(f"states={states}")
    if kind == "mcp-errors-has":
        return 0 if any(args[0] in e for e in data.get("errors", [])) else fail(f"errors={data.get('errors')}")
    if kind == "mcp-errors-none":
        return 0 if data.get("errors") == [] else fail(f"errors={data.get('errors')}")
    return fail(f"unknown json kind {kind}")


def sanitize(root: str, home: str, paths: list[str]) -> None:
    for name in paths:
        path = Path(name)
        text = path.read_text(errors="replace").replace(root, "<SANDBOX>").replace(home, "<HOME>")
        path.write_text(ANSI.sub("", text))


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = argv[1], argv[2:]
    if cmd == "fixtures":
        fixtures(Path(rest[0]), Path(rest[1]), Path(rest[2]))
        return 0
    if cmd == "seed-home":
        seed_home(Path(rest[0]), Path(rest[1]))
        return 0
    if cmd == "sanitize":
        sanitize(rest[0], rest[1], rest[2:])
        return 0
    if cmd == "rpc":
        return rpc(Path(rest[0]), rest[1:])
    if cmd == "probe":
        return probe(rest[0], Path(rest[1]), rest[2:])
    if cmd == "json":
        return json_check(rest[0], Path(rest[1]), rest[2:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
