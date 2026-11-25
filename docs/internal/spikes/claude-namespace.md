# Claude Code Plugin Namespace, Cross-Plugin Dispatch, and Skill Preload Spike (YAN-1121)

- **Date:** 2026-10-15
- **Issue:** `YAN-1121`
- **Target CLIs:** `@anthropic-ai/claude-code` floor `2.1.143` (`2.1.143 (Claude Code)`) and `latest` (`2.1.300 (Claude Code)`)
- **Harness:** [`scripts/test-claude-namespace-spike.sh`](../../../scripts/test-claude-namespace-spike.sh) + [`scripts/claude_namespace_fake_api.py`](../../../scripts/claude_namespace_fake_api.py) + typed assertions in [`scripts/claude_namespace_checks.py`](../../../scripts/claude_namespace_checks.py)

## Executive Decisions (Post-6.0 `ycc-agents` Split)

1. **Shared runtime namespace (`"name": "ycc"` across two installed plugins):** **No-Go.**
   - Claude Code uses `.claude-plugin/plugin.json` `name` (not the marketplace catalog entry name or `@marketplace` install suffix) as the runtime skill/agent namespace prefix (`<manifest-name>:<component>`).
   - When two installed plugins declare the same manifest `name` (either two entries in one marketplace or two separate marketplaces), `claude plugin install` and startup emit **no collision error or warning**. Both plugins appear in the `system/init` `plugins` list. The duplicated skill string appears twice in `init.skills` on `2.1.143` but once on `2.1.300`; the duplicated agent string appears once on both. Latest also lists built-in plugins (`agents-md`, `plugin-authoring`); those are not fixture plugins.
   - Runtime resolution silently splits by component type and install order: on both `2.1.143` and `2.1.300`, `Skill(shared:probe)` resolves to the **first-installed** plugin's `SKILL.md`, while `Task`/`Agent(subagent_type: shared:worker)` resolves to the **last-installed** plugin's `agents/worker.md`. Two plugins therefore cannot safely co-own `ycc:*` or mask each other symmetrically.
2. **Distinct plugin manifests (`ycc` + `ycc-agents`) with cross-plugin agent dispatch:** **Go (requires qualified agent names).**
   - With distinct `.claude-plugin/plugin.json` names (`<caller>` and `<worker>`), both plugins load without collision in either install order; `Skill` and `Task`/`Agent` deterministically resolve each plugin's own payload.
   - A skill loaded from plugin A (`<caller>:cross-dispatch`, where plugin A has **no** `agents/` directory) can be followed by a `Task`/`Agent` tool call targeting `<worker>:worker` in plugin B. Claude Code loads plugin B's `agents/worker.md` body into the subagent's `system` prompt on both `2.1.143` and `2.1.300`.
   - Negative control (`<prefix>:absent`) is rejected by Claude Code with `is_error: true` (`Agent type '<prefix>:absent' not found. Available agents: ...`) and spawns 0 subagent requests.
3. **Cross-plugin agent `skills:` frontmatter preloading:** **Go (prefer qualified `<plugin>:<skill>`; bare `<skill>` also resolves when unambiguous).**
   - When an agent in plugin B declares `skills: [<caller>:cross-preload]` (or bare `skills: [cross-preload]`), and plugin B contains **no** local copy of `cross-preload`, Claude Code injects plugin A's `SKILL.md` body into the subagent's user messages (qualified command tag for qualified references; bare command tag for bare references) on both `2.1.143` and `2.1.300`.
   - Because bare skill names rely on global lookup across enabled plugins and can collide if another plugin defines the same bare skill name, a post-6.0 `ycc-agents` split **must** use fully qualified `<plugin>:<skill>` references in agent `skills:` frontmatter and `<plugin>:<agent>` in `subagent_type` dispatches.

---

## 1. Live-Verified Environment & Isolation Proof

All observations below were produced by running:

```bash
./scripts/test-claude-namespace-spike.sh --keep
```

Isolation controls enforced by the harness:

