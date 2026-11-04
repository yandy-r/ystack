# Pi (`pi`) Runtime Contract Spike (YAN-1182)

- **Date:** 2026-11-04
- **Issue:** `YAN-1182` (spike + ADR), gate `YAN-1181`; GitHub [#517](https://github.com/yandy-r/ystack/issues/517)
- **Target CLI:** `@earendil-works/pi-coding-agent` `1.5.0` (`pi --version` prints `1.5.0`), Node `v24.22.1`
- **Upstream:** [`earendil-works/pi`](https://github.com/earendil-works/pi) tag `v1.5.0`, commit `f9a26365568127461c47a07a37dcb42c140a3ac5` (2026-11-02)
- **Harness:** [`scripts/test-pi-runtime-contract-spike.sh`](../../../scripts/test-pi-runtime-contract-spike.sh) with fixtures and assertions in [`scripts/pi_runtime_spike.py`](../../../scripts/pi_runtime_spike.py)
- **Decision record:** [ADR 0003](../adr/0003-pi-runtime-contract.md)
- **ycc inventory:** worktree at `91131c1e` (main, v6.1.1): 49 skills plus `skills/_shared/{references,scripts}`, 55 agents, `ycc/rules/{common,golang,python,rust,typescript,web}` (37 rule files), and the packages in `ycc/settings/packages.json`.

Citation format: `path:line` is relative to the Pi repo at the pinned tag. `docs/` means `packages/coding-agent/docs/`, `src/` means `packages/coding-agent/src/`, and `CHANGELOG.md` means `packages/coding-agent/CHANGELOG.md`. `examples/` means `packages/coding-agent/examples/`. Claims that were neither run live nor read in upstream docs or source are labeled **[INFERENCE]**.

Verdict key: **native** (works as shipped), **adapter** (works once ycc generates a Pi-specific form), **fallback** (no Pi package mechanism; `install.sh` writes user config), **unsupported** (no way to reach parity), **excluded** (ycc deliberately ships no Pi form). For herdr, **native** means herdr's own Pi integration covers it.

## Executive Decisions

1. **Distribution: generated Pi packages, installed by path.**
   - A Pi package carries only extensions, skills, prompt templates, and themes (`docs/packages.md:3`, `src/core/package-manager.ts:233`). It cannot carry `mcp.json`, settings, rules, or agents.
   - Pi identifies a git package by repository URL without the ref (`docs/packages.md:151`). Two entries for one repo URL load only the first (live §1.3). There is no subdirectory git source (`src/utils/git.ts:172`). One ystack repo therefore yields one git package, not `ycc` + `ycc-mcp` + `ycc-rules`.
   - Local packages are identified by resolved absolute path and load without copying (`docs/packages.md:40`, `:151`). `install.sh` installs each generated `packages/pi/<pkg>/` by path (live §1.1).
2. **Agents need a ycc-owned subagent extension.** Pi ships no subagents (`README.md:19`, live §1.7). The upstream example works under a scripted model, but a verbatim ycc agent fails in the child: Claude model aliases do not resolve and Claude tool names enable no tools (live §1.7, §1.5).
3. **Hooks.** `WorktreeCreate` and `hooks/hooks.json` are **unsupported** (no reader, no event; §2.4). herdr is **native (herdr-owned)**: `herdr integration install pi` writes its own extension. `ycc-hooks` is **excluded** on Pi, as on OMP.
4. **MCP is an adapter.** The `mcp.json` format matches Claude `mcpServers` and the shipped `ycc-mcp` set parses unchanged (live §1.6). Packages cannot ship it, so `ycc-mcp` registers servers from an extension (`pi.registerMcpServer`, live §1.6) or `install.sh` merges `<agentDir>/mcp.json`.
5. **Trust.** User-scope packages, extensions, and MCP load with no prompt, as full-trust in-process code (`docs/security.md:3`). Project `.pi/*`, project packages, and project `.agents/skills` load only after project trust. Print, JSON, and RPC modes skip them unless `--approve` or `defaultProjectTrust: "always"` (live §1.4).
6. **Minimum version.** The supported floor is **1.2.0**: the lowest tested version that passes. The current harness passes on 1.2.0 and 1.5.0 (both re-run after review), and an earlier revision of it passed on 1.3.0 and 1.4.0. It rejects 1.0.4 and 1.0.0 at its version gate. 1.1.0 was not run, but it predates the `~` override fix (`CHANGELOG.md:263`, under `## [1.2.0]`). The recommended version is 1.5.0, which honours a saved "do not trust" decision (§4).
7. **Namespace.** Keep `ycc`. Pi accepts `ycc:<name>` prompt templates and extension commands (live §1.1). Skills stay unprefixed (`/skill:<name>`).

---

## 1. Live-Verified Facts (`pi 1.5.0`)

All observations come from `PI_BIN=<…>/node_modules/.bin/pi bash scripts/test-pi-runtime-contract-spike.sh --keep`. The 1.5.0 run printed 11 case `PASS` lines and then `PASS all YAN-1182 pi runtime-contract checks (pi 1.5.0, sandbox=bwrap-netns)`. A 1.2.0 run of the same harness printed the same 11 lines with one variant (§1.4).

**Sandbox:**

- **Environment:** every `pi` call runs as `env -i` with `PATH=<node bin>:/usr/local/bin:/usr/bin:/bin`. `HOME`, `XDG_*`, and `TMPDIR` point into a per-case tree under `mktemp -d /tmp/pi-runtime-contract-spike.XXXXXX`. A guard aborts if `HOME` would resolve outside the sandbox or under the real home.
- **Filesystem:** each call also runs as `bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs $REAL_HOME --tmpfs /run/user/$UID --ro-bind <node prefix> --ro-bind <pi package> --bind <sandbox> --unshare-net --`.
  - The host tree is read-only. The real home and the user runtime dir (agent and keyring sockets) are hidden, and only the sandbox root is writable.
  - The harness refuses to start when the Node prefix or the Pi package is `/` or contains the real home.
  - The bwrap preflight runs `/bin/true` under `env -i`. The run used `sandbox=bwrap-netns`. Without bwrap the harness exits 1 unless `--allow-env-i` is passed.
- **Fixture git** (repo init, tags, bare clones) runs in the same `env -i` + bwrap wrapper.
- **Host-side Python** (fixtures, transcript sanitizing, assertions) runs from the checkout's `scripts/pi_runtime_spike.py`, never from a sandbox-writable copy. Only the in-sandbox RPC driver uses the copy under the sandbox root.
- **Sanitizing:** transcripts replace the sandbox root with `<SANDBOX>` and the real home with `<HOME>`.
- **Network-off controls:** `PI_OFFLINE=1`, `PI_TELEMETRY=0`, `PI_SKIP_VERSION_CHECK=1`, and `npm_config_offline=true`. git is file-only: `GIT_ALLOW_PROTOCOL=file`, `GIT_CONFIG_GLOBAL=/dev/null`, and `url.file://<bare>.insteadOf` rewrites of `https://pi-spike.invalid/spike/{pkg,mono,dep}`.
- **Not applied to the OMP harnesses:** this filesystem layout is new here. The OMP harnesses still use `--dev-bind / /`; changing them is a follow-up outside this spike.
- **No inference:**
  - The default model is a null `openai-completions` provider on `127.0.0.1:9`. The probe extension aborts any run on it in `before_agent_start`, before a request.
  - Hook and subagent cases use pi-ai's in-process `fauxProvider` (`packages/ai/src/providers/faux.ts:709`), registered by an extension and answering from a fixed script.

**Introspection without a model:** the probe extension registers `/spike-probe`. Sent over `pi --mode rpc` it writes the following, from `ctx.getSystemPrompt()`, `ctx.getSystemPromptOptions()`, `ctx.isProjectTrusted()`, `pi.getAllTools()`, `pi.getActiveTools()`, and `pi.getCommands()` (`docs/extensions.md:1302`, `:1322`, `:1770`, `:1892`):

- the rendered system prompt;
- the context files;
- the trust decision;
- the tools;
- every command with its `sourceInfo` scope and origin.

`pi mcp list --json` and `pi list` need no session.

> **Per-run values:** `<SANDBOX>` paths, npm log names, and dates change on every run. Compare exit codes, messages, and layouts.

### 1.1 Packages: local path, manifest, filters, commands

| Command / probe                                                                       | Exit | Key output                                                                                                                                  |
| ------------------------------------------------------------------------------------- | ---- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `pi install <SANDBOX>/pkg` (conventional `extensions/`, `skills/`, `prompts/`)        | 0    | `Installed <SANDBOX>/pkg`; `settings.json` `"packages": ["../../../../../pkg"]` (relative to the agent dir)                                 |
| `pi list`                                                                             | 0    | `User packages:` / `../../../../../pkg` / `<SANDBOX>/pkg`                                                                                   |
| RPC `get_commands` via probe                                                          | 0    | `spike-ext`, `ycc:colon-ext` (extension), `spike-tpl`, `ycc:colon-tpl`, `ycc:chain` (prompt), `skill:spike-skill`                           |
| `/spike-tpl alpha "b c" d`                                                            | 0    | expanded prompt `TPL all=alpha b c d first=alpha rest=b c d`                                                                                |
| `/skill:ph one two`                                                                   | 0    | `<skill name="ph" …>` + body `PHBODY root=${CLAUDE_PLUGIN_ROOT} args=$ARGUMENTS` (both literal) + `</skill>\n\none two` appended (asserted) |
| `/ycc:chain x y` (template whose body is `/skill:ph $ARGUMENTS`)                      | 0    | expanded prompt `/skill:ph x y`: the skill is **not** re-expanded                                                                           |
| `/ycc:ext-chain z` (extension command, `sendUserMessage(…, {expandPromptTemplates})`) | 0    | expanded prompt starts `<skill name="ph"`: the skill **is** expanded                                                                        |
| `pi install <SANDBOX>/mpkg` (`package.json#pi` lists `extensions` and `skills` only)  | 0    | `man-ext`, `skill:man-skill` load; conventional `prompts/conv-tpl.md` and `skills/conv-skill` do **not**                                    |
| settings object `{"source":…pkg,"skills":["skills/spike-skill"],"prompts":[],…}`      | 0    | `pi list` marks `(filtered)`; only `skill:spike-skill` loads from the package                                                               |

### 1.2 Project scope and identity

| Command (cwd = git repo `proj/`)                                                                                  | Exit | Key output                                                              |
| ----------------------------------------------------------------------------------------------------------------- | ---- | ----------------------------------------------------------------------- |
| `pi install -l <SANDBOX>/mpkg` (untrusted)                                                                        | 1    | `Project is not trusted. Use --approve to modify local package config.` |
| `pi install -l --approve <SANDBOX>/mpkg`                                                                          | 0    | `proj/.pi/settings.json` gains `"../../mpkg"`                           |
| same package also in user settings (`install` rc 0, user `packages` = `["../../../../../mpkg"]`); RPC `--approve` | 0    | exactly one `man-ext`, `scope: project`, `origin: package`              |
| `pi remove -l --approve <SANDBOX>/mpkg`                                                                           | 0    | entry removed                                                           |

### 1.3 git packages

| Command                                                                                          | Exit | Key output                                                                                                                                                   |
| ------------------------------------------------------------------------------------------------ | ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `pi install git:pi-spike.invalid/spike/pkg@v0.0.1` (repo has a `main-only` commit after the tag) | 0    | `Note: switching to 'v0.0.1'.`, `Installed git:pi-spike.invalid/spike/pkg@v0.0.1`; checkout `HEAD` equals the tag commit and `main-only` is absent           |
| `pi update git:…@v0.0.1`; `pi update --extensions`                                               | 0    | `Updated packages`                                                                                                                                           |
| `pi install git:…/dep` (`dependencies: {left-pad}`, npm offline)                                 | 1    | `npm error code ENOTCACHED`, `Error: npm install --omit=dev --legacy-peer-deps --no-audit --no-fund failed with code 1`; checkout removed, no settings entry |
| `pi install git:…/mono` (root `package.json` with `scripts.prepare`)                             | 0    | `<SANDBOX>/prepare-ran` exists: npm ran the package `prepare` script                                                                                         |
| two settings entries for `git:…/mono` (different skill filters)                                  | 0    | only the first entry's skill loads (`skill:rule-skill`, not `skill:mono-skill`)                                                                              |
| `pi remove git:…@v0.0.1`                                                                         | 0    | `Removed git:pi-spike.invalid/spike/pkg@v0.0.1`; checkout deleted; `packages: []`                                                                            |

### 1.4 Project trust, context files, system-prompt files

Fixture project: `.pi/{settings.json,mcp.json,extensions/proj.ts,skills/proj-skill,prompts/proj-tpl.md,APPEND_SYSTEM.md}`, `.agents/skills/agents-proj`, `AGENTS.md`, `CLAUDE.md`. The user agent dir also has `AGENTS.md` and `APPEND_SYSTEM.md`.

| RPC session                            | `isProjectTrusted` | Project extensions/prompts/skills/MCP                                    | `.agents/skills` (project) | Context in prompt                                                   |
| -------------------------------------- | ------------------ | ------------------------------------------------------------------------ | -------------------------- | ------------------------------------------------------------------- |
| no flag (`defaultProjectTrust: "ask"`) | `false`            | none                                                                     | none                       | user + project `AGENTS.md`; user `APPEND_SYSTEM.md`; no `CLAUDE.md` |
| `--no-approve`                         | `false`            | none                                                                     | none                       | same                                                                |
| `--approve`                            | `true`             | `proj-ext`, `proj-tpl`, `skill:proj-skill`, `mcp__projmcp__projmcp_ping` | `skill:agents-proj`        | project `APPEND_SYSTEM.md` **replaces** the user one                |
| `defaultProjectTrust: "always"`        | `true`             | `proj-ext` loads                                                         | —                          | —                                                                   |

- `pi mcp list --json` in the untrusted project prints `"note": "<SANDBOX>/proj/.pi/mcp.json is ignored because the project is not trusted. …"`. `pi mcp add -l projx …` succeeds and says the file is ignored until trusted.
- A folder with only `AGENTS.md` and a saved `trust.json` `false`: `AGENTS.md` loads and `isProjectTrusted` is `false`. The same check on 1.2.0–1.4.0 reports `true` (the harness logs `IGNORED before 1.5.0`), which matches `CHANGELOG.md:42`.
- `<agentDir>/SYSTEM.md` replaces the base prompt (`USERSYSTEMMARK`, no `coding assistant` text). `APPEND_SYSTEM.md` and context files still follow.

### 1.5 Skills

| Probe                                                   | Observed                                                                                                                         |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `~/.agents/skills/agents-user`                          | loaded, `scope: user`, `origin: top-level`                                                                                       |
| `dup2` in `~/.pi/agent/skills` and `~/.agents/skills`   | prompt lists `USER-DUP2`; the `~/.agents` copy is dropped                                                                        |
| `dup` in `~/.agents/skills` and an installed package    | prompt lists `AGENTS-DUP`; the package copy is dropped (no namespacing)                                                          |
| name `Bad_Name`; description of 1100 chars              | both load. The load-time warnings are **not asserted**: RPC does not surface them                                                |
| no `description`                                        | not loaded                                                                                                                       |
| `disable-model-invocation: true`                        | `skill:hidden` command exists; description absent from the prompt                                                                |
| settings `"skills": ["-~/.agents/skills/dup/SKILL.md"]` | prompt lists `PKG-DUP`: the package copy wins once the alias is excluded                                                         |
| `--tools Read,Grep,Glob` (Claude-cased)                 | `pi.getActiveTools()` is `[]`                                                                                                    |
| built-in tools                                          | `read bash edit write grep find ls codemode tool_search` asserted present; no `subagent`/`task` (the list also has `powershell`) |

### 1.6 MCP

| Command / probe                                                          | Exit | Key output                                                                                                   |
| ------------------------------------------------------------------------ | ---- | ------------------------------------------------------------------------------------------------------------ |
| `pi mcp add spikemcp -- python3 stub.py spikemcp`                        | 0    | writes `<agentDir>/mcp.json`                                                                                 |
| `pi mcp list --json`                                                     | 0    | `"state": "connected"`, `"exposure": "codemode"`, `"tools": ["spikemcp_ping"]`, `"errors": []`               |
| `mcp.json` with `{"type":"sse",…}`                                       | 1    | `server "badsse": legacy SSE transport is not supported; use the streamable HTTP URL`                        |
| shipped `packages/claude/ycc-mcp/.mcp.json`, each server `enabled:false` | 0    | 10 servers, all `"state": "disabled"`, `"errors": []`; stdio (`sh -c …`, `npx …`) and http transports parsed |
| RPC with an extension calling `pi.registerMcpServer("extmcp", …)`        | 0    | tools `mcp__spikemcp__spikemcp_ping`, `mcp__extmcp__extmcp_ping`                                             |
| same extension, `ctx.ui.setStatus("ycc","STATUSMARK")`                   | 0    | RPC `{"type":"extension_ui_request",…,"method":"setStatus","statusKey":"ycc","statusText":"STATUSMARK"}`     |

### 1.7 Extensions, hooks, subagents, roots

| Probe                                                                                    | Exit | Key output                                                                                                      |
| ---------------------------------------------------------------------------------------- | ---- | --------------------------------------------------------------------------------------------------------------- |
| `-e broken.ts` (factory throws)                                                          | 1    | `Error: Failed to load extension "<SANDBOX>/ext/broken.ts": Failed to load extension: BROKENEXT`                |
| installed package whose extension throws                                                 | 1    | `Failed to load extension … BROKENPKG`: one broken package stops startup                                        |
| scripted model calls `bash touch <marker>`; extension `tool_call` returns `{block:true}` | 0    | marker absent; the model receives `BLOCKED-BY-SPIKE`; events `session_start`, `tool_call:bash`, `agent_settled` |
| `-e examples/extensions/subagent/index.ts`, scripted `subagent {agent:"scout"}`          | 0    | parent's next turn: `PARENT-DONE CHILD-DONE` (child `pi` ran from `<agentDir>/agents/scout.md`)                 |
| same, agent `code-reviewer` copied verbatim from `ycc/agents/`                           | 0    | `PARENT-DONE Agent failed: No API key found for amazon-bedrock.` (`model: sonnet` resolved to a Bedrock model)  |
| `PI_CODING_AGENT_DIR=<case>/alt-agent pi install …`                                      | 0    | `alt-agent/settings.json` carries the package; `~/.pi/agent/settings.json` untouched                            |

**Manual check (not in the harness):** in a bwrap sandbox with a temporary `HOME`, `herdr integration install pi` exits 1 with `pi extension directory not found at …/.pi/agent/extensions. install pi first`. Once that directory exists it writes `~/.pi/agent/extensions/herdr-agent-state.ts`, headed `// installed by herdr`, `HERDR_INTEGRATION_ID=pi`, `HERDR_INTEGRATION_VERSION=8`. It reports `source = "herdr:pi"` from `session_start`, `agent_start`, and `agent_settled`.

---

## 2. Upstream Contract (`v1.5.0`)

### 2.1 Packages

- **Sources:** `npm:`, `git:`, git URLs, and local paths. Local paths load in place; relative entries resolve from the settings file (`docs/packages.md:9-44`).
- **Layout:** conventional `extensions/`, `skills/`, `prompts/`, `themes/`, or `package.json#pi` with paths and globs relative to the package root (`docs/packages.md:48-76`). A manifest that names any resource type replaces conventional discovery (live §1.1; `src/core/package-manager.ts:687`).
- **Scopes:** personal installs go to `~/.pi/agent/settings.json`; `-l` writes `.pi/settings.json`, read only after trust (`docs/packages.md:21-23`; `docs/cli.md:267`).
- **Filters:** the object form narrows each type with globs, `!`, `+`, and `-`; it never exposes undeclared resources (`docs/packages.md:118-143`). The project entry replaces the personal entry, or acts as a delta with `autoload: false` (`:149`).
- **Identity:** npm by package name, git by repo URL without the ref, local by absolute path (`docs/packages.md:151`).
- **git installs:** clone to `<agentDir>/git/<host>/<path>` (project: `.pi/git/…`), check out the ref, then run `npm install --omit=dev --legacy-peer-deps --no-audit --no-fund` when `package.json` exists (`src/core/package-manager.ts:2008-2040`, `:1946`, `:2293-2314`). A failure removes the checkout (`:2035-2038`).
- **Dependencies:** runtime imports go in `dependencies`. Host packages (`@earendil-works/pi-*`, `typebox`) go in `peerDependencies: "*"` and never in `dependencies` (`docs/packages.md:100-116`). Other Pi packages cannot be depended on except by bundling (`:114`).
- **Startup failure:** a configured package that fails to _install_ is skipped with a warning (`docs/packages.md:19`). A package extension that _throws_ stops startup (live §1.7).

### 2.2 Extensions

- **Factory:** a TypeScript/JavaScript default export `(pi: ExtensionAPI) => void | Promise<void>`, loaded through jiti (`docs/extensions.md:186-213`). It must not start long-lived resources (`:254-256`).
- **Locations:** `~/.pi/agent/extensions/*.ts`, `*/index.ts`, `*/package.json#pi.extensions`, project `.pi/extensions/` (trusted only), settings `extensions`, and `-e` (`docs/extensions.md:123-153`).
- **API used by ycc adapters:**
  - registration: `registerTool`, `registerCommand`, `registerMcpServer`, `registerProvider`;
  - actions: `sendUserMessage` with `expandPromptTemplates`, `exec`;
  - context: `getCommands`, `getAllTools`/`setActiveTools`, `ctx.getSystemPromptOptions`, `ctx.isProjectTrusted`, `ctx.ui.{select,confirm,input,notify,setStatus,setWidget,setFooter}`, `ctx.executeTool` (`docs/extensions.md:1565-2124`, `:2738-2779`, `:2871-2915`).
- **Events:**
  - `project_trust` (user and CLI extensions only);
  - `session_start`/`session_shutdown`;
  - `before_agent_start`, which can change sections or the prompt;
  - `tool_call`, which can block or mutate input; `tool_result`, which can patch the result;
  - `turn_end`, `agent_settled`, `input`, `resources_discover` (`docs/extensions.md:307-1160`).
- **MCP tool calls** pass through `tool_call` and `tool_result` (`docs/mcp.md:254`).

### 2.3 Skills, prompt templates, context

- **Skills** follow the Agent Skills spec. `~/.agents/skills` and ancestor `.agents/skills` are discovered (the project ones only when trusted). Name ≤64 characters, lowercase and hyphen; description ≤1024 characters, warnings only. A missing description skips the skill; on a collision the first skill wins with a warning (`docs/skills.md:59-85`; `src/core/skills.ts:14`, `:304-345`; `src/core/package-manager.ts:2604-2720`).
- `/skill:name args` appends `args` after the skill block (`docs/skills.md:47`). `disable-model-invocation` hides the skill from the prompt, and the command stays (`:53`; `src/core/skills.ts:352-359`). `enableSkillCommands` is a setting (`docs/settings.md:160`).
- **Prompt templates:** the file name is the command name. They support `$1`, `$@`, `$ARGUMENTS`, `${1:-d}`, `${@:N}`, and `${@:N:L}`. Conventional dirs load direct `.md` children only (`docs/prompt-templates.md:19-59`). Templates expand after the `input` event and are not re-expanded (`docs/extensions.md:1116-1121`, live §1.1).
- **Context files:** `AGENTS.override.md`, `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD` (first per directory), loaded from the agent dir, cwd, and ancestors regardless of trust (`src/core/resource-loader.ts:213`; `docs/configuration.md:41-47`; `docs/security.md:57`).
- **System prompt files:** `SYSTEM.md` replaces and `APPEND_SYSTEM.md` appends. The trusted project file takes precedence over the agent-dir file, and the two are never combined (`docs/configuration.md:19-39`).

### 2.4 Hooks and worktrees

- `git grep -F hooks.json -- packages/` and `git grep -F WorktreeCreate -- packages/` both exit 1 at the tag.
- No extension event creates worktrees (`docs/extensions.md:307-408`).
- Pi's only worktree logic is context-file shadowing for nested linked worktrees (`src/core/resource-loader.ts:233-258`; `CHANGELOG.md:257`).

### 2.5 MCP

- **Files:** `~/.pi/agent/mcp.json` and `.pi/mcp.json` (the latter only when trusted). A project entry replaces a user entry, or overrides `enabled` and exposure only (`docs/mcp.md:30-42`).
- **Servers:**
  - stdio uses `command`, `args`, `env`, and `cwd`; HTTP uses `url`, `headers`, and `oauth`. SSE is rejected.
  - `timeout` is in seconds.
  - `env` and `headers` accept `${VAR}` and `!command` (`docs/mcp.md:62-82`).
- **Names:** server names may use letters, digits, `_`, and `-`. Tools are `mcp__<server>__<tool>` with every other character turned into `_`; `-` and `_` server names collide (`docs/mcp.md:77`; `CHANGELOG.md:524`).
- **Exposure:** the default is `codemode`, so tools are not declared to the model. `direct`, `deferred`, and `hidden` exist, plus per-tool `toolExposure` (`docs/mcp.md:191-232`).
- **Extensions:** `pi.registerMcpServer` registrations are per session, and a file-configured server with the same name wins. `pi mcp` shell commands never see them (`docs/mcp.md:260-264`; `docs/extensions.md:2780-2793`). An extension that registers `/mcp` replaces the built-in support (`docs/mcp.md:266-270`).

### 2.6 Settings, models, approvals

- **Settings:** user `<agentDir>/settings.json` and project `.pi/settings.json`. The project overrides scalars, and resource lists combine (`docs/settings.md:3`). `defaultProjectTrust` is valid only in the agent dir (`:36`).
- **Models:** `defaultProvider`, `defaultModel`, `enabledModels`, `defaultThinkingLevel`, `modelThinkingLevels` (`docs/settings.md:11-21`), and `models.json` providers (`docs/models.md:45-67`). There are no model roles and no per-subagent model setting.
- **Approvals:** Pi "does not ask for approval before every tool call" (`docs/security.md:3`). Gating is an extension `tool_call` handler (`docs/extensions.md:2752-2764`).
- **Agent dir:** `PI_CODING_AGENT_DIR` relocates it (`docs/configuration.md:9`; live §1.7).

### 2.7 Subagents

- **No built-in subagents.** "Pi ships with powerful defaults but skips features like sub-agents and plan mode" (`README.md:19`).
- **Example extension:** `examples/extensions/subagent/` registers a `subagent` tool with single, parallel (max 8, 4 concurrent), and chain modes (`examples/extensions/subagent/README.md:91-97`).
  - Each run spawns `pi --mode json -p --no-session [--model] [--tools]` through `process.execPath` (`index.ts:247-257`, `:298-304`).
  - Agents come from `<agentDir>/agents/*.md` and, with `agentScope`, `.pi/agents` (`agents.ts:119-129`).

### 2.8 Security and trust model

- **Protected resources:** the trust gate covers `.pi/{settings.json,mcp.json,extensions,skills,prompts,themes,SYSTEM.md,APPEND_SYSTEM.md}` and project `.agents/skills` (`docs/security.md:35-55`; `src/core/trust-manager.ts:30`).
- **Decision order:**
  1. a CLI `--approve` or `--no-approve` flag;
  2. a user or CLI extension's `project_trust` handler;
  3. the nearest saved decision in `~/.pi/agent/trust.json`;
  4. `defaultProjectTrust`.

  Non-interactive modes treat `ask` as no (`docs/security.md:59-82`).

- **Not a full boundary:** `sessionDir` is read before trust (`docs/security.md:31`), and context files load untrusted (`:57`).
- **Extensions and packages** run with the user's permissions and no sandbox (`docs/security.md:3`, `:90`; `docs/extensions.md:7`). 1.5.0 removed the OS sandbox example (`CHANGELOG.md:117`).

**Trust model for ycc:** every ycc Pi extension (subagent dispatcher, MCP registrar, command wrappers, rules injector) and every MCP command is full-trust code. Pi prompts for none of it at user scope. A throwing factory stops Pi from starting, so each factory must be side-effect-free and must not throw at load. Missing dependencies must surface as tool errors.

### 2.9 Landing versions

| Needed feature                                                        | Landed | Evidence                                            |
| --------------------------------------------------------------------- | ------ | --------------------------------------------------- |
| `disable-model-invocation`                                            | 0.50.0 | `CHANGELOG.md:4268`                                 |
| `~/.agents/skills` and `.agents/skills` auto-discovery                | 0.54.0 | `CHANGELOG.md:3689`                                 |
| Project trust gate, `--approve`/`--no-approve`, `project_trust` event | 0.79.0 | `CHANGELOG.md:1987-1995`                            |
| `defaultProjectTrust`, `ctx.isProjectTrusted()`                       | 0.79.1 | `CHANGELOG.md:1951-1959`                            |
| Built-in MCP, `pi mcp`, `pi.registerMcpServer`, codemode              | 0.99.0 | `CHANGELOG.md:556`                                  |
| MCP `-` to `_` tool-name normalization                                | 0.99.2 | `CHANGELOG.md:524`                                  |
| `--no-mcp`                                                            | 1.0.4  | `CHANGELOG.md:346`                                  |
| `~` in `!`/`+`/`-` resource override entries                          | 1.2.0  | `CHANGELOG.md:263`; live: 1.0.4 fails §1.5 override |
| Saved "do not trust" honoured for context-only folders                | 1.5.0  | `CHANGELOG.md:42`; live §1.4                        |
| Tool argument validation on pi-schema (TypeBox refinements not run)   | 1.5.0  | `CHANGELOG.md:14`                                   |

---

## 3. Component → Verdict Matrix

| ycc component                                                           | Claude form today                                                         | Pi surface                                                                       | Verdict                                        | Required work                                                                                                                                                                                                                                                                                                                                                | Evidence            |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------- |
| Catalog / distribution                                                  | root `.claude-plugin/marketplace.json`                                    | Pi packages (`pi install <path\|git\|npm>`)                                      | **adapter**                                    | Generate `packages/pi/<pkg>/` with `package.json#pi`. Install by absolute path. One git URL is one package, so a remote git install is a single root package or npm packages.                                                                                                                                                                                | §1.1, §1.3, §2.1    |
| Plugin manifest                                                         | `ycc/.claude-plugin/plugin.json`                                          | `package.json` (`pi` key, `version`, `peerDependencies`)                         | **adapter**                                    | Lockstep `version`; host packages as `peerDependencies: "*"`; no `dependencies` (npm runs at git install and fails offline).                                                                                                                                                                                                                                 | §1.3, §2.1          |
| Skills, auto-invocable (40 of 49)                                       | `skills/<n>/SKILL.md`                                                     | package `skills/`                                                                | **native** discovery / **adapter** bodies      | All 49 names and descriptions pass Pi limits. Rewrite `${CLAUDE_PLUGIN_ROOT}` (102 files under `ycc/skills`), `/ycc:` references (70 files), and body `$ARGUMENTS` (39 files): Pi leaves all three literal and appends arguments.                                                                                                                            | §1.1, §1.5, §2.3    |
| Skills, hidden (9 with `disable-model-invocation: true`)                | hidden from the model                                                     | same key                                                                         | **native**                                     | Keep the key.                                                                                                                                                                                                                                                                                                                                                | §1.5                |
| Skill `allowed-tools`, `argument-hint`                                  | Claude hints                                                              | `allowed-tools` experimental, `argument-hint` templates only                     | **unsupported** (ignored, harmless)            | None.                                                                                                                                                                                                                                                                                                                                                        | `docs/skills.md:78` |
| `skills/_shared/` (`references/`, `scripts/`)                           | `${CLAUDE_PLUGIN_ROOT}/skills/_shared/…`                                  | files inside the package                                                         | **adapter**                                    | Ship inside the package and rewrite to paths relative to the skill dir. Pi tells the model to resolve relative paths against the skill dir. [INFERENCE] `_shared/` is not discovered as a skill because it has no `SKILL.md`.                                                                                                                                | §2.3                |
| Public command entrypoints                                              | `/ycc:<skill>` (Claude plugin prefix)                                     | prompt templates and extension commands named `ycc:<name>`                       | **adapter**                                    | A template that emits `/skill:x` is not expanded. Use an extension command that calls `sendUserMessage("/skill:x …", {expandPromptTemplates:true})`, or a template that inlines the skill instruction.                                                                                                                                                       | §1.1                |
| Agents (55)                                                             | `agents/*.md`: Claude `tools`, `model` `sonnet`/`opus`/`inherit`, `color` | none built in                                                                    | **adapter** (ycc subagent extension)           | A ycc-owned TypeScript `subagent` tool: load agents from the package (not `<agentDir>/agents`), map tool names (`Read`→`read`, `Grep`→`grep`, `Glob`→`find`/`ls`, `Bash`→`bash`, `Edit`/`Write`; `WebSearch`/`WebFetch`/`NotebookEdit` have no built-in), and map models through ycc settings. Spawn child `pi` runs. The upstream example is the reference. | §1.5, §1.7, §2.7    |
| Workflow: questions                                                     | `AskUserQuestion`                                                         | `ctx.ui.select/confirm/input` (TUI and RPC)                                      | **adapter**                                    | Expose a question tool from the extension, or degrade to plain text in `-p`.                                                                                                                                                                                                                                                                                 | §2.2                |
| Workflow: background jobs, parallel fan-out                             | Claude background tasks                                                   | subagent parallel mode; no background jobs                                       | **adapter** / **unsupported** (background)     | Parallel through the ycc subagent tool; no detached jobs.                                                                                                                                                                                                                                                                                                    | §2.7                |
| Worktrees (`.claude/worktrees`, `git worktree add` in bodies)           | `WorktreeCreate` hook                                                     | `bash` + git                                                                     | **fallback**                                   | Bodies run `git worktree add` under `.pi/worktrees/` [INFERENCE]; subagent `cwd` points there. Context-file shadowing for nested worktrees is native.                                                                                                                                                                                                        | §2.4                |
| Artifact store (`.ycc/artifacts/`, Linear default)                      | shell helpers + Linear MCP                                                | `bash` + MCP                                                                     | **native** helpers / **adapter** MCP reach     | The helpers run unchanged under `bash`. Linear tools default to `codemode` exposure and are renamed `mcp__linear_personal__…`. Set `exposure`/`toolExposure` and rewrite tool names in skills.                                                                                                                                                               | §1.6, §2.5          |
| `ycc-mcp` `.mcp.json` (10 servers)                                      | Claude plugin MCP                                                         | `mcp.json` (user/project) or `pi.registerMcpServer`                              | **adapter**                                    | Packages cannot ship `mcp.json`. Use an extension that registers the 10 servers (a same-name file entry wins), or a `fallback` merge into `<agentDir>/mcp.json`. The format parses unchanged; `${XERO_*}` env works; no SSE.                                                                                                                                 | §1.6, §2.5          |
| `worktree-create.sh` (`WorktreeCreate`)                                 | `hooks/hooks.json`                                                        | none                                                                             | **unsupported**                                | No hooks reader and no worktree event.                                                                                                                                                                                                                                                                                                                       | §2.4                |
| HOOKS.PreToolUse                                                        | Claude `PreToolUse` shell hook                                            | extension `tool_call` (can block or mutate)                                      | **adapter** (TS only; matrix: partial)         | Shell hooks never run. A TypeScript handler gates calls; the harness blocked a scripted `bash` call and the reason reached the model (§1.7). ycc ships no hook port (`ycc-hooks` excluded).                                                                                                                                                                  | §1.7, §2.2          |
| HOOKS.PostToolUse                                                       | Claude `PostToolUse` shell hook                                           | extension `tool_result` (can patch the result)                                   | **adapter** (TS only; matrix: partial)         | Documented (`docs/extensions.md:1038-1072`). The handler was registered but not reached, because the call was blocked first.                                                                                                                                                                                                                                 | §2.2                |
| HOOKS.Stop                                                              | Claude `Stop` shell hook                                                  | extension `agent_settled` / `agent_before_settle`                                | **adapter** (TS only; matrix: partial)         | `agent_settled` fired in the scripted session (§1.7).                                                                                                                                                                                                                                                                                                        | §1.7, §2.2          |
| INSTALL_PATH                                                            | `install.sh` + native plugin installs                                     | `pi install <abs path>` (user) / `-l --approve` (project), `PI_CODING_AGENT_DIR` | **adapter** (matrix: partial)                  | `install.sh --target pi` drives `pi install/remove`. User scope writes `<agentDir>/settings.json` with a relative entry; project scope needs trust; the agent dir can move (§1.1, §1.2, §1.7). There is no catalog. A remote install needs YAN-1188's distribution decision.                                                                                 | §1.1, §1.2, §1.7    |
| herdr session reporting                                                 | herdr-managed Claude integration                                          | `herdr integration install pi`                                                   | **native** (herdr-owned)                       | ycc ships none (manual check §1.7).                                                                                                                                                                                                                                                                                                                          | §1.7                |
| `ycc/settings/hooks/herdr-agent-state.sh`                               | `# installed by herdr`                                                    | none                                                                             | **n/a** (not ycc-owned)                        | —                                                                                                                                                                                                                                                                                                                                                            | —                   |
| Rules `common/` (always rules)                                          | Cursor/OMP rules; Claude `install.sh`                                     | context files (`AGENTS.md`), `APPEND_SYSTEM.md`, extension sections              | **fallback** (`AGENTS.md`) / **adapter**       | `install.sh --rules` links `<agentDir>/AGENTS.md`. Do not use `APPEND_SYSTEM.md`: a trusted project's file replaces it. An extension may inject sections in `before_agent_start`.                                                                                                                                                                            | §1.4, §2.3          |
| Rules `golang/`, `python/`, `rust/`, `typescript/`, `web/` (path rules) | `paths:` frontmatter                                                      | none native                                                                      | **adapter**                                    | Extension: on `tool_call`/`tool_result` for `edit`/`write`/`read` paths matching a family glob, inject that family's rules (OMP TTSR-trigger analogue). Not exercised live.                                                                                                                                                                                  | §2.2                |
| `ycc/settings/rules/{CLAUDE,AGENTS}.md`                                 | `install.sh` instructions                                                 | `<agentDir>/AGENTS.md` native context file                                       | **fallback**                                   | Link as above.                                                                                                                                                                                                                                                                                                                                               | §1.4                |
| `ycc/settings/models.json`, model pins                                  | Claude `settings.json` model                                              | `defaultProvider`/`defaultModel`; no roles                                       | **fallback** (main) / **adapter** (subagents)  | Opt-in `install.sh --settings` merge of `defaultModel`; subagent models resolved by the ycc extension from a `targets.pi` table. Verbatim `sonnet` resolves to Bedrock (§1.7).                                                                                                                                                                               | §1.7, §2.6          |
| `ycc/settings/settings.json` (permissions, env, statusLine)             | Claude user settings                                                      | `settings.json` (no permission model)                                            | **fallback** / DANGEROUS_MODE **unsupported**  | No approval modes exist; an optional `tool_call` gate extension is the only analogue.                                                                                                                                                                                                                                                                        | §2.6                |
| Status line (`statusline-command.sh`)                                   | `statusLine: {type:"command"}`                                            | `ctx.ui.setStatus`/`setWidget`/`setFooter`                                       | **unsupported** as is / **adapter** (rewrite)  | No command-backed status line. `setStatus` reaches RPC (§1.6). A port is new TypeScript.                                                                                                                                                                                                                                                                     | §1.6, §2.2          |
| Status-bar mod (`ycc/mods/status-bar`, `ycc-mods`)                      | Claude Code mod API                                                       | `ExtensionAPI` UI                                                                | **unsupported** as is / **adapter** (rewrite)  | Out of the `ycc` lockstep; never copy the mod.                                                                                                                                                                                                                                                                                                               | §2.2                |
| Package `ycc`                                                           | `./ycc`                                                                   | generated Pi package                                                             | **adapter**                                    | Skills, `_shared`, command wrappers, subagent extension, agents data.                                                                                                                                                                                                                                                                                        | rows above          |
| Package `ycc-mcp`                                                       | `./packages/claude/ycc-mcp`                                               | extension package                                                                | **adapter**                                    | Registrar extension; no secrets in the package.                                                                                                                                                                                                                                                                                                              | §1.6                |
| Package `ycc-hooks`                                                     | `./packages/claude/ycc-hooks`                                             | none                                                                             | **excluded**                                   | herdr native; `WorktreeCreate` unsupported.                                                                                                                                                                                                                                                                                                                  | §2.4                |
| Package `ycc-rules`                                                     | Cursor/OMP                                                                | extension package                                                                | **adapter**                                    | Path-rule injector + rule files.                                                                                                                                                                                                                                                                                                                             | §2.2                |
| Package `ycc-all`                                                       | Claude meta plugin                                                        | none                                                                             | **fallback**                                   | Pi packages cannot depend on Pi packages; install the parts.                                                                                                                                                                                                                                                                                                 | §2.1                |
| Package `ycc-agents`                                                    | deferred to v7 (ADR 0001)                                                 | none                                                                             | **n/a**                                        | Agents ship inside `ycc`.                                                                                                                                                                                                                                                                                                                                    | ADR 0001            |
| Package `@yandy-r/ycc-opencode`                                         | opencode npm plugin                                                       | none                                                                             | **n/a**                                        | opencode-specific API.                                                                                                                                                                                                                                                                                                                                       | —                   |
| Package `installer-fallback`                                            | `install.sh` copies                                                       | `<agentDir>` files                                                               | **fallback**                                   | `AGENTS.md` link, `settings.json`/`mcp.json` merges, `~/.agents` dedupe overrides; user scope only.                                                                                                                                                                                                                                                          | §1.4, §1.5          |
| `install.sh` `agents` target (`~/.agents/skills`)                       | cross-tool copies                                                         | auto-discovered, outranks package skills                                         | **adapter** (dedupe)                           | Owned `skills: ["-~/.agents/skills/<n>/SKILL.md"]` entries for ycc-installed skills (needs ≥1.2.0).                                                                                                                                                                                                                                                          | §1.5                |
| `ycc/evals/`, `mcp-configs/mcp.json`, Cursor settings                   | maintainer inputs                                                         | —                                                                                | **n/a** (`mcp-configs` is the `ycc-mcp` input) | —                                                                                                                                                                                                                                                                                                                                                            | —                   |

---

## 4. Minimum Supported Version

Runs of the harness as committed:

| Version | Result                                                                                                        |
| ------- | ------------------------------------------------------------------------------------------------------------- |
| 1.5.0   | PASS (11 case lines + PASS all); the saved distrust is honoured                                               |
| 1.2.0   | PASS (11 case lines + PASS all); logs `a saved "no" for a folder with only AGENTS.md is IGNORED before 1.5.0` |
| 1.0.4   | exit 1 at the version gate: `ERROR: pi >=1.2.0 (stable version string) required, got '1.0.4'`                 |
| 1.0.0   | exit 1 at the version gate: `ERROR: pi >=1.2.0 (stable version string) required, got '1.0.0'`                 |

Runs of an earlier revision, before the version gate and the review fixes:

| Version | Result                                                                                                                                                                                 |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1.4.0   | PASS, with the same `IGNORED before 1.5.0` note (log retained at `/tmp/pi-run-1.4.0.log`)                                                                                              |
| 1.3.0   | PASS, same note (log retained at `/tmp/pi-run-1.3.0.log`)                                                                                                                              |
| 1.0.4   | behavioural failure: `check skill-desc on <SANDBOX>/probe/rpc-skills-override.json`, so `-~/.agents/…` overrides do not match (the fix is `CHANGELOG.md:263`, 1.2.0). Log not retained |
| 1.0.0   | behavioural failure: `help-root: expected output to contain '--no-mcp'` (landed in 1.0.4, `CHANGELOG.md:346`). Log not retained                                                        |

- **Floor: 1.2.0.** It is the lowest tested version that passes, and the `~/.agents` dedupe overrides need its fix.
  - 1.0.1–1.0.3 and 1.1.0 were not run.
  - 1.1.0 predates the `~` override fix (`CHANGELOG.md:263` sits under `## [1.2.0]` at `:221`), so it is expected to fail the same check as 1.0.4. That expectation is [INFERENCE].
  - The harness rejects `<1.2.0` before any probe.
- **Recommended: 1.5.0.** Before it, a saved "do not trust" for a folder with only context files was ignored, so packages and extensions saw the folder as trusted (`CHANGELOG.md:42`).
- **Node:** every tested version declares `engines.node >=22.19.0`. Only Node 24.22.1 was run.

## 5. Open Questions and Gaps

- **Not exercised live:**
  - network installs (`npm:` sources, GitHub URLs);
  - the TUI (`/trust` prompt, `/mcp`, `pi config`);
  - OAuth MCP sign-in, and any connected `ycc-mcp` server (all ran disabled);
  - `/reload` hot-loading; macOS and Windows; Node 22.
- **Not built:** the path-rule injector and the question tool. Both are designs on documented events.
- **`_shared/` packaging:** whether `_shared/` inside a package's `skills/` tree is skipped by discovery is [INFERENCE] from the discovery rules. YAN-1184 must test it.
- **Remote distribution** stays open: a single root git package (root `package.json` gains `pi`; npm runs its `prepare` lifecycle script at install, §1.3) or published npm packages. ADR 0003 records the constraint; YAN-1188 decides.
- **herdr** was checked by hand, not by this harness.
- **Internal API:** the subagent case depends on the upstream example path `examples/extensions/subagent/index.ts`. If it moves, the case fails loudly.

## 6. Reproduction

```bash
npm install --prefix /tmp/pi-1.5.0 @earendil-works/pi-coding-agent@1.5.0   # network only for this fetch
PI_BIN=/tmp/pi-1.5.0/node_modules/.bin/pi bash scripts/test-pi-runtime-contract-spike.sh          # sandbox removed on exit
PI_BIN=/tmp/pi-1.5.0/node_modules/.bin/pi bash scripts/test-pi-runtime-contract-spike.sh --keep   # retain transcript.log, logs/, probe/
PI_BIN=… bash scripts/test-pi-runtime-contract-spike.sh --allow-env-i   # weaker sandbox when bwrap netns is unavailable
```

Requirements: `pi >= 1.2.0` installed from npm (`PI_BIN` must resolve to `dist/bundle/cli.js`), Node `>=22.19.0` (`NODE_BIN` overrides), `git`, `python3`, `timeout`, and `bwrap` with a working `--unshare-net`. Without bwrap the harness exits 1 unless `--allow-env-i` is passed.
