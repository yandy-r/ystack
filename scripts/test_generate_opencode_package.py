#!/usr/bin/env python3
"""Consumer-boundary tests for the opencode npm package generator (YAN-1143).

Generates once, then exercises the package the way a consumer does: the
manifest npm reads, a relocated copy, and the V2 plugin adapter driven with a
fake context under node.
"""

from __future__ import annotations

import contextlib
import io
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from typing import Any
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_opencode_package as generator  # noqa: E402
from package_model import REPO_ROOT, PackageModel, load_package_model  # noqa: E402

PACKAGE = Path("packages/opencode/ycc-opencode")
NODE = shutil.which("node")

# Drives the real adapter with a fake V2 context, then prints JSON observations.
DRIVER = r"""
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
const [root, preSkill, preAgent, preMcp, systemText] = process.argv.slice(2);
const plugin = (await import(pathToFileURL(root + "/index.js").href)).default;
const skills = new Map(), agents = new Map(), mcp = new Map(), commands = new Map(), prompts = [], hooks = [];
if (preSkill) skills.set(preSkill, { id: preSkill, preexisting: true });
if (preAgent) agents.set(preAgent, { id: preAgent, preexisting: true });
if (preMcp) mcp.set(preMcp, { preexisting: true });
const ctx = {
  location: { directory: process.cwd(), project: { directory: process.cwd(), canonical: process.cwd() } },
  tool: { hook: async () => {}, transform: async (cb) => cb({ get: () => undefined }) },
  permission: { hook: async () => {} },
  skill: { transform: async (cb) => cb({ get: (id) => skills.get(id), add: (s) => skills.set(s.id, s) }) },
  agent: { transform: async (cb) => cb({
    get: (id) => agents.get(id),
    update: (id, fn) => { const record = agents.get(id) ?? { id }; fn(record); agents.set(id, record); } }) },
  command: { transform: async (cb) => cb({ add: (c) => commands.set(c.name, c) }) },
  mcp: { transform: async (cb) => cb({ get: (n) => mcp.get(n), set: (n, c) => mcp.set(n, c) }) },
  session: {
    hook: async (name, cb) => hooks.push({ name, cb }),
    get: async () => ({ agent: "build" }),
    switchAgent: async () => {}, switchModel: async () => {},
    prompt: async (input) => { prompts.push(input); },
  },
};
const cleanup = await plugin.setup(ctx);
const command = commands.get("ycc:plan");
await command.execute({ sessionID: "ses_test", prompt: { text: "alpha beta" }, delivery: "immediate" });
const event = { system: systemText ? [{ type: "text", text: systemText }] : [], tools: {} };
for (const hook of hooks) await hook.cb(event);
const renderedRoot = dirname(dirname(dirname([...skills.values()].find((s) => !s.preexisting).path)));
const forgeText = readFileSync(join(renderedRoot, "shared/references/forge-detection.md"), "utf8");
const sourceLine = forgeText.split("\n").map((line) => line.trim())
  .find((line) => line.startsWith("source ") && line.includes("shared/scripts/lib/forge.sh"));
const shell = spawnSync("bash", ["-c", sourceLine + '\nforge_host_from_url https://example.test/owner/repo.git'], {
  cwd: "/tmp", encoding: "utf8",
});
console.log(JSON.stringify({
  id: plugin.id,
  skills: [...skills.values()],
  agents: [...agents.values()],
  mcp: Object.fromEntries(mcp),
  commandNames: [...commands.keys()],
  hooks: hooks.map((h) => h.name),
  prompts,
  system: event.system,
  renderedRoot, shell: { status: shell.status, stdout: shell.stdout, stderr: shell.stderr },
}));
await cleanup();
"""