- **Ephemeral sandbox:** Created via `mktemp -d /tmp/opencode/claude-namespace-spike.XXXXXX` (`umask 077`), with `cd "$root/work"` (an empty non-Git directory outside the repository).
- **Scrubbed environment (`env -i`):** Only `PATH` (Node, npm, `/usr/local/bin:/usr/bin:/bin`), `LANG=C.UTF-8`, `TERM=dumb`, `NO_COLOR=1`, isolated `HOME`, `CLAUDE_CONFIG_DIR`, `XDG_*`, `TMPDIR`, isolated `npm_config_cache` / `npm_config_userconfig` / `npm_config_globalconfig`, `DISABLE_AUTOUPDATER=1`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `DISABLE_TELEMETRY=1`, `DISABLE_ERROR_REPORTING=1`, and file-only Git config (`GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_TERMINAL_PROMPT=0`, `GIT_ALLOW_PROTOCOL=file`).
- **Lab-local pinned CLI installs:** `@anthropic-ai/claude-code@2.1.143` and `@anthropic-ai/claude-code@latest` (resolved via `npm view` to `2.1.300`) are installed only into `$root/npm-<version>/` prefixes; global binaries and user configuration are never modified.
- **No real credentials or remote inference:** `ANTHROPIC_BASE_URL` points to an ephemeral `127.0.0.1:<port>` Python stdlib HTTP server (`scripts/claude_namespace_fake_api.py`) with `ANTHROPIC_API_KEY=sk-ant-dummy-namespace-spike`. The server never logs HTTP headers and never synthesizes fixture marker strings.
- **Real user config invariance proof:** Before and after the run (inside the `EXIT` trap), the harness records non-content metadata (`mtime_ns`, `size`, `sha256`, symlink target) for every guarded path under `~/.claude` and for `~/.claude.json`.
  - Since YAN-2454 the guard skips state that live Claude sessions rewrite on their own (`sessions/`, `backups/`, `projects/`, caches, `*.stamp.json`, `*.signature.json`, `plugins/{data,synced,store,.trash}`, `.in_use` markers; see `is_volatile` in `scripts/claude_namespace_checks.py`). `~/.claude.json` compares only its MCP servers and per-project tool/MCP permissions, and the plugin indexes ignore only `lastUpdated` stamps. Settings, plugin indexes, marketplaces, plugin cache payloads, hooks, agents and skills stay strict, so concurrent Claude sessions no longer fail the run.
  - Verified run `/tmp/opencode/claude-namespace-spike.MwyutO`: `real-config hash/mtime unchanged: True entries: 48731`.

| Requested Version | Resolved Version | CLI `--version` Output  | Lab Native Binary `sha256`                                         |
| ----------------- | ---------------- | ----------------------- | ------------------------------------------------------------------ |
| `2.1.143`         | `2.1.143`        | `2.1.143 (Claude Code)` | `f75fdc3ff9d9cd494b86192f9e349b5c5c6d3970ed4d5cd5c7b330c5a2b1dcc4` |
| `latest`          | `2.1.300`        | `2.1.300 (Claude Code)` | `674deba0bba9aee479f4503c438b49303b6fdd304b9a471b14977aaec5215453` |

---

## 2. Fixture Architecture & Anti-Masking Proof

> **Historical per-run values:** Each run generates a fresh random token `<PREFIX>` (`ns-c861a459d2` on `2.1.143`, `ns-91ecc955c9` on `2.1.300`) and 96-bit random payload markers (`PAYLOAD_A_*`, `PAYLOAD_B_*`, `PRELOAD_*`, `LOCAL_PRELOAD_*`) placed **only** in markdown bodies (never in frontmatter `description` fields or fake API responses). All paths are sanitized to `<LAB>` in transcripts.

For the cross-plugin and preload scenarios (`config-cross`), [`scripts/claude_namespace_fake_api.py`](../../../scripts/claude_namespace_fake_api.py) asserts and writes `fixture-proof.json` (recorded after install and before inference):

- `caller_has_agents: false` — `<LAB>/cross/p0/agents` is removed before marketplace registration. Any successful `worker` subagent execution **must** come from plugin B (`<LAB>/cross/p1/agents/`).
- `worker_has_cross_preload: false` — `<LAB>/cross/p1/skills/cross-preload` does not exist. Any appearance of the `PRELOAD_*` marker in a plugin B subagent request **must** come from plugin A (`<LAB>/cross/p0/skills/cross-preload/SKILL.md`).
- Fixtures contain only `.claude-plugin/marketplace.json`, `.claude-plugin/plugin.json`, `skills/*/SKILL.md`, and `agents/*.md` (zero hooks, scripts, or MCP servers).

Sample `fixture-proof.json` values from the `2.1.300` run (`ns-91ecc955c9`):

- `a`: `PAYLOAD_A_c914d28aa9450b826c0f1431`; `b`: `PAYLOAD_B_1b7b405dd590424c273e6b16`
- `preload`: `PRELOAD_3fae06244b375f96454ce770`; `local`: `LOCAL_PRELOAD_2a9d2a07b2b50bb675f51908`
- `p0/skills/cross-preload/SKILL.md`: `sha256=8c73d41c9af47c4bd0def56493ca51ad370a267a896f2f361d088e8a5bf9ecc6`
- `p1/agents/qualified.md`: `sha256=d674787d803d29c166594ac9c6a8c5880239aa36164215b28f248f99dcdb074b`
- `p1/agents/bare.md`: `sha256=48d1e49f0049a4cb6c5c84983f246c4eb8408c5f03e5929d7a5505bacbb96eb7`

