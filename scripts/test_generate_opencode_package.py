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
# `event` cases publish a host bus event to every live subscriber (or only to
# the setups listed in `targets`, i.e. other locations of the project) and
# wait `settle` ms (default 30); `rebuild` sets the adapter up again over the
# same plugin storage; `storage` makes later writes fail (`fail`), wait until a
# `release` (`hold`), or succeed (`ok`), or sets how many ms a scan takes
# (`scanDelay`). Storage calls resolve a tick later, as the host's do, and scan
# pages two entries at a time.
FLOOR_DRIVER = r"""
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
const [root] = process.argv.slice(2);
const { hostRules, inventory, sessions, cases } = JSON.parse(readFileSync(0, "utf8"));
const plugin = (await import(pathToFileURL(root + "/index.js").href)).default;
const storage = new Map(), subscribers = new Set(), held = [];
let writes = "ok", scanDelay = 0;
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
function subscriber(owner) {
  return (options) => ({ [Symbol.asyncIterator]() {
    const queue = [];
    let wake, done = false;
    const sub = { owner, push(event) { queue.push(event); wake?.(); } };
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
  } });
}
const pluginStorage = {
  get: async (key) => { await tick(); return structuredClone(storage.get(key)); },
  set: async (key, value) => {
    await tick();
    if (writes === "fail") throw new Error("kv write failed");
    if (writes === "hold") await new Promise((resolve) => held.push(resolve));
    storage.set(key, structuredClone(value));
  },
  remove: async (key) => { await tick(); storage.delete(key); },
  scan: async ({ prefix, after, limit = 2 }) => {
    // The query reads storage when it starts; a slow scan returns that snapshot.
    const keys = [...storage.keys()]
      .filter((key) => key.startsWith(prefix) && (after === undefined || key > after)).sort();
    const entries = keys.slice(0, limit).map((key) => ({ key, value: structuredClone(storage.get(key)) }));
    await new Promise((resolve) => setTimeout(resolve, scanDelay));
    return keys.length > limit ? { entries, next: entries.at(-1).key } : { entries };
  },
};
let setups = 0;
async function setup() {
  const owner = setups++;
  const agents = new Map(), hooks = { evaluate: [], "execute.before": [], context: [] };
  const add = (name, cb) => { if (name in hooks) hooks[name].push(cb); };
  const ctx = {
    location: { directory: process.cwd(),
      project: { id: "prj", directory: process.cwd(), canonical: process.cwd() } },
    event: { subscribe: subscriber(owner) },
    storage: pluginStorage,
    tool: {
      hook: async (name, cb) => add(name, cb),
      transform: async (cb) => cb({ get: () => undefined }),
      list: async () => inventory.map((tool) => ({ ...tool, execute: async () => ({}) })),
    },
    permission: { hook: async (name, cb) => add(name, cb) },
    skill: { transform: async (cb) => cb({ get: () => undefined, add: () => {} }) },
    agent: { transform: async (cb) => cb({
      get: (id) => agents.get(id),
      update: (id, fn) => { const record = agents.get(id) ?? { id }; fn(record); agents.set(id, record); } }) },
    command: { transform: async (cb) => cb({ add: () => {} }) },
    mcp: { transform: async (cb) => cb({ get: () => undefined, set: () => {} }) },
    session: {
      hook: async (name, cb) => add(name, cb),
      get: async ({ sessionID }) => {
        if (!(sessionID in sessions)) throw new Error(`session not found: ${sessionID}`);
        return { data: { id: sessionID, agent: sessions[sessionID] ?? undefined,
          location: { directory: process.cwd() } } };
      },
    },
  };
  const cleanup = await plugin.setup(ctx);
  // opencode.config.agent pushes host rules into every existing agent in place.
  for (const record of agents.values()) record.permissions?.push(...structuredClone(hostRules));
  return { agents, hooks, cleanup };
}
const settle = () => new Promise((resolve) => setTimeout(resolve, 30));
const first = await setup();
const second = await setup();
const states = [first, second];
let current = second;
await settle();
const results = [];
for (const item of cases) {
  const sessionID = item.sessionID ?? "ses";
  try {
    if (item.kind === "event") {
      for (const event of item.events ?? [item]) {
        for (const sub of subscribers) {
          if (!event.targets || event.targets.includes(sub.owner)) {
            sub.push({ id: "evt", created: 0, type: event.type, data: event.data });
          }
        }
      }
      await new Promise((resolve) => setTimeout(resolve, item.settle ?? 30));
      results.push({ ok: true });
    } else if (item.kind === "storage") {
      if (item.scanDelay !== undefined) scanDelay = item.scanDelay;
      else writes = item.writes;
      if (item.writes === "release") { writes = "ok"; held.splice(0).forEach((resolve) => resolve()); }
      await settle();
      results.push({ ok: true });
    } else if (item.kind === "rebuild") {
      current = await setup();
      states.push(current);
      await settle();
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
const count = (state, id) => state.agents.get(id).permissions.length;
console.log(JSON.stringify({
  counts: { first: count(first, "pr-comment-fixer"), second: count(second, "pr-comment-fixer") },
  results,
}));
for (const state of states) await state.cleanup();
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


def external_asked(
    request: str, resources: list[str], save: list[str], session: str = "ses", targets: list[int] | None = None
) -> dict[str, Any]:
    """The host's permission.asked event for one external_directory request."""
    data = {"id": request, "sessionID": session, "action": "external_directory", "resources": resources, "save": save}
    event: dict[str, Any] = {"kind": "event", "type": "permission.asked", "data": data}
    if targets is not None:
        event["targets"] = targets
    return event