# Sets the adapter up twice (two state rebuilds), appends host rules to the
# registered records the way opencode.config.agent does after the package
# transform, then replays permission.evaluate, tool execute.before, and
# session context events through the latest setup's hooks. The fake tool
# inventory carries the built-ins' permission names (write/patch -> edit).
# A plain case is one evaluate event whose `effect` is the one the host's
# merged rules produced (an `external_check` passes the allow a host-wide
# external_directory allow gives). The fake host also implements what the
# floor calls itself: session.create/get/remove and permission.assert, which
# evaluates like core/src/permission.ts evaluateInput (agent rules, host rules
# appended, then the session's; any deny wins without hooks; the project's
# saved approvals are appended as allow rules; the evaluate hooks run; deny
# throws, ask records a prompt the user rejects). `saved` (payload) holds the
# project's saved external_directory approvals before setup; `save`/`unsave`
# cases add or remove them; `host` cases make session.create or
# permission.assert fail, or (`unhooked`) make assert skip the evaluate hooks
# and leave an ask pending until permission.reply settles it; `event` cases
# publish a host bus event to every subscriber; `storage` (payload) seeds
# plugin storage before setup. `preHooks: "allow-all"` registers another
# plugin's evaluate hook ahead of the package that turns every ask into
# allow; `preHooks: "slow"` registers one that holds every probe evaluation
# past the package's probe timeout; `copies: 2` loads a second copy of the
# package module after the first. Output waits for every assert to settle.
FLOOR_DRIVER = r"""
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
const [root] = process.argv.slice(2);
const { hostRules, inventory, sessions, cases, saved: initialSaved, storage: initialStorage, preHooks, copies } =
  JSON.parse(readFileSync(0, "utf8"));
const plugins = [];
for (let copy = 0; copy < (copies ?? 1); copy++) {
  const dir = copy === 0 ? root : `${root}-copy${copy}`;
  plugins.push((await import(pathToFileURL(dir + "/index.js").href)).default);
}
const storage = new Map(Object.entries(initialStorage ?? {})), subscribers = new Set();
const saved = [...(initialSaved ?? [])], children = new Map(), created = [], prompts = [];
const failing = new Set(), pending = new Map(), replies = [], inflight = new Set();
let current, requests = 0;
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
// core/src/util/wildcard.ts match(), as the package ports it.
function match(input, pattern) {
  let escaped = pattern.replaceAll("\\", "/").replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/\*/g, ".*").replace(/\?/g, ".");
  if (escaped.endsWith(" .*")) escaped = escaped.slice(0, -3) + "( .*)?";
  return new RegExp("^" + escaped + "$", "s").test(String(input).replaceAll("\\", "/"));
}
const evaluate = (rules, action, resource) =>
  rules.findLast((rule) => match(action, rule.action) && match(resource, rule.resource))?.effect ?? "ask";
function subscriber(options) {
  return { [Symbol.asyncIterator]() {
    const queue = [];
    let wake, done = false;
    const sub = { push(event) { queue.push(event); wake?.(); } };
    const stop = () => { done = true; subscribers.delete(sub); wake?.(); };
    subscribers.add(sub);
    options?.signal?.addEventListener("abort", stop, { once: true });
    return {
      async next() {
        while (!queue.length && !done) await new Promise((resolve) => (wake = resolve));
        return queue.length ? { done: false, value: queue.shift() } : { done: true, value: undefined };
      },
      async return() { stop(); return { done: true, value: undefined }; },
    };
  } };
}
const pluginStorage = {
  get: async (key) => { await tick(); return structuredClone(storage.get(key)); },
  set: async (key, value) => { await tick(); storage.set(key, structuredClone(value)); },
  remove: async (key) => { await tick(); storage.delete(key); },
  scan: async ({ prefix, after, limit = 2 }) => {
    await tick();
    const keys = [...storage.keys()]
      .filter((key) => key.startsWith(prefix) && (after === undefined || key > after)).sort();
    const entries = keys.slice(0, limit).map((key) => ({ key, value: structuredClone(storage.get(key)) }));
    return keys.length > limit ? { entries, next: entries.at(-1).key } : { entries };
  },
};
function sessionInfo(sessionID) {
  if (children.has(sessionID)) return children.get(sessionID);
  if (!(sessionID in sessions)) throw new Error(`session not found: ${sessionID}`);
  return { id: sessionID, agent: sessions[sessionID] ?? undefined, permissions: [] };
}
const hostSession = {
  get: async ({ sessionID }) => {
    await tick();
    const info = sessionInfo(sessionID);
    return { data: { ...structuredClone(info), location: { directory: process.cwd() } } };
  },
  create: async (input) => {
    await tick();
    if (failing.has("create")) throw new Error("session create failed");
    sessionInfo(input.parentID);
    const info = { id: `ses_child_${created.length}`, parentID: input.parentID, agent: input.agent,
      title: input.title, permissions: structuredClone(input.permissions ?? []) };
    children.set(info.id, info);
    created.push(structuredClone(info));
    return { data: structuredClone(info) };
  },
  remove: async ({ sessionID }) => {
    await tick();
    if (!children.delete(sessionID)) throw new Error(`session not found: ${sessionID}`);
  },
};
class BlockedError extends Error {}
async function assert(input) {
  const run = assertNow(input);
  inflight.add(run);
  try {
    return await run;
  } finally {
    inflight.delete(run);
  }
}
async function assertNow(input) {
  await tick();
  if (failing.has("assert")) throw new Error("permission service unavailable");
  const session = sessionInfo(input.sessionID);
  const agent = input.agent ?? session.agent;
  const rules = [...(current.agents.get(agent)?.permissions ?? hostRules), ...session.permissions];
  if (input.resources.some((resource) => evaluate(rules, input.action, resource) === "deny")) {
    throw new BlockedError("blocked by rules");
  }
  const all = [...rules, ...saved.map((resource) => ({ action: "external_directory", resource, effect: "allow" }))];
  const effects = input.resources.map((resource) => evaluate(all, input.action, resource));
  const event = { sessionID: input.sessionID, agent: input.agent, action: input.action, resources: input.resources,
    metadata: input.metadata ?? {}, source: input.source, effect: effects.includes("ask") ? "ask" : "allow" };
  if (failing.has("unhooked")) {
    // No plugin hook runs (e.g. the package was unloaded): an ask waits for a reply.
    if (event.effect === "allow") return;
    const id = `per_${requests++}`;
    return new Promise((resolve, reject) => {
      pending.set(id, { sessionID: input.sessionID, settle: (decision) =>
        (decision === "reject" ? reject(new Error("rejected by the user")) : resolve()) });
    });
  }
  for (const cb of current.hooks.evaluate) await cb(event);
  if (event.effect === "deny") throw new BlockedError(event.message ?? "blocked");
  if (event.effect === "ask") {
    prompts.push({ sessionID: input.sessionID, action: input.action, resources: input.resources });
    throw new Error("rejected by the user");
  }
}
async function setup() {
  const agents = new Map(), hooks = { evaluate: [], "execute.before": [], context: [] };
  if (preHooks === "allow-all") {
    hooks.evaluate.push((event) => {
      if (event.effect === "ask") event.effect = "allow";
    });
  }
  if (preHooks === "slow") {
    hooks.evaluate.push(async (event) => {
      if (event.metadata?.yccSavedApprovalProbe) await new Promise((resolve) => setTimeout(resolve, 5500));
    });
  }
  const add = (name, cb) => { if (name in hooks) hooks[name].push(cb); };
  const ctx = {
    location: { directory: process.cwd(),
      project: { id: "prj", directory: process.cwd(), canonical: process.cwd() } },
    event: { subscribe: subscriber },
    storage: pluginStorage,
    tool: {
      hook: async (name, cb) => add(name, cb),
      transform: async (cb) => cb({ get: () => undefined }),
      list: async () => inventory.map((tool) => ({ ...tool, execute: async () => ({}) })),
    },
    permission: {
      hook: async (name, cb) => add(name, cb),
      assert,
      // session.permission.list/reply: inputs { sessionID } and
      // { sessionID, requestID, decision }; list resolves the request array.
      list: async ({ sessionID }) => {
        await tick();
        sessionInfo(sessionID);
        return [...pending].filter(([, item]) => item.sessionID === sessionID)
          .map(([id, item]) => ({ id, sessionID: item.sessionID, action: "external_directory" }));
      },
      reply: async ({ sessionID, requestID, decision }) => {
        await tick();
        const request = pending.get(requestID);
        if (!request || request.sessionID !== sessionID || !["once", "always", "reject"].includes(decision)) {
          throw new Error(`invalid reply: ${JSON.stringify({ sessionID, requestID, decision })}`);
        }
        pending.delete(requestID);
        replies.push({ sessionID, requestID, decision });
        request.settle(decision);
      },
    },
    skill: { transform: async (cb) => cb({ get: () => undefined, add: () => {} }) },
    agent: { transform: async (cb) => cb({
      get: (id) => agents.get(id),
      update: (id, fn) => { const record = agents.get(id) ?? { id }; fn(record); agents.set(id, record); } }) },
    command: { transform: async (cb) => cb({ add: () => {} }) },
    mcp: { transform: async (cb) => cb({ get: () => undefined, set: () => {} }) },
    session: { hook: async (name, cb) => add(name, cb), ...hostSession },
  };
  const cleanups = [];
  for (const plugin of plugins) cleanups.push(await plugin.setup(ctx));
  // opencode.config.agent pushes host rules into every existing agent in place.
  for (const record of agents.values()) record.permissions?.push(...structuredClone(hostRules));
  return { agents, hooks, cleanup: async () => { for (const cleanup of cleanups) await cleanup(); } };
}
const settle = () => new Promise((resolve) => setTimeout(resolve, 30));
const first = await setup();
const second = await setup();
current = second;
await settle();
const results = [];
for (const item of cases) {
  const sessionID = item.sessionID ?? "ses";
  try {
    if (item.kind === "event") {
      for (const event of item.events ?? [item]) {
        for (const sub of subscribers) sub.push({ id: "evt", created: 0, type: event.type, data: event.data });
      }
      await settle();
      results.push({ ok: true });
    } else if (item.kind === "save" || item.kind === "unsave") {
      for (const pattern of item.patterns) {
        const index = saved.indexOf(pattern);
        if (item.kind === "save" && index === -1) saved.push(pattern);
        if (item.kind === "unsave" && index !== -1) saved.splice(index, 1);
      }
      results.push({ ok: true });
    } else if (item.kind === "host") {
      failing.clear();
      for (const name of item.fail) failing.add(name);
      results.push({ ok: true });
    } else if (item.kind === "execute") {
      const event = { sessionID, messageID: "msg", id: "call", agent: item.agent, tool: item.tool,
        input: item.input ?? {} };
      for (const cb of current.hooks["execute.before"]) await cb(event);
      results.push({ ok: true });
    } else if (item.kind === "context") {
      // `renamed` replays a guard that already showed ycc_* as grep/glob
      // (file-copy guard loaded before this package).
      const tag = (name) => (item.renamed && name in item.renamed ? item.renamed[name] : name);
      const event = { sessionID, agent: item.agent, system: [], messages: [], options: {},
        tools: Object.fromEntries(item.tools.map((name) => [name, { description: name, input: {}, tag: tag(name) }])) };
      for (const cb of current.hooks.context) await cb(event);
      results.push({ ok: true, tools: Object.fromEntries(Object.entries(event.tools).map(([k, v]) => [k, v.tag])) });
    } else {
      const event = { sessionID, action: item.action, resources: item.resources, effect: item.effect };
      if (item.agent !== null) event.agent = item.agent;
      for (const cb of current.hooks.evaluate) await cb(event);
      results.push({ ok: true, effect: event.effect, message: event.message ?? null });
    }
  } catch (error) {
    results.push({ ok: false, message: String(error?.message ?? error) });
  }
}
while (inflight.size) await Promise.allSettled([...inflight]);
const count = (state, id) => state.agents.get(id).permissions.length;
console.log(JSON.stringify({
  counts: { first: count(first, "pr-comment-fixer"), second: count(second, "pr-comment-fixer") },
  results,
  // Child sessions the package created, those still present, and every prompt
  // raised in one of them.
  created,
  leftover: [...children.keys()],
  childPrompts: prompts.filter((prompt) => created.some((info) => info.id === prompt.sessionID)),
  pending: [...pending.keys()],
  replies,
  storage: Object.fromEntries(storage),
}));
for (const state of [first, second]) await state.cleanup();
"""