---

## 3. Observed Results Matrix (`2.1.143` and `2.1.300`)

Both `2.1.143` and `2.1.300` produced **identical payload winners** across all 15 probes per version. Init inventory presentation differs: duplicated skill strings occur twice on the floor and once on latest. The table counts fixture components only:

| Scenario ID          | Setup & Install Order (`--scope user`)                                                                                                                | `init` Plugins / Skills / Agents                                                                                                   | Invoked `Skill` -> `Agent`/`Task`                | Parent Skill Payload Resolved                   | Subagent Prompt Payload Resolved                       | Verdict                                   |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ | ----------------------------------------------- | ------------------------------------------------------ | ----------------------------------------- |
| `mismatched-ab`      | 1 catalog, entries `<caller>` (`p0`, marker `A`) & `<worker>` (`p1`, marker `B`), **both manifests named `<shared>`**; install `caller` then `worker` | 2 plugins named `<shared>`; `skills` has `<shared>:probe` **twice on floor / once on latest**; `agents` has `<shared>:worker` once | `<shared>:probe` -> `<shared>:worker`            | **`A` (first installed)** (`a: true, b: false`) | **`B` (last installed)** (`a: false, b: true`)         | **Collision (split winner)**              |
| `mismatched-ba`      | Same as above; install `worker` (`B`) then `caller` (`A`)                                                                                             | 2 plugins named `<shared>`; `<shared>:probe` twice on floor / once on latest; `<shared>:worker` once                               | `<shared>:probe` -> `<shared>:worker`            | **`B` (first installed)** (`a: false, b: true`) | **`A` (last installed)** (`a: true, b: false`)         | **Collision (split winner)**              |
| `shared-markets-ab`  | 2 catalogs (`market-a` marker `A`, `market-b` marker `B`), both entry & manifest named `<shared>`; install `market-a` then `market-b`                 | 2 plugins named `<shared>`; `<shared>:probe` twice on floor / once on latest; `<shared>:worker` once                               | `<shared>:probe` -> `<shared>:worker`            | **`A` (first installed)** (`a: true, b: false`) | **`B` (last installed)** (`a: false, b: true`)         | **Collision (split winner)**              |
| `shared-markets-ba`  | Same as above; install `market-b` (`B`) then `market-a` (`A`)                                                                                         | 2 plugins named `<shared>`; `<shared>:probe` twice on floor / once on latest; `<shared>:worker` once                               | `<shared>:probe` -> `<shared>:worker`            | **`B` (first installed)** (`a: false, b: true`) | **`A` (last installed)** (`a: true, b: false`)         | **Collision (split winner)**              |
| `distinct-ab-caller` | 1 catalog, distinct manifests `<caller>` (`A`) & `<worker>` (`B`); install `caller` then `worker`                                                     | `<caller>:probe`, `<worker>:probe`; `<caller>:worker`, `<worker>:worker`                                                           | `<caller>:probe` -> `<caller>:worker`            | **`A`** (`a: true, b: false`)                   | **`A`** (`a: true, b: false`)                          | **Pass (control)**                        |
| `distinct-ab-worker` | Same (`caller` then `worker`)                                                                                                                         | Distinct skills & agents                                                                                                           | `<worker>:probe` -> `<worker>:worker`            | **`B`** (`a: false, b: true`)                   | **`B`** (`a: false, b: true`)                          | **Pass (control)**                        |
| `distinct-ba-caller` | Same; install `worker` then `caller`                                                                                                                  | Distinct skills & agents                                                                                                           | `<caller>:probe` -> `<caller>:worker`            | **`A`** (`a: true, b: false`)                   | **`A`** (`a: true, b: false`)                          | **Pass (order-independent)**              |
| `distinct-ba-worker` | Same (`worker` then `caller`)                                                                                                                         | Distinct skills & agents                                                                                                           | `<worker>:probe` -> `<worker>:worker`            | **`B`** (`a: false, b: true`)                   | **`B`** (`a: false, b: true`)                          | **Pass (order-independent)**              |
| `cross-dispatch`     | `<caller>` (no `agents/`) + `<worker>` (has `agents/worker.md`)                                                                                       | `<caller>:*` skills only; `<worker>:*` agents only                                                                                 | `<caller>:cross-dispatch` -> `<worker>:worker`   | `caller` (`A`)                                  | `worker` (`B` in subagent `system`)                    | **Pass (cross-plugin dispatch)**          |
| `same-dispatch`      | Positive control within `<worker>`                                                                                                                    | Same                                                                                                                               | `<worker>:same-dispatch` -> `<worker>:worker`    | `caller` (`A` in skill body)                    | `worker` (`B` in subagent `system`)                    | **Pass (positive control)**               |
| `missing-dispatch`   | Negative control targeting `<prefix>:absent`                                                                                                          | Same                                                                                                                               | `<caller>:missing-dispatch` -> `<prefix>:absent` | `caller` (`A`)                                  | **0 subagent requests** (`is_error: true` tool_result) | **Pass (negative control)**               |
| `preload-same`       | Positive control: `<worker>:same` agent has `skills: [local-preload]`                                                                                 | Same                                                                                                                               | `<worker>:probe` -> `<worker>:same`              | `worker` (`B`)                                  | `worker` (`B`) + `local` (`LOCAL_PRELOAD_*`)           | **Pass (positive control)**               |
| `preload-qualified`  | Cross-plugin qualified: `<worker>:qualified` has `skills: [<caller>:cross-preload]`                                                                   | Same                                                                                                                               | `<worker>:probe` -> `<worker>:qualified`         | `worker` (`B`)                                  | `worker` (`B`) + **`preload` (`PRELOAD_*`)**           | **Pass (qualified preload)**              |
| `preload-bare`       | Cross-plugin bare: `<worker>:bare` has `skills: [cross-preload]`                                                                                      | Same                                                                                                                               | `<worker>:probe` -> `<worker>:bare`              | `worker` (`B`)                                  | `worker` (`B`) + **`preload` (`PRELOAD_*`)**           | **Pass (bare preload resolves globally)** |
| `preload-missing`    | Negative control: `<worker>:missing` has `skills: [<caller>:absent]`                                                                                  | Same                                                                                                                               | `<worker>:probe` -> `<worker>:missing`           | `worker` (`B`)                                  | `worker` (`B`) only (`preload: false, local: false`)   | **Pass (negative control)**               |

