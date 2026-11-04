# ADR 0003: Pi runtime contract

- **Status:** Accepted on authorized PR merge. The PR that adds this file is the
  owner's approval once merged; until then it is proposed.
- **Date:** 2026-11-04
- **Tracking:** Linear YAN-1182 (spike + ADR) and YAN-1181 (gate); GitHub
  [#517](https://github.com/yandy-r/ystack/issues/517)
- **Evidence:** [Pi runtime contract spike](../spikes/pi-runtime-contract.md) and its harness
  [`scripts/test-pi-runtime-contract-spike.sh`](../../../scripts/test-pi-runtime-contract-spike.sh)
- **Tested version:** `@earendil-works/pi-coding-agent` 1.5.0 and 1.2.0 (current harness, both pass);
  1.3.0 and 1.4.0 passed an earlier revision; 1.0.4 and 1.0.0 are rejected at the version gate.
  Upstream `earendil-works/pi` tag `v1.5.0`, commit
  `f9a26365568127461c47a07a37dcb42c140a3ac5`
- **Builds on:** [ADR 0001](0001-package-model-and-versioning.md) (package names, lockstep
  versioning) and [ADR 0002](0002-omp-runtime-contract.md) (the OMP target, the closest analogue)

## Gate (YAN-1181)

- **Prerequisite met.** Linear project P-YAN-19 ("YStack -- Rename to ystack & native packages")
  is Completed (2026-10-19T14:50Z). Linear lists 24 issues: 22 Done and 2 Canceled (YAN-1118,
  YAN-1144), so every non-canceled issue is Done. The cutover shipped in
  [v6.0.0](https://github.com/yandy-r/ystack/releases/tag/v6.0.0). `main` is at v6.1.1
  (`91131c1e`).
- **Changed assumptions against the Pi project plan** (written against Pi v1.3.0):
  - **Repo name and ids.** The repo is `ystack`, and the `ycc` namespace stays. Package ids come
    from `ycc/settings/packages.json`: `ycc`, `ycc-mcp`, `ycc-hooks`, `ycc-rules`, `ycc-all`,
    `ycc-agents`, `@yandy-r/ycc-opencode`, and `installer-fallback`. The `ycc-rules` id already
    exists (Cursor and OMP), so Pi adds a runtime and needs no new id.
  - **OMP is the analogue.** The OMP target ships the generated `.omp-plugin/marketplace.json` and
    `packages/omp/{ycc,ycc-mcp,ycc-rules}`. Its generators (skills, agents, commands, rules) and
    agent scope-guard extension are the template for `packages/pi/`. Like OMP, Pi excludes
    `ycc-hooks`.
  - **Installer contracts.** `install.sh` now has `install|sync|remove|migrate|list`,
    `--package <ids>`, `--mode local|repo`, and `--dry-run`. Pi gets a `scripts/lib/install/targets/`
    entry under those contracts, not a new CLI.
  - **Artifact store.** Workflows write `.ycc/artifacts/<slug>/`, and the default store is
    `linear`. Pi skills therefore need the Linear MCP tools reachable under Pi's names (decision 4).
  - **Pi version.** Pi is at 1.5.0, released 2026-11-02, and Node `>=22.19.0` is unchanged.
    Per `CHANGELOG.md`, the contract changes since 1.3.0 are:
    - 1.4.0 is mostly `models.json` and classifier work. It also fixed `mcp.json` files that start
      with a UTF-8 BOM and extension imports of `@earendil-works/pi-ai/models`
      (`CHANGELOG.md:157-158`).
    - 1.5.0 honours a saved "do not trust" for folders that have only context files.
    - 1.5.0 moved tool-argument validation to pi-schema, so TypeBox refinements no longer run.
    - 1.5.0 added package changelogs (`pi.changelogPath`).
    - 1.5.0 removed the OS sandbox example.
  - **Unchanged since 1.3.0.** `.agents/skills` auto-discovery is on, gated by trust for project
    copies. `pi mcp add|remove|list|login|logout` and `pi.registerMcpServer` exist. There are still
    no built-in subagents.
  - **No native package entries for MCP or agents.** The plan assumed a native path for both;
    there is none. A Pi manifest declares only extensions, skills, prompts, and themes, and Pi
    never loads `mcp.json`, settings, rules, or agents from a package by itself. A package can
    still carry them as plain files that its own extension reads, which Decisions 3, 4, and 6
    rely on: `ycc` ships agent definitions, `ycc-mcp` the server set, and `ycc-rules` rule files.
  - **git identity.** Pi identifies a git package by repo URL. One ystack git URL can therefore
    install only one package.

This ADR's evidence unblocks the rest of the Pi project. Closing YAN-1181 is a Linear action for the
maintainer.

## Context

Pi is a minimal agent harness with extension points. It installs packages from npm, git, or
local paths. A package may contain TypeScript extensions, Agent Skills, prompt templates, and
themes. Pi reads `mcp.json`, `settings.json`, `models.json`, context files, and `SYSTEM.md` /
`APPEND_SYSTEM.md` from the agent dir, and from `.pi/` once a project is trusted.

The spike exercised these surfaces live on a clean, network-isolated home with no inference.
[§5 of the spike](../spikes/pi-runtime-contract.md#5-open-questions-and-gaps) lists what was not
run. It found these gaps for ycc:

- No subagents. The upstream example extension works, but a verbatim ycc agent fails: its Claude
  model alias resolved to Bedrock, and Claude tool names enable no tools.
- No shell hooks, no `hooks.json`, no worktree event.
- A Pi manifest has no entries for MCP config, settings, rules, or agents; only a package's own
  extension can load such files from it. Two settings entries for one git repo URL load only the
  first.
- `${CLAUDE_PLUGIN_ROOT}`, `/ycc:` references, and `$ARGUMENTS` stay literal in skill bodies.
  A prompt template that emits `/skill:x` is not expanded again.
- User-scope packages and MCP load with no prompt. A throwing extension stops Pi from starting.

## Decision

1. **Generated Pi packages.** ycc generates `packages/pi/{ycc,ycc-mcp,ycc-rules}/`. Each has a
   `package.json` carrying a unique `name`, the lockstep `version`, and a `pi` manifest that lists
   every resource. Host packages are `peerDependencies: "*"`, and there are no `dependencies`.
   `install.sh --target pi` installs each package by absolute local path: `pi install <dir>` at
   user scope, or `pi install -l --approve <dir>` at project scope. Only local installs were
   exercised. A remote install is not decided here: Pi keys a git package by its repo URL, so one
   ystack URL cannot yield three packages. YAN-1188 picks between a single root git package and
   npm packages.
2. **Namespace.** Keep `ycc`. Skills are `/skill:<name>`. Public entrypoints are `ycc:<name>`
   extension commands that call `sendUserMessage("/skill:<name> …", {expandPromptTemplates: true})`.
   A prompt template does not chain into a skill.
3. **Agents through a ycc subagent extension.** The `ycc` package ships a TypeScript `subagent`
   tool modeled on `examples/extensions/subagent`. It loads the 55 generated agent definitions from
   the package, translates tool names and models, spawns child `pi --mode json -p --no-session`
   runs with depth and concurrency limits and `ctx.signal` cancellation, and returns structured
   output. A prompt-only shim is not acceptable.
4. **MCP.** `ycc-mcp` is an extension package that calls `pi.registerMcpServer` for the shipped
   server set. A same-name user `mcp.json` entry wins. Each server sets an explicit
   `exposure`/`toolExposure`, and skill and agent tool names are re-minted as
   `mcp__<server>__<tool>`, with `-` mapped to `_`. An opt-in `install.sh --mcp` merge into
   `<agentDir>/mcp.json` is the fallback for `pi mcp` shell commands, which never load extensions.
5. **Hooks.** `WorktreeCreate` is **unsupported**. herdr reporting is **native** and owned by
   herdr (`herdr integration install pi`). `ycc-hooks` is **excluded**, and ycc ships no hook
   extension.
6. **Rules, settings, approvals.**
   - Always rules go through `install.sh --rules` as an `<agentDir>/AGENTS.md` link. They never
     use `APPEND_SYSTEM.md`, which a trusted project file replaces.
   - Path and language rules come from a `ycc-rules` extension that attaches a family's rules
     after a matching `read`, `edit`, or `write`.
   - Main-model defaults are an opt-in `--settings` merge. Pi has no approval modes, so
     DANGEROUS_MODE is unsupported.
7. **Minimum version.** Support **`>=1.2.0`**, the lowest tested version that passes the harness,
   and recommend 1.5.0. 1.0.1–1.0.3 and 1.1.0 were not run. 1.1.0 lacks the `~` override fix
   that the dedupe overrides need (`CHANGELOG.md:263`, released in 1.2.0). The harness rejects
   anything older than 1.2.0 at its version gate.
8. **Trust.** Every shipped extension and MCP command is full-trust code and must not throw at
   load: one throwing factory stops Pi from starting. The docs state this, and that project-scope
   installs need trust (`--approve` in non-interactive runs).

### Package matrix (Pi)

| Package                     | Pi mechanism                                                                      | Verdict     | Notes                                                                                                                                           |
| --------------------------- | --------------------------------------------------------------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `ycc`                       | Generated package: skills, `_shared`, command and subagent extensions, agent data | adapter     | Rewrite `${CLAUDE_PLUGIN_ROOT}`, `/ycc:`, `$ARGUMENTS`, and `_shared` paths. The 9 `disable-model-invocation` skills map natively.              |
| `ycc-mcp`                   | Extension package (`pi.registerMcpServer`)                                        | adapter     | A disabled copy of `.mcp.json` parses. Pi does not read `mcp.json` from a package; the registrar reads it as package data. No SSE servers ship. |
| `ycc-hooks`                 | none                                                                              | excluded    | herdr: `herdr integration install pi`. `WorktreeCreate` is unsupported.                                                                         |
| `ycc-rules`                 | Extension package (path-rule injector) + rule files                               | adapter     | Always rules use the `installer-fallback` `AGENTS.md` link.                                                                                     |
| `ycc-all`                   | none                                                                              | fallback    | Pi packages cannot depend on Pi packages.                                                                                                       |
| `ycc-agents`                | none                                                                              | n/a         | Deferred to v7 (ADR 0001); agents ship inside `ycc`.                                                                                            |
| `@yandy-r/ycc-opencode`     | none                                                                              | n/a         | opencode-specific.                                                                                                                              |
| `installer-fallback`        | `<agentDir>` files                                                                | fallback    | `AGENTS.md` link, opt-in `settings.json`/`mcp.json` merges, owned `~/.agents` dedupe overrides; user scope only.                                |
| Status line, status-bar mod | `ctx.ui.setStatus`/`setWidget`/`setFooter`                                        | unsupported | A different module API. A port is new code, outside the lockstep.                                                                               |

The full per-component matrix is in the
[spike, section 3](../spikes/pi-runtime-contract.md#3-component--verdict-matrix).

## Consequences

- **New Pi tree.** Pi gets its own generated tree, validators, and lockstep surfaces (`package.json`
  versions), and release tooling must bump and check them.
- **TypeScript ownership.** The `ycc` package carries real TypeScript: the subagent dispatcher and
  command wrappers. That makes ystack own upgrade risk on Pi's extension API, for example 1.5.0's
  pi-schema tool validation.
- **`~/.agents/skills` collisions.** Copies under `~/.agents/skills` from the `install.sh` `agents`
  target outrank package skills of the same name. The Pi target must write owned `skills`
  exclusions (`-~/.agents/skills/<n>/SKILL.md`, ≥1.2.0) or skip the agents copies.
- **Non-interactive trust.** In print, JSON, and RPC modes, project-scope content needs `--approve`
  or `defaultProjectTrust: "always"`. Context files (`AGENTS.md`) load untrusted regardless.
- **No offline-safe dependencies.** git and npm installs run `npm install` and lifecycle scripts.
  ycc packages must stay dependency-free.

## Follow-up mapping

| Issue    | Scope from this ADR                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| YAN-1183 | Add a `pi` column to the capability matrix in `ycc/skills/_shared/references/target-capability-matrix.md`, using the matrix vocabulary: SKILLS partial (native discovery, body rewrite), COMMANDS partial (extension commands), AGENTS partial (ycc subagent extension), HOOKS.PreToolUse/PostToolUse/Stop partial (TypeScript `tool_call`/`tool_result`/`agent_settled` only; no shell hooks), MCP partial (registrar extension or `mcp.json` merge), INSTALL_PATH partial (`pi install <path>`; no catalog), DANGEROUS_MODE unsupported, WORKTREE partial (bash `git worktree`; no event), MODS unsupported, plus a `**<CAP>:pi**` note for each partial/unsupported cell. Also add `pi` to `CANONICAL_TARGETS` in `scripts/validate_capability_matrix.py`, to `ALL_TARGETS` in `ycc/skills/compatibility-audit/scripts/audit-target-features.sh`, and to the runtime enum in `ycc/settings/packages.schema.json`; add `pi` runtimes to `ycc/settings/packages.json` and the inventory; floor `>=1.2.0` (landed as all-`unsupported` until surfaces ship; validators tie the column to `packages/pi/`; target v6.3.0) |
| YAN-1184 | Skill and `_shared` generation into `packages/pi/ycc/skills`; rewrite `${CLAUDE_PLUGIN_ROOT}`, `/ycc:`, and `$ARGUMENTS` (left literal by Pi); verify `_shared` is not discovered as a skill                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| YAN-1185 | `ycc:<name>` extension commands that call `sendUserMessage(…, {expandPromptTemplates:true})`; a template that chains `/skill:x` does not expand (**scope change:** commands need an extension, not plain templates)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| YAN-1186 | ycc subagent extension (tool-name and model translation, package-local agent data, child `pi` runs, limits, cancellation); the upstream example is the reference, a verbatim ycc agent fails                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| YAN-1187 | Questions via `ctx.ui` (degrade in `-p`), `.pi/worktrees/` via bash and subagent `cwd`, no background jobs, artifact store via bash plus re-minted Linear MCP tool names                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| YAN-1188 | `packages/pi/*` generator with `package.json#pi` and lockstep version; decide remote distribution (one git URL = one package; npm runs lifecycle scripts) (**scope change**)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| YAN-1189 | `install.sh --target pi`: `pi install/remove <abs path>` (`-l --approve` for project), `PI_CODING_AGENT_DIR`-aware paths, `--dry-run`, `migrate`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| YAN-1190 | `ycc-mcp` registrar extension (`pi.registerMcpServer`), explicit exposure, opt-in `mcp.json` merge fallback; no SSE (**scope change:** packages cannot ship `mcp.json`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| YAN-1191 | Record `WorktreeCreate` unsupported and herdr native (`herdr integration install pi`); `ycc-hooks` excluded; no ycc hook extension (**scope change:** narrows to verdicts and guards)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| YAN-1192 | `--rules` `AGENTS.md` link, `ycc-rules` path-rule injector, opt-in `defaultModel` merge, `targets.pi` models for the subagent extension; no approval modes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| YAN-1193 | `~/.agents/skills` dedupe overrides (owned `-~/…/SKILL.md` entries), project-trust docs (`--approve` in non-interactive runs), no-throw extension guard, clean removal                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| YAN-1194 | Validators and generator tests for `packages/pi`; wire this harness as an opt-in live job (outside this spike)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| YAN-1195 | Live acceptance on 1.2.0 (floor) and current, Linux/macOS/Windows, network installs, TUI trust prompt, connected MCP                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| YAN-1196 | `docs/install/pi.md`: trust model, scope and `--approve`, restart and `/reload`, herdr                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| YAN-1197 | Release gate: list the Pi packages and record the floor in release notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