# Built-in tool names and the permission action each is gated by.
FAKE_INVENTORY = [
    {"name": name, "options": {"codemode": False, **({"permission": permission} if permission else {})}}
    for name, permission in (
        ("read", None),
        ("edit", "edit"),
        ("write", "edit"),
        ("patch", "edit"),
        ("shell", None),
        ("grep", None),
        ("glob", None),
        ("webfetch", None),
        ("websearch", None),
        ("question", None),
        ("subagent", None),
        ("ycc_grep", None),
        ("ycc_glob", None),
        ("third_party_tool", None),
    )
]


def run_driver(root: Path, *extra: str, env: dict[str, str] | None = None) -> dict:
    assert NODE is not None
    script = root.parent / f"driver-{abs(hash(extra))}.mjs"
    script.write_text(DRIVER, encoding="utf-8")
    result = subprocess.run(
        [NODE, str(script), str(root), *(extra + ("",) * (4 - len(extra)))],
        capture_output=True,
        text=True,
        timeout=60,
        env=env,
        check=False,
    )
    if result.returncode:
        raise AssertionError(result.stderr or result.stdout)
    return json.loads(result.stdout.strip().splitlines()[-1])


FIXER = "pr-comment-fixer"


def external_check(agent: str, resources: list[str], session: str = "ses") -> dict[str, Any]:
    """An external_directory check the host's merged rules allow."""
    return {
        "agent": agent,
        "action": "external_directory",
        "resources": resources,
        "effect": "allow",
        "sessionID": session,
    }


def external_asked(request: str, resources: list[str], save: list[str], session: str = "ses") -> dict[str, Any]:
    """The host's permission.asked event for one external_directory request."""
    data = {"id": request, "sessionID": session, "action": "external_directory", "resources": resources, "save": save}
    return {"kind": "event", "type": "permission.asked", "data": data}


def external_replied(request: str, reply: str, session: str = "ses") -> dict[str, Any]:
    """The host's permission.replied event."""
    data = {"sessionID": session, "requestID": request, "reply": reply}
    return {"kind": "event", "type": "permission.replied", "data": data}


def host_saved(kind: str, *patterns: str) -> dict[str, Any]:
    """Add (`save`) or remove (`unsave`) saved approvals of the project on the host."""
    return {"kind": kind, "patterns": list(patterns)}


class OpencodeNpmPackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temp = tempfile.TemporaryDirectory()
        cls.dest = Path(cls._temp.name) / "repo"
        cls.model = load_package_model()
        cls.inventory = generator.write_all(cls.dest)
        cls.root = cls.dest / PACKAGE
        cls.manifest = json.loads((cls.root / "package.json").read_text(encoding="utf-8"))
        cls.registration = json.loads((cls.root / "registration.json").read_text(encoding="utf-8"))

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temp.cleanup()

    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)

    # -- manifest npm consumes ------------------------------------------------

    def test_manifest_matches_canonical_version_and_engine_floor(self) -> None:
        canonical = json.loads((REPO_ROOT / self.model.version_source).read_text(encoding="utf-8"))
        self.assertEqual(self.manifest["name"], "@yandy-r/ycc-opencode")
        self.assertEqual(self.manifest["version"], canonical["version"])
        self.assertEqual(self.manifest["engines"], {"opencode": ">=2.0.30"})
        self.assertEqual(self.manifest["type"], "module")
        self.assertEqual(self.manifest["main"], "./index.js")
        self.assertEqual(self.manifest["exports"], {".": "./index.js"})
        self.assertEqual(
            self.manifest["repository"],
            {
                "type": "git",
                "url": "git+https://github.com/yandy-r/ystack.git",
                "directory": "packages/opencode/ycc-opencode",
            },
        )

    def test_every_published_file_exists_and_nothing_private_ships(self) -> None:
        for entry in self.manifest["files"]:
            self.assertTrue((self.root / entry).exists(), entry)
        self.assertNotIn("private", self.manifest)
        self.assertNotIn("scripts", self.manifest)

    @unittest.skipIf(NODE is None, "node is required")
    def test_npm_pack_is_self_contained(self) -> None:
        npm = shutil.which("npm")
        if npm is None:
            self.skipTest("npm is required")
        result = subprocess.run(
            [npm, "pack", "--dry-run", "--json", "--ignore-scripts"],
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        start = min(index for char in "[{" if (index := result.stdout.find(char)) >= 0)
        payload = json.loads(result.stdout[start:])
        if isinstance(payload, list):
            entry = payload[0]
        else:
            entry = payload if "files" in payload else next(iter(payload.values()))
        paths = {item["path"] for item in entry["files"]}
        self.assertLessEqual({"index.js", "registration.json", "package.json", "AGENTS.md"}, paths)
        self.assertTrue(any(path.startswith("shared/scripts/") for path in paths))

    # -- component classes and relocatable assets -----------------------------

    def test_registration_covers_every_component_class(self) -> None:
        source_skills = {p.parent.name for p in (REPO_ROOT / "ycc/skills").glob("*/SKILL.md")}
        source_agents = {p.stem for p in (REPO_ROOT / "ycc/agents").glob("*.md")}
        self.assertEqual({s["id"] for s in self.registration["skills"]}, source_skills)
        self.assertEqual({a["id"] for a in self.registration["agents"]}, source_agents)
        self.assertEqual({c["name"] for c in self.registration["commands"]}, {f"ycc:{name}" for name in source_skills})
        self.assertEqual(self.registration["context"], "AGENTS.md")
        mcp_source = json.loads((REPO_ROOT / "mcp-configs/mcp.json").read_text(encoding="utf-8"))["mcpServers"]
        self.assertEqual(set(self.registration["mcp"]), set(mcp_source))
        for agent in self.registration["agents"]:
            self.assertRegex(agent["model"], r"^[^/]+/.+")
            self.assertEqual(agent["mode"], "subagent")

    def test_no_install_root_or_home_path_is_baked_for_shipped_units(self) -> None:
        baked = re.compile(r"(~|\$\{HOME\}|\$HOME)/\.config/opencode/(skills|shared|agents|commands)/")
        offenders = [
            str(path.relative_to(self.root))
            for path in self.root.rglob("*")
            if path.is_file() and baked.search(path.read_text(encoding="utf-8", errors="ignore"))
        ]
        # Verbatim target-matrix documents every deployment target literally.
        self.assertEqual(
            [o for o in offenders if o != "shared/references/target-capability-matrix.md"],
            [],
        )
        self.assertNotIn(str(REPO_ROOT), (self.root / "index.js").read_text(encoding="utf-8"))
        self.assertNotIn(str(REPO_ROOT), (self.root / "registration.json").read_text(encoding="utf-8"))

    def test_relative_shared_references_resolve_to_real_files_after_relocation(self) -> None:
        moved = self.tmp / "elsewhere" / "node_modules" / "@yandy-r" / "ycc-opencode"
        shutil.copytree(self.root, moved)
        pattern = re.compile(r"(?<![\w./-])((?:\.\./)+(?:shared|skills|agents)/[\w./-]+)")
        checked = 0
        for path in moved.rglob("*.md"):
            if path.name == "README.md":
                continue
            for match in pattern.finditer(path.read_text(encoding="utf-8")):
                ref = match.group(1).split("#")[0].rstrip(".,)`")
                self.assertTrue((path.parent / ref).exists(), f"{path.relative_to(moved)}: {ref}")
                checked += 1
        self.assertGreater(checked, 0)
        script = (moved / "skills/git-workflow/scripts/create-pr.sh").read_text(encoding="utf-8")
        self.assertIn('FORGE_LIB="${SCRIPT_DIR}/../../../shared/scripts/lib/forge.sh"', script)
        self.assertNotIn("|| FORGE_LIB=", script)

    def test_concrete_legacy_bundle_references_are_relocated(self) -> None:
        cases = (
            (
                "shared/references/forge-detection.md",
                "{{package-root}}/skills/git-cleanup/references/host-detection.md",
            ),
            ("skills/backport/SKILL.md", "{{package-root}}/agents/backport-conflict-resolver.md"),
            ("skills/prp-plan/SKILL.md", "{{package-root}}/shared/references/worktree-strategy.md"),
            ("skills/blueprint/references/bootstrap-mapping.md", "{{package-root}}/skills/init/SKILL.md"),
        )
        for rel, expected in cases:
            with self.subTest(rel=rel):
                self.assertIn(expected, (self.root / rel).read_text(encoding="utf-8"))
        legacy = re.compile(r"\.opencode-plugin/(?:skills|agents)/")
        preserved = generator.verbatim_outputs(__import__("generate_opencode_skills")) | {
            "skills/bundle-author/SKILL.md",
            "skills/bundle-author/references/surface-map.md",
            "skills/bundle-author/references/when-not-to-scaffold.md",
            "skills/bundle-author/references/templates/agent-template.md",
            "skills/bundle-author/references/templates/skill-template.md",
            "skills/bundle-author/scripts/scaffold-skill.sh",
        }
        offenders = [
            str(path.relative_to(self.root))
            for path in self.root.rglob("*")
            if path.is_file()
            and str(path.relative_to(self.root)) not in preserved
            and legacy.search(path.read_text(encoding="utf-8", errors="ignore"))
        ]
        self.assertEqual(offenders, [])

    # -- the adapter, driven as opencode drives it ----------------------------

    @unittest.skipIf(NODE is None, "node is required")
    def test_relocated_package_registers_all_component_classes_and_runs_commands(self) -> None:
        moved = self.tmp / "moved" / "ycc-opencode"
        shutil.copytree(self.root, moved)
        observed = run_driver(moved)
        self.assertEqual(len(observed["skills"]), len(self.registration["skills"]))
        # The guard adds its hidden internal search agent beside the packaged agents.
        self.assertEqual(
            {agent["id"] for agent in observed["agents"]},
            {agent["id"] for agent in self.registration["agents"]} | {"ycc-sensitive-search"},
        )
        self.assertEqual(len(observed["commandNames"]), len(self.registration["commands"]))
        self.assertEqual(set(observed["mcp"]), set(self.registration["mcp"]))
        # The package carries the same sensitive-file guard as the file-copy install.
        for rel in ("index.js", "policy.json", "package.json"):
            with self.subTest(guard_file=rel):
                self.assertEqual(
                    (moved / "ycc-sensitive-guard" / rel).read_bytes(),
                    (REPO_ROOT / ".opencode-plugin" / "ycc-sensitive-guard" / rel).read_bytes(),
                )
        for skill in observed["skills"]:
            self.assertEqual(Path(skill["path"]), Path(observed["renderedRoot"]) / "skills" / skill["id"] / "SKILL.md")
            self.assertNotIn("{{package-root}}", skill["content"])
            self.assertFalse(skill["content"].startswith("---"))
        self.assertEqual(observed["shell"]["status"], 0, observed["shell"]["stderr"])
        self.assertEqual(observed["shell"]["stdout"].strip(), "example.test")
        self.assertIn("ycc:init", observed["commandNames"])
        self.assertNotIn("init", observed["commandNames"])
        agent = next(a for a in observed["agents"] if a["id"] == "architect")
        self.assertEqual(agent["mode"], "subagent")
        self.assertIn("permissions", agent)
        self.assertEqual(set(agent["model"]), {"id", "providerID"})
        self.assertNotIn("{{package-root}}", agent["system"])
        # The command forwards the template with the invocation text expanded.
        (prompt,) = observed["prompts"]
        self.assertEqual(prompt["sessionID"], "ses_test")
        self.assertIn("load the `plan` skill", prompt["text"])
        self.assertTrue(prompt["text"].rstrip().endswith("alpha beta"))
        self.assertNotIn("$ARGUMENTS", prompt["text"])
        # Instructions arrive as a typed SystemPart, never a bare string.
        self.assertEqual([part["type"] for part in observed["system"]], ["text"])
        self.assertEqual(observed["system"][0]["text"], (moved / "AGENTS.md").read_text(encoding="utf-8"))

    @unittest.skipIf(NODE is None, "node is required")
    def test_existing_registrations_win_and_instructions_are_not_duplicated(self) -> None:
        moved = self.tmp / "coexist" / "ycc-opencode"
        shutil.copytree(self.root, moved)
        instructions = (moved / "AGENTS.md").read_text(encoding="utf-8")
        observed = run_driver(moved, "plan", "architect", "github", instructions)
        plan = next(s for s in observed["skills"] if s["id"] == "plan")
        architect = next(a for a in observed["agents"] if a["id"] == "architect")
        self.assertTrue(plan.get("preexisting"))
        self.assertTrue(architect.get("preexisting"))
        self.assertTrue(observed["mcp"]["github"].get("preexisting"))
        self.assertEqual(len(observed["skills"]), len(self.registration["skills"]))
        # Same text already present: the hook pushes nothing.
        self.assertEqual(len(observed["system"]), 1)

    @unittest.skipIf(NODE is None, "node is required")
    def test_mcp_environment_placeholders_resolve_at_setup_not_generation(self) -> None:
        stored = json.dumps(self.registration["mcp"])
        self.assertIn("{env:", stored)
        self.assertNotIn("sk-", stored)
        moved = self.tmp / "env" / "ycc-opencode"
        shutil.copytree(self.root, moved)
        env = {"PATH": "/usr/bin:/bin", "XERO_CLIENT_ID": "id-from-env", "XERO_CLIENT_SECRET": "secret-from-env"}
        observed = run_driver(moved, env=env)
        self.assertEqual(observed["mcp"]["xero"]["environment"]["XERO_CLIENT_ID"], "id-from-env")

    @unittest.skipIf(NODE is None, "node is required")
    def test_asset_paths_cannot_escape_the_package(self) -> None:
        moved = self.tmp / "escape" / "ycc-opencode"
        shutil.copytree(self.root, moved)
        registration = json.loads((moved / "registration.json").read_text(encoding="utf-8"))
        registration["skills"][0]["path"] = "../outside/SKILL.md"
        (moved / "registration.json").write_text(json.dumps(registration), encoding="utf-8")
        with self.assertRaisesRegex(AssertionError, "escapes the package root"):
            run_driver(moved)

    def run_floor(
        self,
        name: str,
        host: list[dict[str, str]],
        cases: list[dict[str, Any]],
        saved: list[str] | None = None,
        storage: dict[str, Any] | None = None,
        pre_hooks: str | None = None,
        copies: int = 1,
    ) -> dict[str, Any]:
        """Drive the package's floor hooks with host rules appended after setup.

        `saved` are the project's saved approvals and `storage` the plugin
        storage, both as they are before the package is set up. `pre_hooks`
        and `copies` are FLOOR_DRIVER's `preHooks` and `copies`.
        """
        assert NODE is not None
        moved = self.tmp / name / "ycc-opencode"
        shutil.copytree(self.root, moved)
        for copy in range(1, copies):
            shutil.copytree(self.root, moved.parent / f"ycc-opencode-copy{copy}")
        script = moved.parent / "floor.mjs"
        script.write_text(FLOOR_DRIVER, encoding="utf-8")
        payload = {
            "hostRules": host,
            "inventory": FAKE_INVENTORY,
            "sessions": {"ses": None, "ses-fixer": "pr-comment-fixer", "ses-finder": "code-finder"},
            "cases": cases,
            "saved": saved or [],
            "storage": storage or {},
            "preHooks": pre_hooks,
            "copies": copies,
        }
        result = subprocess.run(
            [NODE, str(script), str(moved)],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        observed: dict[str, Any] = json.loads(result.stdout.strip().splitlines()[-1])
        return observed

    @unittest.skipIf(NODE is None, "node is required")
    def test_host_permission_rules_cannot_loosen_restricted_agents(self) -> None:
        restricted_agents = json.loads((self.root / "ycc-sensitive-guard/policy.json").read_text(encoding="utf-8"))[
            "restricted_agents"
        ]
        host = [
            {"action": action, "resource": "*", "effect": "allow"}
            for action in ("read", "edit", "shell", "webfetch", "grep", "glob")
        ]

        def case(
            agent: str | None, action: str, resources: list[str], effect: str = "allow", **extra: str
        ) -> dict[str, Any]:
            return {"agent": agent, "action": action, "resources": resources, "effect": effect, **extra}

        fixer = "pr-comment-fixer"
        expected = [
            # Packaged denies win over host allows.
            *[(case(agent, "read", [".env"]), "deny") for agent in restricted_agents],
            (case(fixer, "edit", ["config/.env.production"]), "deny"),
            (case(fixer, "read", ["keys/server.pem"]), "deny"),
            (case(fixer, "read", ["src/app.ts", ".env"]), "deny"),
            (case(fixer, "shell", ["cat .env"]), "deny"),
            (case(fixer, "webfetch", ["https://example.test"]), "deny"),
            # The unguarded built-in search stays outside a restricted agent's own rules.
            (case(fixer, "grep", ["TOKEN"]), "deny"),
            # Resources the packaged rules do not deny keep the host's effect.
            (case(fixer, "read", ["src/app.ts"]), "allow"),
            (case(fixer, "read", ["src/app.ts"], "ask"), "ask"),
            (case(fixer, "read", [".env.example"]), "allow"),
            (case(fixer, "ycc_grep", ["TOKEN"]), "allow"),
            (case(fixer, "shell", ["pytest -q"]), "allow"),
            (case(fixer, "shell", ['python3 -c "print(1)"']), "deny"),
            # A host allow for a restricted agent's `ask` is raised to a prompt.
            (case(fixer, "external_directory", ["/elsewhere/*"]), "ask"),
            # A check without an agent is judged by the session's agent.
            (case(None, "read", [".env"], sessionID="ses-fixer"), "deny"),
            (case(None, "read", [".env"], sessionID="ses-finder"), "allow"),
            # Unrestricted agents are untouched.
            (case("code-finder", "read", [".env"]), "allow"),
            (case("code-finder", "shell", ["cat .env"]), "allow"),
            (case("build", "read", [".env"], "ask"), "ask"),
        ]
        observed = self.run_floor("floor", host, [item for item, _ in expected])
        for (item, effect), outcome in zip(expected, observed["results"], strict=True):
            with self.subTest(**{k: str(v) for k, v in item.items()}):
                self.assertEqual(outcome["effect"], effect)
                if effect == "deny" and item["effect"] != "deny":
                    self.assertIn("ycc", outcome["message"])
                elif effect != "deny":
                    self.assertIsNone(outcome["message"])
        # Each setup registers its own copy: host rules never accumulate in the
        # packaged registration across state rebuilds.
        packaged = next(a for a in self.registration["agents"] if a["id"] == fixer)["permissions"]
        self.assertEqual(observed["counts"], {"first": len(packaged) + len(host), "second": len(packaged) + len(host)})

    def run_external(
        self,
        name: str,
        steps: list[tuple[dict[str, Any], str | None]],
        saved: list[str] | None = None,
        pre_hooks: str | None = None,
        copies: int = 1,
    ) -> dict[str, Any]:
        """Replay external-directory checks under a host-wide allow.

        Every saved-approval probe must leave no session or request behind and never prompt.
        """
        host = [{"action": "external_directory", "resource": "*", "effect": "allow"}]
        observed = self.run_floor(
            name, host, [step for step, _ in steps], saved=saved, pre_hooks=pre_hooks, copies=copies
        )
        for index, ((step, effect), outcome) in enumerate(zip(steps, observed["results"], strict=True)):
            with self.subTest(index=index, step=json.dumps(step)):
                self.assertTrue(outcome["ok"], outcome)
                if effect is not None:
                    self.assertEqual(outcome["effect"], effect)
                    self.assertIsNone(outcome["message"])
        self.assertEqual(observed["leftover"], [])
        self.assertEqual(observed["childPrompts"], [])
        self.assertEqual(observed["pending"], [])
        return observed

    @unittest.skipIf(NODE is None, "node is required")
    def test_removed_saved_approval_prompts_restricted_agents_again(self) -> None:
        # The user answers "always": the host saves /elsewhere/* and publishes
        # the request and the reply. Removing the saved approval in OpenCode
        # must take effect for the restricted agent at once.
        self.run_external(
            "unsaved",
            [
                (external_asked("per_1", ["/elsewhere/a/*"], ["/elsewhere/*"]), None),
                (host_saved("save", "/elsewhere/*"), None),
                (external_replied("per_1", "always"), None),
                (external_check(FIXER, ["/elsewhere/a/*"]), "allow"),
                (host_saved("unsave", "/elsewhere/*"), None),
                (external_check(FIXER, ["/elsewhere/a/*"]), "ask"),
                (external_check(FIXER, ["/elsewhere/b/*"]), "ask"),
            ],
        )

    @unittest.skipIf(NODE is None, "node is required")
    def test_host_external_directory_allow_alone_prompts_only_restricted_agents(self) -> None:
        observed = self.run_external(
            "config-allow",
            [
                (external_check(FIXER, ["/elsewhere/a/*"]), "ask"),
                (external_check("code-finder", ["/elsewhere/a/*"]), "allow"),
                # A check without an agent is judged by the session's agent.
                ({**external_check(FIXER, ["/elsewhere/a/*"], "ses-fixer"), "agent": None}, "ask"),
                ({**external_check(FIXER, ["/elsewhere/a/*"], "ses-finder"), "agent": None}, "allow"),
            ],
        )
        # Only restricted agents' checks probe, in a child of the asking session.
        self.assertEqual(
            [(info["parentID"], info["agent"]) for info in observed["created"]],
            [("ses", FIXER), ("ses-fixer", FIXER)],
        )
        for info in observed["created"]:
            self.assertEqual(info["permissions"], [{"action": "external_directory", "resource": "*", "effect": "ask"}])

    @unittest.skipIf(NODE is None, "node is required")
    def test_saved_approval_from_before_setup_is_honoured(self) -> None:
        # Saved while the package was not loaded: no event was ever seen.
        self.run_external(
            "saved-before",
            [
                (external_check(FIXER, ["/elsewhere/a/*"]), "allow"),
                (external_check("review-fixer", ["/elsewhere/b/*"]), "allow"),
                (external_check(FIXER, ["/other/*"]), "ask"),
            ],
            saved=["/elsewhere/*"],
        )

    @unittest.skipIf(NODE is None, "node is required")
    def test_every_asked_resource_must_be_covered(self) -> None:
        self.run_external(
            "mixed",
            [
                (external_check(FIXER, ["/elsewhere/a/*", "/other/*"]), "ask"),
                (external_check(FIXER, ["/other/*", "/elsewhere/a/*"]), "ask"),
                (host_saved("save", "/other/*"), None),
                (external_check(FIXER, ["/elsewhere/a/*", "/other/*"]), "allow"),
            ],
            saved=["/elsewhere/*"],
        )

    @unittest.skipIf(NODE is None, "node is required")
    def test_failed_saved_approval_probe_prompts(self) -> None:
        self.run_external(
            "probe-failure",
            [
                ({"kind": "host", "fail": ["create"]}, None),
                (external_check(FIXER, ["/elsewhere/a/*"]), "ask"),
                ({"kind": "host", "fail": ["assert"]}, None),
                (external_check(FIXER, ["/elsewhere/a/*"]), "ask"),
                ({"kind": "host", "fail": []}, None),
                (external_check(FIXER, ["/elsewhere/a/*"]), "allow"),
            ],
            saved=["/elsewhere/*"],
        )

    @unittest.skipIf(NODE is None, "node is required")
    def test_another_plugins_allow_hook_cannot_pass_the_probe(self) -> None:
        # A plugin whose evaluate hook runs first approves every request,
        # including the probe's: the sentinel exposes it and the floor prompts.
        self.run_external(
            "allow-all-hook",
            [
                (external_check(FIXER, ["/elsewhere/a/*"]), "ask"),
                (external_check(FIXER, ["/other/*"]), "ask"),
                (external_check("code-finder", ["/other/*"]), "allow"),
            ],
            saved=["/elsewhere/*"],
            pre_hooks="allow-all",
        )

    @unittest.skipIf(NODE is None, "node is required")
    def test_saved_approval_covering_everything_prompts(self) -> None:
        # A saved approval that covers the sentinel too proves nothing.
        self.run_external("broad-saved", [(external_check(FIXER, ["/elsewhere/a/*"]), "ask")], saved=["/*"])

    @unittest.skipIf(NODE is None, "node is required")
    def test_two_package_copies_reach_the_same_answer(self) -> None:
        # Each copy has its own probes; one copy's probe is an ordinary check
        # for the other, which nests at most one probe of its own.
        observed = self.run_external(
            "two-copies",
            [
                (external_check(FIXER, ["/elsewhere/a/*"]), "allow"),
                (external_check(FIXER, ["/other/*"]), "ask"),
                (host_saved("unsave", "/elsewhere/*"), None),
                (external_check(FIXER, ["/elsewhere/a/*"]), "ask"),
            ],
            saved=["/elsewhere/*"],
            copies=2,
        )
        parents = {info["parentID"] for info in observed["created"]}
        depth = {info["id"]: 0 if info["parentID"] == "ses" else 1 for info in observed["created"]}
        self.assertLessEqual(parents, {"ses", *depth})
        for info in observed["created"]:
            if info["parentID"] != "ses":
                self.assertEqual(depth[info["parentID"]], 0, info)

    @unittest.skipIf(NODE is None, "node is required")
    def test_probe_without_the_hook_times_out_and_rejects_its_request(self) -> None:
        # No evaluate hook denies the probe (e.g. the plugin unloaded
        # mid-probe), so its request stays pending until the timeout.
        observed = self.run_external(
            "unhooked",
            [({"kind": "host", "fail": ["unhooked"]}, None), (external_check(FIXER, ["/other/*"]), "ask")],
        )
        (probe,) = observed["created"]
        self.assertEqual([(r["sessionID"], r["decision"]) for r in observed["replies"]], [(probe["id"], "reject")])

    @unittest.skipIf(NODE is None, "node is required")
    def test_probe_evaluation_after_the_timeout_never_prompts(self) -> None:
        # An earlier plugin's hook holds the probe evaluation past the timeout:
        # the floor prompts, and the late evaluation is still denied rather
        # than raising a prompt in the removed probe session.
        observed = self.run_external(
            "slow-hook",
            [(external_check(FIXER, ["/elsewhere/a/*"]), "ask")],
            saved=["/elsewhere/*"],
            pre_hooks="slow",
        )
        self.assertEqual(len(observed["created"]), 1)

    @unittest.skipIf(NODE is None, "node is required")
    def test_saved_approval_probe_never_prompts_or_leaks_a_session(self) -> None:
        observed = self.run_external(
            "probe-cleanup",
            [
                (external_check(FIXER, ["/elsewhere/a/*"]), "ask"),
                (host_saved("save", "/elsewhere/*"), None),
                (external_check(FIXER, ["/elsewhere/a/*"]), "allow"),
                (external_check("review-fixer", ["/elsewhere/a/*"], "ses-fixer"), "allow"),
                # Probes run only where the packaged rules ask under a host allow.
                ({**external_check(FIXER, ["/elsewhere/a/*"]), "effect": "ask"}, "ask"),
                ({**external_check(FIXER, ["src/*"]), "action": "read"}, "allow"),
            ],
        )
        self.assertEqual(len(observed["created"]), 3)

    @unittest.skipIf(NODE is None, "node is required")
    def test_stale_saved_approval_records_are_removed_at_setup(self) -> None:
        stale = {f"saved/external_directory/prj/{index}": f"/stale/{index}/*" for index in range(5)}
        other = {"saved/external_directory/other-project/x": "/x/*", "unrelated": "kept"}
        observed = self.run_floor(
            "stale-records",
            [{"action": "external_directory", "resource": "*", "effect": "allow"}],
            [external_check(FIXER, ["/stale/0/x/*"])],
            storage={**stale, **other},
        )
        self.assertEqual(observed["storage"], other)
        # A stale record grants nothing.
        self.assertEqual(observed["results"][0]["effect"], "ask")

    @unittest.skipIf(NODE is None, "node is required")
    def test_host_wildcard_allow_cannot_widen_a_restricted_agents_tools(self) -> None:
        host = [{"action": "*", "resource": "*", "effect": "allow"}]
        everything = [tool["name"] for tool in FAKE_INVENTORY]
        fixer = "pr-comment-fixer"
        cases: list[dict[str, Any]] = [
            {"kind": "context", "agent": fixer, "tools": everything},
            {"kind": "context", "agent": "code-finder", "tools": everything},
            *[{"kind": "execute", "agent": fixer, "tool": tool} for tool in everything],
            {"kind": "execute", "agent": "code-finder", "tool": "third_party_tool"},
        ]
        observed = self.run_floor("tools", host, cases)
        restricted_view, open_view, *calls, open_call = observed["results"]
        # Only the packaged allowlist (edit covers write/patch) reaches the model;
        # the guarded search tools appear under the built-in names.
        packaged = {"read", "edit", "write", "patch", "shell", "ycc_grep", "ycc_glob"}
        self.assertEqual(
            restricted_view["tools"],
            {
                **{name: name for name in packaged - {"ycc_grep", "ycc_glob"}},
                "grep": "ycc_grep",
                "glob": "ycc_glob",
            },
        )
        # Unrestricted agents keep every tool except the guarded search tools.
        self.assertEqual(set(open_view["tools"]), set(everything) - {"ycc_grep", "ycc_glob"})
        # grep/glob calls are the guarded tools' advertised names; a call that
        # reaches the unguarded built-in is denied by the evaluate hook instead.
        for tool, outcome in zip(everything, calls, strict=True):
            with self.subTest(tool=tool):
                self.assertEqual(outcome["ok"], tool in packaged | {"grep", "glob"}, outcome)
        self.assertTrue(open_call["ok"], open_call)

    @unittest.skipIf(NODE is None, "node is required")
    def test_restricted_agent_keeps_search_when_another_guard_renamed_it_first(self) -> None:
        renamed = {"grep": "ycc_grep", "glob": "ycc_glob"}
        observed = self.run_floor(
            "renamed",
            [{"action": "*", "resource": "*", "effect": "allow"}],
            [{"kind": "context", "agent": "pr-comment-fixer", "tools": ["read", "grep", "glob"], "renamed": renamed}],
        )
        (view,) = observed["results"]
        self.assertEqual(view["tools"], {"read": "read", "grep": "ycc_grep", "glob": "ycc_glob"})

    @unittest.skipIf(NODE is None, "node is required")
    def test_agentless_permission_check_in_an_unresolvable_session_fails_closed(self) -> None:
        observed = self.run_floor(
            "agentless",
            [{"action": "*", "resource": "*", "effect": "allow"}],
            [{"agent": None, "action": "read", "resources": ["src/app.ts"], "effect": "allow", "sessionID": "gone"}],
        )
        (outcome,) = observed["results"]
        self.assertEqual(outcome["effect"], "deny", outcome)

    @unittest.skipIf(NODE is None, "node is required")
    def test_registered_agent_fields_are_not_shared_across_setups(self) -> None:
        moved = self.tmp / "request" / "ycc-opencode"
        shutil.copytree(self.root, moved)
        registration = json.loads((moved / "registration.json").read_text(encoding="utf-8"))
        registration["agents"][0]["request"] = {"settings": {}, "headers": {}, "body": {}}
        (moved / "registration.json").write_text(json.dumps(registration), encoding="utf-8")
        agent_id = registration["agents"][0]["id"]
        script = moved.parent / "request.mjs"
        script.write_text(
            r"""
import { pathToFileURL } from "node:url";
const [root, id] = process.argv.slice(2);
const plugin = (await import(pathToFileURL(root + "/index.js").href)).default;
const seen = [];
for (let round = 0; round < 2; round++) {
  const agents = new Map();
  const noop = async () => {};
  const ctx = {
    location: { directory: process.cwd(), project: { directory: process.cwd(), canonical: process.cwd() } },
    tool: { hook: noop, transform: async (cb) => cb({ get: () => undefined }), list: async () => [] },
    permission: { hook: noop },
    skill: { transform: async (cb) => cb({ get: () => undefined, add: () => {} }) },
    agent: { transform: async (cb) => cb({ get: (k) => agents.get(k),
      update: (k, fn) => { const r = agents.get(k) ?? { id: k }; fn(r); agents.set(k, r); } }) },
    command: { transform: async (cb) => cb({ add: () => {} }) },
    mcp: { transform: async (cb) => cb({ get: () => undefined, set: () => {} }) },
    session: { hook: noop, get: async () => ({}) },
  };
  const cleanup = await plugin.setup(ctx);
  const record = agents.get(id);
  seen.push(structuredClone(record.request));
  // opencode.config.agent merges config headers into the record in place.
  Object.assign(record.request.headers, { "x-host": String(round) });
  await cleanup();
}
console.log(JSON.stringify(seen));
""",
            encoding="utf-8",
        )
        assert NODE is not None
        result = subprocess.run(
            [NODE, str(script), str(moved), agent_id], capture_output=True, text=True, timeout=60, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        first, second = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(first["headers"], {})
        self.assertEqual(second["headers"], {})

    # -- generator ownership and safety ---------------------------------------

    def test_check_passes_clean_and_detects_drift_and_orphans(self) -> None:
        dest = self.tmp / "repo"
        generator.write_all(dest)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(generator.run_check(dest), 0)
            (dest / PACKAGE / "AGENTS.md").write_text("drift\n", encoding="utf-8")
            (dest / PACKAGE / "stray.txt").write_text("orphan\n", encoding="utf-8")
            self.assertEqual(generator.run_check(dest), 1)

    def test_write_prunes_orphans_but_never_touches_sibling_packages(self) -> None:
        dest = self.tmp / "repo"
        generator.write_all(dest)
        sibling = dest / "packages/opencode/not-ours/keep.txt"
        sibling.parent.mkdir(parents=True)
        sibling.write_text("keep\n", encoding="utf-8")
        orphan = dest / PACKAGE / "skills/removed-skill/SKILL.md"
        orphan.parent.mkdir(parents=True)
        orphan.write_text("stale\n", encoding="utf-8")
        generator.write_all(dest)
        self.assertFalse(orphan.exists())
        self.assertFalse(orphan.parent.exists())
        self.assertTrue(sibling.is_file())

    def test_dry_run_mutates_nothing(self) -> None:
        dest = self.tmp / "repo"
        with contextlib.redirect_stdout(io.StringIO()):
            generator.write_all(dest, dry_run=True)
        self.assertFalse((dest / PACKAGE).exists())

    def test_managed_symlinks_are_rejected_in_every_mode(self) -> None:
        dest = self.tmp / "repo"
        target = self.tmp / "elsewhere"
        target.mkdir()
        (dest / "packages/opencode").mkdir(parents=True)
        (dest / PACKAGE).symlink_to(target, target_is_directory=True)
        for action in (
            lambda: generator.write_all(dest),
            lambda: generator.write_all(dest, dry_run=True),
            lambda: generator.run_check(dest),
        ):
            with self.assertRaises(ValueError):
                action()
        self.assertEqual(list(target.iterdir()), [])

    def test_selection_follows_the_model_not_catalog_visibility(self) -> None:
        def with_runtime(**changes: object) -> PackageModel:
            packages = tuple(
                (
                    replace(
                        package,
                        runtimes=tuple(
                            replace(entry, **changes) if entry.runtime == "opencode" else entry
                            for entry in package.runtimes
                        ),
                    )
                    if package.key == "@yandy-r/ycc-opencode"
                    else package
                )
                for package in self.model.packages
            )
            return PackageModel(self.model.schema_version, self.model.version_source, packages)

        listed = with_runtime(listed=True)
        self.assertEqual([p.key for p in generator.npm_packages(listed.packages)], ["@yandy-r/ycc-opencode"])
        deferred = with_runtime(status="deferred")
        self.assertEqual(generator.npm_packages(deferred.packages), ())
        self.assertEqual(generator.npm_package_roots(deferred.packages), (PACKAGE,))
        unsupported = with_runtime(components=("skills", "hooks"))
        with self.assertRaisesRegex(ValueError, "unsupported opencode npm components"):
            generator.npm_packages(unsupported.packages)

    def test_missing_canonical_version_fails_before_any_write(self) -> None:
        dest = self.tmp / "repo"
        with patch.object(generator, "native_version", side_effect=ValueError("missing nonempty version")):
            with self.assertRaisesRegex(ValueError, "missing nonempty version"):
                generator.write_all(dest)
        self.assertFalse(dest.exists())

    def test_cli_check_exit_codes(self) -> None:
        script = REPO_ROOT / "scripts/generate_opencode_package.py"
        result = subprocess.run(
            [sys.executable, str(script), "--bogus"], capture_output=True, text=True, timeout=60, check=False
        )
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