---

## 4. Sanitized Transcript & Request Evidence

### 4.1 Shared Manifest Collision (`mismatched-ab` vs `mismatched-ba`)

Filtered `2.1.300` init excerpt (built-ins and unrelated fields omitted): even when the marketplace entries have distinct catalog names (`<caller>@<market>` and `<worker>@<market>`) and install into separate cache directories (`.../cache/<market>/<caller>/0.0.1` and `.../cache/<market>/<worker>/0.0.1`), `system/init` registers both under their `.claude-plugin/plugin.json` `name` (`<shared>`):

```json
{
  "type": "system",
  "subtype": "init",
  "plugins": [
    {
      "name": "ns-91ecc955c9-shared",
      "path": "<LAB>/mismatched-ab/p0",
      "source": "ns-91ecc955c9-caller@ns-91ecc955c9-mismatched-ab"
    },
    {
      "name": "ns-91ecc955c9-shared",
      "path": "<LAB>/mismatched-ab/p1",
      "source": "ns-91ecc955c9-worker@ns-91ecc955c9-mismatched-ab"
    }
  ],
  "skills": ["ns-91ecc955c9-shared:probe"],
  "agents": ["claude", "Explore", "general-purpose", "ns-91ecc955c9-shared:worker", "Plan", "statusline-setup"]
}
```

In `mismatched-ab` (`p0` installed first, `p1` second), invoking `Skill(ns-91ecc955c9-shared:probe)` injects `PAYLOAD_A_*` (`p0`, first-installed wins), whereas invoking `Agent(subagent_type: "ns-91ecc955c9-shared:worker")` spawns a subagent whose `system` prompt contains `PAYLOAD_B_*` (`p1`, last-installed wins). Reversing the install order (`mismatched-ba`) flips both winners (`Skill` -> `B`, `Agent` -> `A`).

### 4.2 Cross-Plugin Agent Dispatch & Negative Control

When the fake API responds to the parent turn with `tool_use` for `Skill("<caller>:cross-dispatch")` and then `Agent`/`Task` with `subagent_type: "<worker>:worker"`, Claude Code sends a separate `/v1/messages` request for the subagent whose `system` array includes plugin B's `agents/worker.md` body (`PAYLOAD_B_*`).

When `subagent_type` is `<prefix>:absent` (`missing-dispatch`), Claude Code does not call `/v1/messages` for a subagent (`subagent_requests: 0`) and returns this `tool_result` to the parent conversation:

```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_ns_agent",
  "is_error": true,
  "content": "Agent type 'ns-91ecc955c9:absent' not found. Available agents: claude, Explore, general-purpose, ns-91ecc955c9-worker:bare, ns-91ecc955c9-worker:missing, ns-91ecc955c9-worker:qualified, ns-91ecc955c9-worker:same, ns-91ecc955c9-worker:worker, Plan, statusline-setup"
}
```

### 4.3 Cross-Plugin Skill Preload (`preload-qualified`, `preload-bare`, `preload-missing`)

In `preload-qualified` (`skills: [ns-91ecc955c9-caller:cross-preload]`) and `preload-bare` (`skills: [cross-preload]`), the subagent `/v1/messages` request logged by the fake API contains:

- `system`: plugin B's agent markdown body (`PAYLOAD_B_1b7b405dd590424c273e6b16`)
- `messages[0]` (`role: "user"`):

```json
{
  "role": "user",
  "content": [
    { "type": "text", "text": "SUBAGENT:preload-bare\n" },
    {
      "type": "text",
      "text": "<command-message>cross-preload</command-message>\n<command-name>cross-preload</command-name>\n<skill-format>true</skill-format>"
    },
    {
      "type": "text",
      "text": "Base directory for this skill: <LAB>/cross/p0/skills/cross-preload\n\nPRELOAD_3fae06244b375f96454ce770\n"
    }
  ]
}
```

This is an actual bare-preload excerpt from latest, not a reconstructed response. The qualified probe uses `<command-name>ns-91ecc955c9-caller:cross-preload</command-name>` with the same body marker. Floor also injects the body but wraps environment/skill reminders differently.

In `preload-missing` (`skills: [ns-91ecc955c9-caller:absent]`), the subagent still launches (no hard error), with `PAYLOAD_B_*` in `system` and the subagent task (plus built-in environment/skill metadata) but no preload body (missing preloaded skills are silently omitted).

---

## 5. Limitations & Boundaries

1. **Tool vs. model behavior boundary:**
   - The fake API (`scripts/claude_namespace_fake_api.py`) deterministically scripts `tool_use` blocks (`Skill` then `Agent`/`Task`). This proves **Claude Code's CLI/runtime mechanics** (manifest parsing, namespace registration, `Skill` tool loading, `Agent`/`Task` `subagent_type` resolution, and `skills:` frontmatter injection into subagent requests). It does **not** measure LLM compliance with prose instructions inside a skill.
2. **Missing `skills:` frontmatter entries fail open:**
   - As shown by `preload-missing`, an unresolvable skill in an agent's `skills:` frontmatter is silently skipped at subagent launch without failing the `Agent`/`Task` call. CI validators (such as `scripts/validate.sh`) must continue to statically verify frontmatter skill references across split plugins.
3. **Network isolation scope:**
   - `npm view` and `npm install --prefix` contact `https://registry.npmjs.org` to fetch the pinned `@anthropic-ai/claude-code` packages into the ephemeral sandbox. During `claude` execution, `ANTHROPIC_BASE_URL` routes inference to `127.0.0.1` and telemetry/updater env vars are disabled, but process egress is not kernel-firewalled.
4. **Tool naming evolution (`Task` vs `Agent`):**
   - Both init events report `Task`, while both versions advertise `Agent` to the fake Messages API after normalizing the CLI tool selection. The harness inspects the advertised tool list in the request body and selects `Agent` when present or `Task` as fallback.

5. **Local directory marketplaces only:**
   - Both versions load these installed plugins from the lab source directories (latest explicitly reports `readFromFolder` as well as `installPath`). This verifies the requested user-scope local-marketplace path, not Git/remote updates, cache-only portability, dependency installation, or marketplace publication. The fixtures are left immutable after install.
6. **Streaming compatibility and request counts:**
   - The fake endpoint returns JSON even for streaming requests. Both tested CLIs retry non-streaming and complete successfully. Request counts therefore include repeated conversation snapshots; they are not counts of independent agent dispatches. Marker presence in request bodies, not counts or fake reply text, is the proof. No fixture body marker is present in initial description-only requests.
7. **Version gates and bounded evidence:**
   - The harness records CLI/subcommand help and gates required flags; unsupported paths are marked inconclusive, not passed. A resolved version without expected-behavior entries (duplicate-skill count) also exits nonzero as INCONCLUSIVE. Each CLI invocation is bounded at 75 seconds, each npm operation at 60/180 seconds, and each version matrix at 1500 seconds. `--keep` / `--output-dir` retain evidence; default EXIT cleanup removes only the unique mktemp lab, even on failure/signals. There is no OS network namespace or filesystem sandbox.