def external_replied(
    request: str, reply: str, session: str = "ses", targets: list[int] | None = None
) -> dict[str, Any]:
    """The host's permission.replied event."""
    data = {"sessionID": session, "requestID": request, "reply": reply}
    event: dict[str, Any] = {"kind": "event", "type": "permission.replied", "data": data}
    if targets is not None:
        event["targets"] = targets
    return event


def external_batch(*events: dict[str, Any]) -> dict[str, Any]:
    """Events published back to back, without waiting between them."""
    return {"kind": "event", "events": list(events)}


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

    def run_floor(self, name: str, host: list[dict[str, str]], cases: list[dict[str, Any]]) -> dict[str, Any]:
        """Drive the package's floor hooks with host rules appended after setup."""
        assert NODE is not None
        moved = self.tmp / name / "ycc-opencode"
        shutil.copytree(self.root, moved)
        script = moved.parent / "floor.mjs"
        script.write_text(FLOOR_DRIVER, encoding="utf-8")
        payload = {
            "hostRules": host,
            "inventory": FAKE_INVENTORY,
            "sessions": {"ses": None, "ses-fixer": "pr-comment-fixer", "ses-finder": "code-finder"},
            "cases": cases,
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

    def run_external(self, name: str, steps: list[tuple[dict[str, Any], str | None]]) -> None:
        """Replay external-directory checks and events under a host-wide allow."""
        host = [{"action": "external_directory", "resource": "*", "effect": "allow"}]
        observed = self.run_floor(name, host, [step for step, _ in steps])
        for index, ((step, effect), outcome) in enumerate(zip(steps, observed["results"], strict=True)):
            with self.subTest(index=index, step=json.dumps(step)):
                self.assertTrue(outcome["ok"], outcome)
                if effect is not None:
                    self.assertEqual(outcome["effect"], effect)
                    self.assertIsNone(outcome["message"])

    @unittest.skipIf(NODE is None, "node is required")
    def test_host_external_directory_allow_prompts_restricted_agents_until_saved(self) -> None:
        self.run_external(
            "external",
            [
                # A config-level allow does not reach a restricted agent's own `ask`.
                (external_check(FIXER, ["/elsewhere/a/*"]), "ask"),
                (external_check("code-finder", ["/elsewhere/a/*"]), "allow"),
                # The user answers that prompt "always"; the host saves the project root.
                (external_asked("per_1", ["/elsewhere/a/*"], ["/elsewhere/*"]), None),
                (external_replied("per_1", "always"), None),
                (external_check(FIXER, ["/elsewhere/a/*"]), "allow"),
                (external_check(FIXER, ["/elsewhere/b/*"]), "allow"),
                (external_check(FIXER, ["/elsewhere/b/*", "/other/*"]), "ask"),
                # "once" saves nothing, so the next call prompts again.
                (external_asked("per_2", ["/other/*"], ["/other/*"]), None),
                (external_replied("per_2", "once"), None),
                (external_check(FIXER, ["/other/*"]), "ask"),
                # A reply to a request never seen asked records nothing; "reject" neither.
                (external_replied("per_unknown", "always"), None),
                (external_asked("per_3", ["/third/*"], ["/third/*"]), None),
                (external_replied("per_3", "reject"), None),
                (external_check(FIXER, ["/third/*"]), "ask"),
                # Saved approvals are per project, for every agent and session, as the host saves them.
                (external_asked("per_4", ["/fourth/*"], ["/fourth/*"], "ses-finder"), None),
                (external_replied("per_4", "always", "ses-finder"), None),
                (external_check(FIXER, ["/fourth/x/*"]), "allow"),
                # The approval outlives a state rebuild.
                ({"kind": "rebuild"}, None),
                (external_check(FIXER, ["/elsewhere/a/*"]), "allow"),
                (external_check(FIXER, ["/other/*"]), "ask"),
            ],
        )

    @unittest.skipIf(NODE is None, "node is required")
    def test_host_auto_resolved_external_requests_record_nothing(self) -> None:
        # Two prompts pend; the user answers the narrow one "always". The host
        # saves /repo/d/* only, then auto-resolves the covered /repo/d/sub/*
        # request with an "always" reply whose wider `save` it never stores.
        self.run_external(
            "auto-resolve",
            [
                (external_asked("per_a", ["/repo/d/*"], ["/repo/d/*"]), None),
                (external_asked("per_b", ["/repo/d/sub/*"], ["/repo/*"]), None),
                (external_batch(external_replied("per_a", "always"), external_replied("per_b", "always")), None),
                (external_check(FIXER, ["/repo/d/sub/*"]), "allow"),
                (external_check(FIXER, ["/repo/e/*"]), "ask"),
                ({"kind": "rebuild"}, None),
                (external_check(FIXER, ["/repo/e/*"]), "ask"),
            ],
        )

    @unittest.skipIf(NODE is None, "node is required")
    def test_auto_resolved_request_partly_allowed_by_config_records_nothing(self) -> None:
        # One batched request: /home/u/p2/sub/* is allowed by the user's config,
        # /r/d/sub/* asks. The user answers another request for /r/d/* "always";
        # the host saves only /r/d/* and auto-resolves the batched request.
        self.run_external(
            "auto-resolve-partial",
            [
                (external_asked("per_a", ["/r/d/*"], ["/r/d/*"]), None),
                (external_asked("per_b", ["/home/u/p2/sub/*", "/r/d/sub/*"], ["/home/u/p2/*", "/r/*"]), None),
                (external_batch(external_replied("per_a", "always"), external_replied("per_b", "always")), None),
                (external_check(FIXER, ["/r/d/sub/*"]), "allow"),
                (external_check(FIXER, ["/r/e/*"]), "ask"),
                (external_check(FIXER, ["/home/u/p2/x/*"]), "ask"),
                ({"kind": "rebuild"}, None),
                (external_check(FIXER, ["/r/e/*"]), "ask"),
                (external_check(FIXER, ["/home/u/p2/x/*"]), "ask"),
            ],
        )

    @unittest.skipIf(NODE is None, "node is required")
    def test_failed_approval_write_does_not_stop_recording(self) -> None:
        self.run_external(
            "write-failure",
            [
                ({"kind": "storage", "writes": "fail"}, None),
                (external_asked("per_1", ["/one/*"], ["/one/*"]), None),
                (external_replied("per_1", "always"), None),
                ({"kind": "storage", "writes": "ok"}, None),
                (external_asked("per_2", ["/two/*"], ["/two/*"]), None),
                (external_replied("per_2", "always"), None),
                ({"kind": "rebuild"}, None),
                (external_check(FIXER, ["/two/*"]), "allow"),
                # The write that failed is not stored: it prompts once more after a rebuild.
                (external_check(FIXER, ["/one/*"]), "ask"),
            ],
        )

    @unittest.skipIf(NODE is None, "node is required")
    def test_approval_applies_before_its_storage_write_lands(self) -> None:
        self.run_external(
            "pending-write",
            [
                ({"kind": "storage", "writes": "hold"}, None),
                (external_asked("per_1", ["/one/*"], ["/one/*"]), None),
                (external_replied("per_1", "always"), None),
                # The host re-evaluates a parallel request right after the reply.
                (external_check(FIXER, ["/one/sub/*"]), "allow"),
                ({"kind": "storage", "writes": "release"}, None),
                ({"kind": "rebuild"}, None),
                (external_check(FIXER, ["/one/sub/*"]), "allow"),
            ],
        )

    @unittest.skipIf(NODE is None, "node is required")
    def test_approval_applies_before_a_slow_storage_scan_finishes(self) -> None:
        # The host's re-evaluation of pending requests runs right after it
        # publishes the reply, long before a slow storage scan returns.
        self.run_external(
            "slow-scan",
            [
                ({"kind": "storage", "scanDelay": 300}, None),
                (external_asked("per_1", ["/one/*"], ["/one/*"]), None),
                ({**external_replied("per_1", "always"), "settle": 5}, None),
                (external_check(FIXER, ["/one/sub/*"]), "allow"),
                # A request asked alongside it and answered "always" is still recorded.
                (external_asked("per_2", ["/two/*"], ["/two/*"]), None),
                ({**external_replied("per_2", "always"), "settle": 5}, None),
                (external_check(FIXER, ["/two/sub/*"]), "allow"),
            ],
        )

    @unittest.skipIf(NODE is None, "node is required")
    def test_concurrent_approvals_from_two_locations_are_both_kept(self) -> None:
        # Setups 0 and 1 stand for two directories (worktrees) of one project,
        # each streaming its own location's events into the shared storage.
        self.run_external(
            "two-locations",
            [
                ({"kind": "storage", "writes": "hold"}, None),
                (
                    external_batch(
                        external_asked("per_a", ["/a/*"], ["/a/*"], targets=[0]),
                        external_asked("per_b", ["/b/*"], ["/b/*"], targets=[1]),
                        external_replied("per_a", "always", targets=[0]),
                        external_replied("per_b", "always", targets=[1]),
                    ),
                    None,
                ),
                ({"kind": "storage", "writes": "release"}, None),
                ({"kind": "rebuild"}, None),
                (external_check(FIXER, ["/a/*"]), "allow"),
                (external_check(FIXER, ["/b/*"]), "allow"),
            ],
        )

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
