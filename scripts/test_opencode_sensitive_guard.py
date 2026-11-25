#!/usr/bin/env python3
"""Behaviour tests for the generated ycc sensitive-file guard (OpenCode V2 plugin).

The generated plugin is imported under node and driven with a fake V2 context
whose `tool.hook`, `tool.transform`, `agent.transform`, `session.hook` and
`permission.hook` record the registrations, so each case exercises the same
events OpenCode v2.0.32 triggers (packages/plugin/src/promise/tool.ts,
session.ts, permission.ts).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from opencode_sensitive_policy import GUARDED_SEARCH_TOOLS  # noqa: E402
from test_generate_opencode_agents import evaluate  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
GUARD_DIR = REPO_ROOT / ".opencode-plugin" / "ycc-sensitive-guard"
NODE = shutil.which("node")
RESTRICTED = "pr-comment-fixer"
OPEN_AGENT = "code-finder"
SEARCH_AGENT = "ycc-sensitive-search"

# Reads cases as JSON on stdin and prints one JSON outcome per case. The setup
# location (`setupDir`, like a server started elsewhere) differs from the
# session location that ctx.session.get reports for each case's sessionID.
# Built-in grep/glob are fakes that record the context they ran with and
# return the case's scripted result.
DRIVER = r"""
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
const [guardDir, setupDir] = process.argv.slice(2);
const { sessions, setupLocation, builtins, cases } = JSON.parse(readFileSync(0, "utf8"));
const plugin = (await import(pathToFileURL(guardDir + "/index.js").href)).default;
const hooks = {}, sessionHooks = {}, permissionHooks = {};
const agents = new Map(), tools = new Map(), calls = [], asserts = [];
let decisions = {};
let scripted = null;
let helperCheck = null;
async function evaluate(event) {
  for (const cb of permissionHooks.evaluate ?? []) await cb(event);
  return event;
}
// Fake built-ins: when a case scripts `helperCheck`, the built-in's own
// external-directory request is evaluated through the permission hooks with
// the effect the host's rules would give it.
for (const name of builtins) {
  tools.set(name, {
    name, description: `builtin ${name}`, input: { schema: name }, output: { schema: name },
    options: { codemode: false },
    execute: async (input, context) => {
      const call = { tool: name, agent: context.agent, input };
      if (helperCheck) {
        const event = await evaluate({ sessionID: context.sessionID, agent: context.agent,
          action: "external_directory", resources: helperCheck.resources, effect: helperCheck.effect,
          source: { type: "tool", messageID: context.messageID, id: context.id } });
        call.helperEffect = event.effect;
      }
      calls.push(call);
      return structuredClone(scripted);
    },
  });
}
const ctx = {
  location: setupLocation === false
    ? undefined
    : { directory: setupDir, project: { directory: setupDir, canonical: setupDir } },
  tool: {
    hook: async (name, cb) => { (hooks[name] ??= []).push(cb); },
    transform: async (cb) => cb({
      get: (id) => tools.get(id),
      add: (tool) => tools.set(tool.name, tool),
    }),
  },
  agent: {
    transform: async (cb) => cb({
      get: (id) => agents.get(id),
      update: (id, fn) => { const record = agents.get(id) ?? { id }; fn(record); agents.set(id, record); },
    }),
  },
  // Permission checks the guard makes itself: a case's `decisions` maps an
  // action to "deny" (rule deny) or "reject" (the user declines a prompt).
  permission: {
    hook: async (name, cb) => { (permissionHooks[name] ??= []).push(cb); },
    assert: async (input) => {
      asserts.push(structuredClone(input));
      const decision = decisions[input.action] ?? "allow";
      if (decision === "deny") throw new Error(`Permission denied: ${input.action}`);
      if (decision === "reject") throw new Error(`Permission rejected by user: ${input.action}`);
    },
  },
  session: {
    hook: async (name, cb) => { (sessionHooks[name] ??= []).push(cb); },
    get: async ({ sessionID }) => {
      if (!(sessionID in sessions)) throw new Error(`session not found: ${sessionID}`);
      return { data: { id: sessionID, location: { directory: sessions[sessionID] } } };
    },
  },
};
await plugin.setup(ctx);
const results = [];
for (const item of cases) {
  const sessionID = item.sessionID ?? "ses";
  const event = { sessionID, messageID: "msg", id: "call", agent: item.agent, tool: item.tool, input: item.input };
  calls.length = 0;
  asserts.length = 0;
  decisions = item.decisions ?? {};
  helperCheck = item.helperCheck ?? null;
  try {
    if (item.kind === "execute") {
      scripted = item.result ?? { output: [], content: "No matches found", metadata: {} };
      const context = { sessionID, agent: item.agent, messageID: "msg", id: item.callID ?? "call" };
      const result = await tools.get(item.tool).execute(item.input, context);
      results.push({ ok: true, result, calls: structuredClone(calls), asserts: structuredClone(asserts) });
    } else if (item.kind === "evaluate") {
      const event = await evaluate({ sessionID, agent: item.agent, action: item.action, resources: item.resources,
        effect: item.effect, source: { type: "tool", messageID: "msg", id: item.callID ?? "call" } });
      results.push({ ok: true, effect: event.effect });
    } else if (item.kind === "context") {
      const ctxEvent = { sessionID, agent: item.agent, system: [], messages: [], options: {}, tools: item.tools };
      for (const cb of sessionHooks.context ?? []) await cb(ctxEvent);
      results.push({ ok: true, tools: Object.keys(ctxEvent.tools).sort(),
        identity: Object.fromEntries(Object.entries(ctxEvent.tools).map(([k, v]) => [k, v.tag])) });
    } else if (item.result) {
      Object.assign(event, { status: "completed", result: item.result });
      for (const cb of hooks["execute.after"] ?? []) await cb(event);
      results.push({ ok: true, result: event.result });
    } else {
      for (const cb of hooks["execute.before"] ?? []) await cb(event);
      results.push({ ok: true });
    }
  } catch (error) {
    results.push({ ok: false, message: String(error?.message ?? error), calls: structuredClone(calls),
      asserts: structuredClone(asserts) });
  }
}
const registered = [...tools.values()].filter((tool) => !builtins.includes(tool.name)).map((tool) => ({
  name: tool.name, description: tool.description, input: tool.input, output: tool.output, options: tool.options,
}));
console.log(JSON.stringify({
  id: plugin.id,
  hooks: Object.keys(hooks).sort(),
  agents: [...agents.values()],
  tools: registered,
  results,
}));
"""


@unittest.skipIf(NODE is None, "node is required")
class SensitiveGuardTestCase(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.work = self.tmp / "work"
        (self.work / "src").mkdir(parents=True)
        (self.work / "src" / "app.ts").write_text("export const value = 1;\n", encoding="utf-8")
        (self.work / ".env").write_text("TOKEN=synthetic\n", encoding="utf-8")
        (self.work / ".env.example").write_text("TOKEN=\n", encoding="utf-8")
        (self.work / "config").mkdir()
        (self.work / "config" / ".env.production").write_text("TOKEN=synthetic\n", encoding="utf-8")
        (self.work / "notes.txt").symlink_to(self.work / ".env")
        (self.work / "linked").symlink_to(self.work / "config")
        # Dangling link to a sensitive path that does not exist yet.
        (self.work / "pending.txt").symlink_to(self.work / "config" / ".env.local")
        # Curly-quote name that the read tool's look-alike fallback would pick.
        (self.work / "it\u2019s.txt").symlink_to(self.work / ".env")

    def drive(
        self,
        cases: list[dict[str, Any]],
        sessions: dict[str, str] | None = None,
        setup_dir: Path | None = None,
        setup_location: bool = True,
        builtins: tuple[str, ...] = ("grep", "glob"),
    ) -> dict[str, Any]:
        """Set the guard up against the fake context and run every case."""
        assert NODE is not None
        script = self.tmp / "driver.mjs"
        script.write_text(DRIVER, encoding="utf-8")
        server = setup_dir or self.tmp / "server"
        server.mkdir(exist_ok=True)
        payload = {
            "sessions": {"ses": str(self.work)} if sessions is None else sessions,
            "setupLocation": setup_location,
            "builtins": list(builtins),
            "cases": cases,
        }
        result = subprocess.run(
            [NODE, str(script), str(GUARD_DIR), str(server)],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            timeout=60,
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.tmp / "home")},
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        observed: dict[str, Any] = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(observed["id"], "yandy-r.ycc-sensitive-guard")
        self.assertEqual(observed["hooks"], ["execute.after", "execute.before"])
        return observed

    def run_cases(
        self,
        cases: list[dict[str, Any]],
        sessions: dict[str, str] | None = None,
        setup_dir: Path | None = None,
        setup_location: bool = True,
    ) -> list[dict[str, Any]]:
        """Drive the hooks; session "ses" lives in self.work unless overridden.

        The plugin's setup location defaults to a separate server directory, so
        every case also proves paths resolve against the session location.
        """
        results: list[dict[str, Any]] = self.drive(cases, sessions, setup_dir, setup_location)["results"]
        return results

    def assert_blocked(self, tool: str, input_: dict[str, Any], agent: str = RESTRICTED) -> None:
        (outcome,) = self.run_cases([{"agent": agent, "tool": tool, "input": input_}])
        self.assertFalse(outcome["ok"], f"{tool} {input_} was not blocked")
        self.assertIn("ycc sensitive-file guard", outcome["message"])

    def assert_allowed(self, tool: str, input_: dict[str, Any], agent: str = RESTRICTED) -> None:
        (outcome,) = self.run_cases([{"agent": agent, "tool": tool, "input": input_}])
        self.assertTrue(outcome["ok"], outcome)

    def test_blocks_sensitive_targets_for_restricted_agents(self) -> None:
        blocked = [
            ("read", {"path": ".env"}),
            ("read", {"path": "./config/../.env"}),
            ("read", {"path": str(self.work / "config" / ".env.production")}),
            ("read", {"path": ".ENV"}),
            ("read", {"path": "notes.txt"}),
            ("read", {"path": "linked/.env.production"}),
            ("read", {"path": "~/.aws/credentials"}),
            ("read", {"path": "deploy/server.pem"}),
            ("read", {"path": ".ssh"}),
            ("edit", {"path": ".env", "oldString": "a", "newString": "b"}),
            ("write", {"path": "config/.envrc", "content": "x"}),
            ("patch", {"patchText": "*** Begin Patch\n*** Update File: notes.txt\n@@\n-a\n+b\n*** End Patch"}),
            ("patch", {"patchText": "*** Begin Patch\n*** Add File: keys/id_rsa\n+x\n*** End Patch"}),
            ("grep", {"pattern": "TOKEN", "path": ".env"}),
            ("grep", {"pattern": "TOKEN", "path": "notes.txt"}),
            ("grep", {"pattern": "TOKEN", "include": ".env"}),
            ("grep", {"pattern": "TOKEN", "include": "**/.env.production"}),
            ("glob", {"pattern": "*", "path": ".ssh"}),
            ("shell", {"command": "npm run x -- .env"}),
            ("shell", {"command": "python3 -c \"print(open('config/.env.production').read())\""}),
            ("shell", {"command": "make show FILE=notes.txt"}),
            ("shell", {"command": "ls .e*"}),
            ("shell", {"command": "ls", "workdir": ".ssh"}),
            ("shell", {"command": "git show HEAD:.env"}),
            ("shell", {"command": "git show HEAD~1:.env"}),
            ("shell", {"command": "git show 'main:config/.env.production'"}),
            ("shell", {"command": "git show :0:.env"}),
            ("shell", {"command": "git cat-file -p v1.2.0:deploy/server.pem"}),
            ("shell", {"command": "git log -p -- HEAD:.ENV"}),
            ("shell", {"command": "git diff --no-index . /tmp/empty"}),
            ("shell", {"command": "git diff --stat --no-index -- .. /tmp/empty"}),
            ("shell", {"command": "cat .{e,x}nv"}),
            ("shell", {"command": "cat .{'e'nv,'a b'}"}),
            ("shell", {"command": "git diff /tmp/empty ."}),
            ("shell", {"command": "git diff . ~/empty"}),
            ("shell", {"command": "git diff -- ../outside ."}),
            ("shell", {"command": "git -C /tmp/elsewhere diff"}),
            ("shell", {"command": "git --git-dir=/tmp/x/.git log -p"}),
            ("shell", {"command": "git --work-tree /tmp/x diff"}),
            ("shell", {"command": "git diff", "workdir": "/tmp"}),
            ("shell", {"command": "cd src && git diff ../../outside ."}),
            ("shell", {"command": "git diff $HOME ."}),
            ("shell", {"command": 'git diff "${TMPDIR}" .'}),
            ("shell", {"command": "git diff $(dirname $PWD) ."}),
            ("shell", {"command": "git diff `echo /tmp` ."}),
            ("shell", {"command": "cat $OLDPWD/.env"}),
            ("shell", {"command": "git diff ~root ."}),
            ("shell", {"command": "git diff ~someone/project ."}),
            ("shell", {"command": "git diff ~- ."}),
            ("shell", {"command": "git diff ~+/../sibling ."}),
            ("shell", {"command": "git diff --output=x ~+/.. ."}),
            ("shell", {"command": "make show DIR=~-"}),
            ("shell", {"command": "cat .e{n..n}v"}),
            ("shell", {"command": "cat $'\\x2eenv'"}),
            ("write", {"path": "pending.txt", "content": "x"}),
            ("edit", {"path": "pending.txt", "oldString": "a", "newString": "b"}),
            ("patch", {"patchText": "*** Begin Patch\n  *** Update File: notes.txt\n@@\n-a\n+b\n*** End Patch"}),
            ("patch", {"patchText": "*** Begin Patch\n\t*** Add File:   pending.txt  \n+x\n*** End Patch"}),
            ("read", {"path": "it's.txt"}),
            ("read", {"path": "keys/id_rsa.env.example"}),
            ("read", {"path": "id_ed25519.prod.env.example"}),
            ("read", {"path": "prod.env"}),
            ("read", {"path": "config/app.env"}),
            ("read", {"path": "app.env.local"}),
            ("edit", {"path": "config/app.env", "oldString": "a", "newString": "b"}),
            ("grep", {"pattern": "TOKEN", "path": "prod.env"}),
            ("shell", {"command": "ls; head prod.env"}),
        ]
        cases = [{"agent": RESTRICTED, "tool": tool, "input": input_} for tool, input_ in blocked]
        for (tool, input_), outcome in zip(blocked, self.run_cases(cases), strict=True):
            with self.subTest(tool=tool, input=input_):
                self.assertFalse(outcome["ok"], outcome)
                self.assertIn("ycc sensitive-file guard", outcome["message"])

    def test_allows_ordinary_work_and_documented_exceptions(self) -> None:
        allowed = [
            ("read", {"path": "src/app.ts"}),
            ("read", {"path": ".env.example"}),
            ("read", {"path": "app.env.example"}),
            ("read", {"path": "config/app.env.example"}),
            ("read", {"path": "."}),
            ("edit", {"path": "src/app.ts", "oldString": "1", "newString": "2"}),
            ("grep", {"pattern": "value", "path": "src"}),
            ("grep", {"pattern": "value"}),
            ("grep", {"pattern": "value", "include": "*.ts"}),
            ("glob", {"pattern": "**/*.ts"}),
            ("shell", {"command": "ls"}),
            ("shell", {"command": "ls src/*"}),
            ("shell", {"command": "npm test -- src/app.ts"}),
            ("shell", {"command": "pytest -k env"}),
            ("shell", {"command": "git show HEAD:src/app.ts"}),
            ("shell", {"command": "git show HEAD~1:.env.example"}),
            ("shell", {"command": "git log --oneline HEAD~3..HEAD"}),
            ("shell", {"command": "git diff origin/main:src/app.ts HEAD:src/app.ts"}),
            ("shell", {"command": "git diff HEAD~1 -- src"}),
            ("shell", {"command": "git status --short && git log --oneline -- src/app.ts"}),
            ("shell", {"command": "git diff", "workdir": "src"}),
            ("shell", {"command": "git blame -C src/app.ts"}),
            ("shell", {"command": "git log -c -p HEAD~2..HEAD -- src"}),
            ("shell", {"command": "npm test -- --grep '{value}'"}),
            ("read", {"path": "src/missing.ts"}),
            ("write", {"path": "src/new.ts", "content": "x"}),
            ("patch", {"patchText": "*** Begin Patch\n  *** Update File: src/app.ts\n@@\n-1\n+2\n*** End Patch"}),
        ]
        cases = [{"agent": RESTRICTED, "tool": tool, "input": input_} for tool, input_ in allowed]
        for (tool, input_), outcome in zip(allowed, self.run_cases(cases), strict=True):
            with self.subTest(tool=tool, input=input_):
                self.assertTrue(outcome["ok"], outcome)

    def test_unrestricted_agents_are_untouched(self) -> None:
        self.assert_allowed("read", {"path": ".env"}, agent=OPEN_AGENT)
        self.assert_allowed("shell", {"command": "cat .env"}, agent=OPEN_AGENT)

    def test_grep_results_drop_sensitive_files_and_recount(self) -> None:
        output = [
            {"entry": {"path": ".env"}, "line": 1, "offset": 0, "text": "TOKEN=synthetic", "submatches": []},
            {"entry": {"path": "src/app.ts"}, "line": 1, "offset": 0, "text": "export const value", "submatches": []},
            {"entry": {"path": "notes.txt"}, "line": 1, "offset": 0, "text": "TOKEN=synthetic", "submatches": []},
        ]
        result = {
            "output": output,
            "content": "Found 3 matches\n.env:\n  Line 1: TOKEN=synthetic",
            "metadata": {"matches": 3, "truncated": False},
        }
        cases = [{"agent": RESTRICTED, "tool": "grep", "input": {"pattern": "."}, "result": result}]
        (outcome,) = self.run_cases(cases)
        filtered = outcome["result"]
        self.assertEqual([m["entry"]["path"] for m in filtered["output"]], ["src/app.ts"])
        self.assertEqual(filtered["metadata"]["matches"], 1)
        self.assertNotIn("synthetic", json.dumps(filtered))
        self.assertIn("Found 1 matches", filtered["content"])
        self.assertIn(str(self.work / "src" / "app.ts"), filtered["content"])

        cases = [{"agent": OPEN_AGENT, "tool": "grep", "input": {"pattern": "."}, "result": result}]
        (untouched,) = self.run_cases(cases)
        self.assertEqual(untouched["result"], result)

    def test_glob_results_drop_sensitive_names(self) -> None:
        result = {
            "output": [{"path": ".env"}, {"path": ".env.example"}, {"path": "src/app.ts"}, {"path": "linked"}],
            "content": "x",
            "metadata": {"count": 4, "truncated": False},
        }
        (outcome,) = self.run_cases(
            [{"agent": RESTRICTED, "tool": "glob", "input": {"pattern": "*", "hidden": True}, "result": result}]
        )
        filtered = outcome["result"]
        self.assertEqual([e["path"] for e in filtered["output"]], [".env.example", "src/app.ts", "linked"])
        self.assertEqual(filtered["metadata"]["count"], 3)
        self.assertNotIn(str(self.work / ".env") + "\n", filtered["content"] + "\n")

        empty = {"output": [{"path": ".env"}], "content": "x", "metadata": {"count": 1, "truncated": False}}
        cases = [{"agent": RESTRICTED, "tool": "glob", "input": {"pattern": ".env"}, "result": empty}]
        (outcome,) = self.run_cases(cases)
        self.assertEqual(outcome["result"]["content"], "No files found")

    def test_error_results_pass_through(self) -> None:
        cases = [{"agent": RESTRICTED, "tool": "read", "input": {"path": "src/app.ts"}, "result": {"content": "ok"}}]
        (outcome,) = self.run_cases(cases)
        self.assertEqual(outcome["result"], {"content": "ok"})

    def test_paths_resolve_against_each_sessions_location(self) -> None:
        other = self.tmp / "other"
        (other / "src").mkdir(parents=True)
        (other / "src" / "main.ts").write_text("x\n", encoding="utf-8")
        sessions = {"ses": str(self.work), "ses-other": str(other)}
        cases = [
            # Relative `.env` names the session's file, not the server's.
            {"agent": RESTRICTED, "tool": "read", "input": {"path": "notes.txt"}},
            {"agent": RESTRICTED, "tool": "read", "input": {"path": "notes.txt"}, "sessionID": "ses-other"},
            # git arguments are confined to the calling session's directory.
            {"agent": RESTRICTED, "tool": "shell", "input": {"command": "git diff src ."}, "sessionID": "ses-other"},
            {
                "agent": RESTRICTED,
                "tool": "shell",
                "input": {"command": f"git diff {self.work} ."},
                "sessionID": "ses-other",
            },
        ]
        outcomes = self.run_cases(cases, sessions=sessions)
        self.assertEqual([outcome["ok"] for outcome in outcomes], [False, True, True, False])

        grep = {
            "output": [{"entry": {"path": "src/main.ts"}, "line": 1, "offset": 0, "text": "x", "submatches": []}],
            "content": "x",
            "metadata": {"matches": 1, "truncated": False},
        }
        (filtered,) = self.run_cases(
            [
                {
                    "agent": RESTRICTED,
                    "tool": "grep",
                    "input": {"pattern": "x"},
                    "result": grep,
                    "sessionID": "ses-other",
                }
            ],
            sessions=sessions,
        )
        self.assertIn(str(other / "src" / "main.ts"), filtered["result"]["content"])

    def test_falls_back_to_setup_location_then_fails_closed(self) -> None:
        # session.get fails: the plugin's setup location is the root.
        (outcome,) = self.run_cases(
            [{"agent": RESTRICTED, "tool": "read", "input": {"path": ".env"}, "sessionID": "gone"}],
            setup_dir=self.work,
        )
        self.assertFalse(outcome["ok"])
        (outcome,) = self.run_cases(
            [{"agent": RESTRICTED, "tool": "read", "input": {"path": "src/app.ts"}, "sessionID": "gone"}],
            setup_dir=self.work,
        )
        self.assertTrue(outcome["ok"], outcome)

        # Neither: restricted agents are denied, results withheld, others untouched.
        grep = {"output": [{"entry": {"path": "src/app.ts"}}], "content": "x", "metadata": {}}
        outcomes = self.run_cases(
            [
                {"agent": RESTRICTED, "tool": "read", "input": {"path": "src/app.ts"}, "sessionID": "gone"},
                {"agent": RESTRICTED, "tool": "grep", "input": {"pattern": "x"}, "result": grep, "sessionID": "gone"},
                {"agent": OPEN_AGENT, "tool": "read", "input": {"path": ".env"}, "sessionID": "gone"},
            ],
            setup_location=False,
        )
        self.assertFalse(outcomes[0]["ok"])
        self.assertIn("ycc sensitive-file guard", outcomes[0]["message"])
        self.assertEqual(outcomes[1]["result"]["output"], [])
        self.assertIn("withheld", outcomes[1]["result"]["content"])
        self.assertTrue(outcomes[2]["ok"])

    # -- guarded search tools (restricted agents' only search path) -----------

    def test_registers_guarded_search_tools_reusing_builtin_definitions(self) -> None:
        observed = self.drive([])
        tools = {tool["name"]: tool for tool in observed["tools"]}
        self.assertEqual(set(tools), set(GUARDED_SEARCH_TOOLS.values()))
        for base, name in GUARDED_SEARCH_TOOLS.items():
            with self.subTest(tool=name):
                self.assertEqual(tools[name]["description"], f"builtin {base}")
                self.assertEqual(tools[name]["input"], {"schema": base})
                self.assertEqual(tools[name]["output"], {"schema": base})
                self.assertEqual(tools[name]["options"], {"codemode": False})

    def test_internal_search_agent_may_only_search(self) -> None:
        (helper,) = self.drive([])["agents"]
        self.assertEqual(helper["id"], SEARCH_AGENT)
        self.assertTrue(helper["hidden"])
        # `primary`: the subagent tool refuses to start it.
        self.assertEqual(helper["mode"], "primary")
        rules = helper["permissions"]
        for action in ("grep", "glob", "external_directory"):
            self.assertEqual(evaluate(rules, action, "/elsewhere/*"), "allow", action)
        for action in ("read", "edit", "shell", "webfetch", "subagent", "ycc_grep", "skill"):
            self.assertEqual(evaluate(rules, action, "x"), "deny", action)

    def test_internal_search_agent_cannot_run_tools_directly(self) -> None:
        cases = [
            {"agent": SEARCH_AGENT, "tool": tool, "input": input_}
            for tool, input_ in (("grep", {"pattern": "x"}), ("glob", {"pattern": "*"}), ("read", {"path": "src"}))
        ]
        for outcome in self.run_cases(cases):
            self.assertFalse(outcome["ok"], outcome)
            self.assertIn("ycc sensitive-file guard", outcome["message"])

    def test_guarded_search_authorizes_as_the_calling_agent(self) -> None:
        cases = [
            {"kind": "execute", "agent": RESTRICTED, "tool": "ycc_grep", "input": {"pattern": "value", "path": "src"}},
            {"kind": "execute", "agent": RESTRICTED, "tool": "ycc_glob", "input": {"pattern": "**/*.ts"}},
        ]
        for outcome, name, pattern in zip(
            self.run_cases(cases), ("ycc_grep", "ycc_glob"), ("value", "**/*.ts"), strict=True
        ):
            with self.subTest(tool=name):
                self.assertTrue(outcome["ok"], outcome)
                (check,) = outcome["asserts"]
                self.assertEqual(check["action"], name)
                self.assertEqual(check["agent"], RESTRICTED)
                self.assertEqual(check["resources"], [pattern])
                self.assertEqual(check["sessionID"], "ses")

    def test_guarded_search_honors_the_calling_agents_deny_and_rejection(self) -> None:
        cases = [
            {
                "kind": "execute",
                "agent": RESTRICTED,
                "tool": "ycc_grep",
                "input": {"pattern": "value"},
                "decisions": {"ycc_grep": decision},
            }
            for decision in ("deny", "reject")
        ]
        for outcome in self.run_cases(cases):
            self.assertFalse(outcome["ok"], outcome)
            self.assertEqual(outcome["calls"], [])

    def test_guarded_search_outside_the_session_asks_as_the_calling_agent(self) -> None:
        outside = self.tmp / "outside"
        (outside / "lib").mkdir(parents=True)
        cases = [
            {
                "kind": "execute",
                "agent": RESTRICTED,
                "tool": "ycc_grep",
                "input": {"pattern": "x", "path": str(outside)},
            },
            {
                "kind": "execute",
                "agent": RESTRICTED,
                "tool": "ycc_glob",
                "input": {"pattern": "*", "path": "../outside/lib"},
                "decisions": {"external_directory": "reject"},
            },
        ]
        allowed, rejected = self.run_cases(cases)
        self.assertTrue(allowed["ok"], allowed)
        external = [check for check in allowed["asserts"] if check["action"] == "external_directory"]
        self.assertEqual(len(external), 1)
        self.assertEqual(external[0]["agent"], RESTRICTED)
        self.assertEqual(external[0]["resources"], [f"{outside}/*"])
        self.assertFalse(rejected["ok"])
        self.assertEqual(rejected["calls"], [])
        self.assertEqual(rejected["asserts"][0]["resources"], [f"{outside}/lib/*"])
        # Inside the session no directory approval is requested.
        (inside,) = self.run_cases(
            [{"kind": "execute", "agent": RESTRICTED, "tool": "ycc_grep", "input": {"pattern": "x", "path": "src"}}]
        )
        self.assertEqual([check["action"] for check in inside["asserts"]], ["ycc_grep"])

    def outside_project(self) -> tuple[Path, Path, Path]:
        """A version-controlled project whose session runs in a subdirectory."""
        project = self.tmp / "project"
        (project / ".git").mkdir(parents=True)
        (project / "sub").mkdir()
        (project / "other").mkdir()
        outside = self.tmp / "elsewhere"
        outside.mkdir()
        (outside / "notes.txt").write_text("x\n", encoding="utf-8")
        return project, project / "sub", outside

    def test_guarded_search_inside_the_project_is_not_external(self) -> None:
        project, session, _ = self.outside_project()
        (inside,) = self.run_cases(
            [
                {
                    "kind": "execute",
                    "agent": RESTRICTED,
                    "tool": "ycc_grep",
                    "input": {"pattern": "x", "path": "../other"},
                }
            ],
            sessions={"ses": str(session)},
        )
        self.assertTrue(inside["ok"], inside)
        self.assertEqual([check["action"] for check in inside["asserts"]], ["ycc_grep"])
        self.assertEqual(inside["calls"][0]["input"]["path"], "../other")

    def test_guarded_search_directory_approval_matches_the_builtin_target(self) -> None:
        _, session, outside = self.outside_project()
        file = str(outside / "notes.txt")
        grep, glob = self.run_cases(
            [
                {"kind": "execute", "agent": RESTRICTED, "tool": "ycc_grep", "input": {"pattern": "x", "path": file}},
                {"kind": "execute", "agent": RESTRICTED, "tool": "ycc_glob", "input": {"pattern": "*", "path": file}},
            ],
            sessions={"ses": str(session)},
        )
        # grep judges a file root by its parent; glob always treats the root as a directory.
        self.assertEqual(grep["asserts"][0]["resources"], [f"{outside}/*"])
        self.assertEqual(glob["asserts"][0]["resources"], [f"{file}/*"])

    def test_guarded_search_check_carries_the_builtin_metadata(self) -> None:
        grep, glob = self.run_cases(
            [
                {
                    "kind": "execute",
                    "agent": RESTRICTED,
                    "tool": "ycc_grep",
                    "input": {"pattern": "x", "path": "src", "include": "*.ts", "literal": True, "limit": 5},
                },
                {"kind": "execute", "agent": RESTRICTED, "tool": "ycc_glob", "input": {"pattern": "*", "hidden": True}},
            ]
        )
        self.assertEqual(
            grep["asserts"][-1]["metadata"],
            {"root": ".", "path": "src", "include": "*.ts", "literal": True, "limit": 5},
        )
        self.assertEqual(glob["asserts"][-1]["metadata"], {"root": ".", "hidden": True})

    def test_approved_directory_is_not_asked_again_for_the_internal_search(self) -> None:
        _, session, outside = self.outside_project()
        approved = [f"{outside}/*"]
        cases: list[dict[str, Any]] = [
            # The host would ask the helper for the directory the caller just approved.
            {
                "kind": "execute",
                "agent": RESTRICTED,
                "tool": "ycc_grep",
                "input": {"pattern": "x", "path": str(outside)},
                "helperCheck": {"resources": approved, "effect": "ask"},
            },
            # A different directory is not covered by the caller's approval.
            {
                "kind": "execute",
                "agent": RESTRICTED,
                "tool": "ycc_grep",
                "input": {"pattern": "x", "path": str(outside)},
                "helperCheck": {"resources": [f"{self.tmp}/other/*"], "effect": "ask"},
            },
            # A host deny is never changed.
            {
                "kind": "execute",
                "agent": RESTRICTED,
                "tool": "ycc_grep",
                "input": {"pattern": "x", "path": str(outside)},
                "helperCheck": {"resources": approved, "effect": "deny"},
            },
            # Outside a guarded call, or for another agent, nothing changes.
            {
                "kind": "evaluate",
                "agent": SEARCH_AGENT,
                "action": "external_directory",
                "resources": approved,
                "effect": "ask",
                "callID": "unknown",
            },
            {
                "kind": "evaluate",
                "agent": RESTRICTED,
                "action": "external_directory",
                "resources": approved,
                "effect": "ask",
            },
        ]
        same, other, denied, unknown, caller = self.run_cases(cases, sessions={"ses": str(session)})
        self.assertEqual(same["calls"][0]["helperEffect"], "allow")
        self.assertEqual(other["calls"][0]["helperEffect"], "ask")
        self.assertEqual(denied["calls"][0]["helperEffect"], "deny")
        self.assertEqual(unknown["effect"], "ask")
        self.assertEqual(caller["effect"], "ask")

    def test_missing_builtin_search_tool_is_not_replaced(self) -> None:
        observed = self.drive([], builtins=("glob",))
        self.assertEqual([tool["name"] for tool in observed["tools"]], ["ycc_glob"])
        observed = self.drive([], builtins=())
        self.assertEqual(observed["tools"], [])

    def test_guarded_search_delegates_and_filters_for_restricted_agents(self) -> None:
        grep = {
            "output": [
                {"entry": {"path": ".env"}, "line": 1, "offset": 0, "text": "TOKEN=synthetic", "submatches": []},
                {"entry": {"path": "src/app.ts"}, "line": 1, "offset": 0, "text": "value", "submatches": []},
            ],
            "content": "raw",
            "metadata": {"matches": 2, "truncated": False},
        }
        glob = {"output": [{"path": ".env"}, {"path": "src/app.ts"}], "content": "raw", "metadata": {"count": 2}}
        cases = [
            {"kind": "execute", "agent": RESTRICTED, "tool": "ycc_grep", "input": {"pattern": "."}, "result": grep},
            {"kind": "execute", "agent": RESTRICTED, "tool": "ycc_glob", "input": {"pattern": "**/*"}, "result": glob},
        ]
        grep_outcome, glob_outcome = self.run_cases(cases)
        for outcome, tool in ((grep_outcome, "grep"), (glob_outcome, "glob")):
            with self.subTest(tool=tool):
                self.assertTrue(outcome["ok"], outcome)
                (call,) = outcome["calls"]
                self.assertEqual(call["tool"], tool)
                self.assertEqual(call["agent"], SEARCH_AGENT)
                self.assertNotIn("synthetic", json.dumps(outcome["result"]))
                self.assertIn(str(self.work / "src" / "app.ts"), outcome["result"]["content"])
        self.assertEqual(grep_outcome["result"]["metadata"]["matches"], 1)
        self.assertEqual(glob_outcome["result"]["metadata"]["count"], 1)

    def test_guarded_search_rejects_sensitive_roots_before_delegating(self) -> None:
        cases = [
            {"kind": "execute", "agent": RESTRICTED, "tool": "ycc_grep", "input": {"pattern": "T", "path": ".env"}},
            {"kind": "execute", "agent": RESTRICTED, "tool": "ycc_grep", "input": {"pattern": "T", "include": ".env"}},
            {"kind": "execute", "agent": RESTRICTED, "tool": "ycc_glob", "input": {"pattern": "*", "path": ".ssh"}},
        ]
        for outcome in self.run_cases(cases):
            self.assertFalse(outcome["ok"], outcome)
            self.assertIn("ycc sensitive-file guard", outcome["message"])
            self.assertEqual(outcome["calls"], [])

    def test_guarded_search_is_reserved_for_restricted_agents(self) -> None:
        cases = [
            {"kind": "execute", "agent": agent, "tool": tool, "input": {"pattern": "x"}}
            for agent in (OPEN_AGENT, SEARCH_AGENT, "build")
            for tool in ("ycc_grep", "ycc_glob")
        ]
        for outcome in self.run_cases(cases):
            self.assertFalse(outcome["ok"], outcome)
            self.assertEqual(outcome["calls"], [])

    def test_guarded_search_fails_closed_without_a_session_root(self) -> None:
        cases = [
            {"kind": "execute", "agent": RESTRICTED, "tool": "ycc_grep", "input": {"pattern": "x"}, "sessionID": "x"}
        ]
        (outcome,) = self.run_cases(cases, setup_location=False)
        self.assertFalse(outcome["ok"])
        self.assertEqual(outcome["calls"], [])

    def test_guarded_tool_names_are_aliases_in_execute_hooks(self) -> None:
        cases = [
            {"agent": RESTRICTED, "tool": "ycc_grep", "input": {"pattern": "T", "path": ".env"}},
            {"agent": RESTRICTED, "tool": "ycc_glob", "input": {"pattern": "*", "path": ".ssh"}},
            {"agent": RESTRICTED, "tool": "ycc_grep", "input": {"pattern": "value", "path": "src"}},
        ]
        outcomes = self.run_cases(cases)
        self.assertEqual([outcome["ok"] for outcome in outcomes], [False, False, True])
        result = {"output": [{"path": ".env"}, {"path": "src/app.ts"}], "content": "x", "metadata": {"count": 2}}
        (outcome,) = self.run_cases(
            [{"agent": RESTRICTED, "tool": "ycc_glob", "input": {"pattern": "*"}, "result": result}]
        )
        self.assertEqual([entry["path"] for entry in outcome["result"]["output"]], ["src/app.ts"])

    def test_context_hook_shows_guarded_tools_under_builtin_names_for_restricted_agents_only(self) -> None:
        offered = {
            "read": {"description": "read", "input": {}, "tag": "read"},
            "ycc_grep": {"description": "g", "input": {}, "tag": "ycc_grep"},
            "ycc_glob": {"description": "f", "input": {}, "tag": "ycc_glob"},
        }
        both = {**offered, "grep": {"description": "b", "input": {}, "tag": "grep"}}
        restricted, unrestricted, explicit = self.run_cases(
            [
                {"kind": "context", "agent": RESTRICTED, "tools": offered},
                {"kind": "context", "agent": OPEN_AGENT, "tools": offered},
                {"kind": "context", "agent": RESTRICTED, "tools": both},
            ]
        )
        self.assertEqual(restricted["tools"], ["glob", "grep", "read"])
        self.assertEqual(restricted["identity"], {"read": "read", "grep": "ycc_grep", "glob": "ycc_glob"})
        # Agents outside the restricted set are never offered the guarded tools.
        self.assertEqual(unrestricted["tools"], ["read"])
        # A built-in the host still offers keeps its own name; nothing is shadowed.
        self.assertEqual(explicit["identity"]["grep"], "grep")
        self.assertEqual(explicit["identity"]["glob"], "ycc_glob")
        self.assertEqual(explicit["identity"]["ycc_grep"], "ycc_grep")


if __name__ == "__main__":
    unittest.main(verbosity=2)