8. **Decision is a runtime prerequisite, not a migration implementation:**
   - Qualified dispatch/preloading is mechanically supported on the floor. Production generators/validators still need explicit cross-plugin reference handling and install/dependency policy, and real model routing requires a separately approved inference test. Bare lookup ambiguity with two distinct plugins defining the same skill basename was not tested. Do not ship a shared `ycc` manifest name or treat this spike as proof that users will install both plugins.

---

## 6. Reproduction, Evidence Index, and Validation

```bash
./scripts/test-claude-namespace-spike.sh --keep
# Optional, fixed versions:
./scripts/test-claude-namespace-spike.sh --keep --versions 2.1.143,2.1.300
# Existing parent under /tmp/opencode; implies retention:
./scripts/test-claude-namespace-spike.sh --output-dir /tmp/opencode
```

Historical verified run: `/tmp/opencode/claude-namespace-spike.MwyutO` (scanned then deleted as requested), exit 0, with both versions asserting `assert_matrix: all expectations verified` and the shell printing `VERIFIED: 2 of 2 requested versions; matrix assertions passed.`

- `transcript.log`: version resolution, binary hashes, probe summaries, final assertion results.
- `run-{2.1.143,latest}/transcript.log` and `logs/*.log`: sanitized argv/exit/stdout/stderr, installs, lists, init events, real tool results.
- `run-*/logs/*.requests.json`: actual request bodies received on loopback; no auth headers. Search body-only markers using the matching `fixture-proof.json`.
- `run-*/results.json`: init inventory, CLI tool results, parent/subagent marker booleans; `fixture-proof.json`: anti-masking invariants and source hashes.
- `config-before.json`, `config-after.json`, `config-proof.log`: hashes/mtime proof. **Sensitive local evidence:** these fingerprint credential files as well as settings (real paths, sizes, mtimes, SHA-256 digests and symlink targets). A digest of a credential file is still a credential fingerprint: do not publish or retain these files unnecessarily, even though file contents are not copied.

Sanitized evidence SHA-256 identifiers from that run:

| File                                              | SHA-256                                                            |
| ------------------------------------------------- | ------------------------------------------------------------------ |
| `transcript.log`                                  | `441cf33f5f9c90fc772885a5c6e0c0ec4c3e104caece73b43cfbd3dd177fb4aa` |
| `run-2.1.143/transcript.log`                      | `021def9e73061c1154655b9fc0488e0b747584b04c699494239ba44ce5901baa` |
| `run-2.1.143/results.json`                        | `cad77fa8cef81e5a473e6b5f8a4e726fa75459a403e252f921a02ce0773c4308` |
| `run-latest/transcript.log`                       | `1ad2391bc8f5cc9e52af00e71319dd72d42bef6e6962bce896aa32ab9bc243ff` |
| `run-latest/results.json`                         | `956808b803cbbb38c898d14ffeeb559a4dd2b41502070fd699d4fb93d75c94a1` |
| `run-latest/logs/preload-qualified.requests.json` | `f2fcfde31dacc48cb442d86dbc57b24d823d3b7d4bad45cb7e30a2127a65812c` |
| `run-latest/logs/preload-bare.requests.json`      | `409940b35643b06ef51a6ae482fb011882735e2b608bb437876ab1e59407146d` |
| `run-2.1.143/logs/missing-dispatch.requests.json` | `94ac799bf92aae7933985a37ab09a39513701ec271e98fb2ffebbe80aafc0858` |

```text
requested=2.1.143 resolved=2.1.143
2.1.143 assert_matrix: all expectations verified
requested=latest resolved=2.1.300
2.1.300 assert_matrix: all expectations verified
real-config hash/mtime unchanged: True entries: 48731
```

Targeted authoring checks: `bash -n scripts/test-claude-namespace-spike.sh`, `shellcheck scripts/test-claude-namespace-spike.sh` (installed `0.10.0`, matching repository pin), Python compile and `ruff check scripts/claude_namespace_fake_api.py`, scoped markdownlint/Prettier via `npm run lint:modified` / `npm run format:modified`. Full bundle sync/validation and real-auth/model inference are out of scope: no generated sources, skills, or agents were modified.

---

## 7. Review-Fix Addendum (assertions, fail-closed gate, hygiene)

All nine adversarial-review findings are addressed; every doc claim above is now machine-asserted, not manually inspected:

1. **Install/init evidence asserted:** `install()` records each `marketplace add` / `plugin install` / `plugin list` command and `check()`s exit 0; `verify_matrix()` asserts both same-named plugins appear in `init.plugins` with the exact expected `source` -> `name` mapping, the full `plugin list --json` inventory (IDs, `scope: user`, `enabled: true`), exact fixture skill/agent inventory per scenario, the version-specific duplicate-skill presentation (`EXPECTED_DUP_SKILL_COUNT = {"2.1.143": 2, "2.1.300": 1}`), and that no collision/conflict/duplicate diagnostic appears in any install or startup output (`assert_no_banned_diagnostics`).
2. **Fail-closed:** unsupported CLI flags now `raise SystemExit("INCONCLUSIVE: unsupported CLI flags")`; probe statuses and CLI exit 0 are checked per row; the shell requires the literal `<version> assert_matrix: all expectations verified` marker per requested version and prints `VERIFIED: N of N ...` only then — any missing marker, `set -e` failure, or unverified count exits nonzero.
3. **Marker geography:** each probe records separate maps for first parent request (full body incl. tools/system), child `system`, and child `messages`, plus tool descriptions; assertions require zero fixture markers in the first parent request and tool descriptions, the agent payload marker only in child `system`, and preload/local markers only in child `messages`.
4. **Tool-result specificity:** `missing-dispatch` selects the single `tool_result` with `tool_use_id == "toolu_ns_agent"` (`select_result`) and asserts `is_error`, the absent agent name, and `not found` in its content; `preload-missing` asserts its Agent/Task `tool_result` is **not** `is_error` while the preload marker is absent.
5. **Explicit `check()`:** all bare `assert`s were replaced by `check(label, expected, actual)` raising `SystemExit` with label/expected/actual; a `negative_self_test()` runs on every invocation proving `check()` fails closed (no weakened-mode flag exists).
6. **Process-group hygiene:** each Claude child starts with `start_new_session=True` and `run()` kills its process group on timeout/exception/finally; the outer driver runs in its own session (`os.setsid()`), publishes its PID to `driver.pid`, and the shell's EXIT trap forwards TERM then KILL to that group before deleting the lab. Remaining best-effort boundary: a process that deliberately detaches into another session, or an uncatchable SIGKILL of the driver before it cleans a child group, is not contained; this is process-group cleanup, not a cgroup/namespace sandbox. Signals during ordinary inference unwind Python and kill the separate Claude group before lab cleanup.
7. **Early trap / absolute paths:** the EXIT trap is installed immediately after `mktemp` and tolerates a missing before-snapshot (reports it and exits nonzero); `real_home`/`real_config` are resolved with `realpath -m` before any snapshot.
8. **Robustness/hygiene:** duplicate requested and duplicate resolved versions both `die`; the fake API caps requests at 32 MiB, returns HTTP 400 on invalid length/JSON, and does not log headers; snapshot walks use `os.walk(followlinks=False)` and never hash through symlinked directories.

**Negative gate proof (one-off, not committed):** a throwaway copy of the harness in `/tmp/opencode/yan1121-neg` mutated one expectation (`"mismatched-ab-shared": ({"b"}, {"b"}, set())`) and ran `./test-claude-namespace-spike.sh --keep --versions 2.1.300`, which exited `1` with:

```text
CHECK FAILED [mismatched-ab-shared parent payload]: expected={'b'} actual={'a'}
ERROR: matrix verification failed: 2.1.300 (look for CHECK FAILED above)
```

The mutated copy and its lab were deleted; the committed harness contains no flag that weakens assertions in normal runs.

**Retained-lab scan and deletion:** scanned `/tmp/opencode/claude-namespace-spike.MwyutO` with `grep -rl 'sk-ant-'` and `grep -rIl '/home/yandy'`. `sk-ant-` matches were limited to upstream vendor binaries/shims (opaque upstream key-prefix constants); the exact dummy key had no matches in captured evidence. Real-home matches were expected config-proof paths/digests plus npm's debug logs naming the Node/npm executable and its installation-level npmrc. There were no real-home paths in CLI/request evidence. No real credentials were passed to the subprocesses. The positive lab, negative lab/copy, and temporary runner logs were removed after inspection/hash extraction (`ls /tmp/opencode | grep claude-namespace` returned no labs). The committed evidence index is historical, not a promise of retained files.

---

## 8. Production Prep (YAN-1142, hidden)

The v7 split is built on demand, never committed, from unchanged `ycc/` source:

- `scripts/claude_agents_split.py --out DIR` writes `DIR/ycc` (skills and `_shared`; manifest `ycc`, lockstep version, `dependencies: ["ycc-agents"]`), `DIR/ycc-agents` (agents only), and a lab `DIR/.claude-plugin/marketplace.json`.
- It rewrites agent references with the package graph's own detector (`package_graph_extract.iter_references`). Dispatch values, `ycc:<agent>` mentions, and agent handoffs become `ycc-agents:<frontmatter-name>`, so `code-researcher.md` becomes `codebase-research-analyst`. Built-ins stay bare. `ycc:<skill>` and `/ycc:<skill>` stay unchanged.
- Dispatch values include every code span in a dispatch table column (Subagent Type, Plugin Agent Name, Teammate Type, Recommended/Primary/Supporting Agent), `subagent type`/`All N use` prose, and `- Agent:` fields.
- Bare agent frontmatter names are also rewritten in agent-naming contexts: any Markdown code span or table row, a heading that is only the name, list-item leads, parenthesized names, `→`/`->` targets, and quoted shell string literals. This covers orchestrate's recommendation table, task-breakdown arrows, catalog, `analyze-task.sh` suggestions, and `validate-agents.sh` `VALID_AGENTS`. The rule skips names that are also skills or built-ins, and plain prose.
- Bare names that are not agent references stay bare through a per-file allowlist (`ROLE_NAMES`). These are the `architect` persona in `plan/`, the `practices-researcher` teammate role in feature-research and prp-plan, the agent file stems in prp-plan's preflight, and the Cursor file-stem category keys in `init/scripts/generate-agent-catalog.sh`.
- `releaser` and `git-cleanup` are both skills and agents. Those mentions are rewritten only when followed by "agent".
- An unknown dispatch target fails the build.
- `--check` builds into a temporary directory and validates the result. It runs in the `claude-native` validation target.

Counts at 6.0.0: 49 skills and 55 agents. The build rewrites 162 dispatch tokens and 205 `ycc:<agent>` mentions or bare agent names in skills, plus 34 agent-to-agent handoffs. It keeps 16 built-in dispatches bare and finds 25 dispatching skills (graph closure, catalog edges excluded).

The validator checks that every dispatch, handoff, and mention resolves to a built-in or a `ycc-agents` frontmatter name. It also checks that:

- no `ycc:<agent>` token, bare plugin-agent dispatch, or bare agent name in the contexts above remains outside the allowlist;
- `ycc:<skill>` references resolve in the split `ycc`;
- the split `ycc` has no `agents/` directory and `ycc-agents` has no `skills/` directory;
- every dispatching skill still reaches an agent;
- agent `skills:` preloads are qualified `ycc:<skill>`.

It also warns about one known v7 blocker that has to be fixed before the flip. `skills/prp-plan/scripts/preflight-enhanced-agents.sh` checks `${PLUGIN_ROOT}/agents/<name>.md`, so `prp-plan --enhanced` would abort in the split `ycc`, which has no `agents/` directory. The fix is a `ycc/` source change in the v7.0.0 flip PR. Either drop the preflight, or make it check `${CLAUDE_PLUGIN_ROOT}/../ycc-agents/agents` or the installed `ycc-agents` plugin. Then remove the preflight entry from `ROLE_NAMES` and turn the warning into an error.

**Live harness** (`./scripts/test-claude-agents-split.sh [--keep]`, opt-in, uses `CLAUDE_BIN` or `claude` on PATH). It reuses this spike's `Lab` fake Messages API in an `env -i` lab and snapshots the real config before and after.

- Run against Claude Code **2.1.303** on 2026-10-19 (and earlier against 2.1.302), with the lab removed afterwards. The orchestrate probe is pinned to `ycc-agents:frontend-ui-developer` from its SKILL.md Recommended Agent table.
- `plugin install ycc@ycc-split-lab` also installed and enabled `ycc-agents` through `dependencies`.
- **25/25** dispatching skills passed `Skill(ycc:<skill>)` followed by `Agent(ycc-agents:<agent>)`. In each, the skill body reached the parent and the agent's own body was in the child `system` prompt. The four `disable-model-invocation` skills (backport, blueprint, clean, releaser) start from their slash command instead.
- The negative control `ycc-agents:absent` returned `is_error` ("Agent type 'ycc-agents:absent' not found") with no child request.
- The recorded bare probe `subagent_type: planner` did **not** resolve ("Agent type 'planner' not found"). Every plugin agent dispatch must therefore be qualified after the split.
- The real config was unchanged (`real-config hash/mtime unchanged: True`). One earlier run reported a changed entry because another Claude session on the same machine wrote to `~/.claude` mid-run; since YAN-2454 the guard skips that live-session state.
