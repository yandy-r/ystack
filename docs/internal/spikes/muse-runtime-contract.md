# Muse Code Runtime Contract (CLI-verified)

- **Date:** 2026-11-27
- **Target:** Muse Code (`muse`, Meta's terminal coding agent), version 1.4.25 (`1.4.25-R9361.1`)
- **Method:** run against the installed `muse` binary with isolated `XDG_CONFIG_HOME`/`XDG_DATA_HOME`/`HOME`: `muse plugins validate|install|inspect|approve|update|remove|list`, `muse skills list|inspect`, `muse plugins marketplace add`, and `muse exec --provider echo` (offline) for rule loading. Its bundled `create-plugin`, `create-skill`, `manage-settings` and `migrate` skills (in `~/.local/share/muse/plugins/cache/builtin/muse-core/`) supplied the native manifest contract. Facts are **[CLI]** (observed with the CLI), **[LIVE]** (observed in an authenticated `muse exec` session) or **[DOCS]** (from those bundled skills); anything not observed is **[INFERENCE]**.
- **Generator:** [`scripts/generate_muse_packages.py`](../../../scripts/generate_muse_packages.py)
- **Installer:** [`scripts/muse_install.py`](../../../scripts/muse_install.py) and [`scripts/lib/install/targets/muse.sh`](../../../scripts/lib/install/targets/muse.sh)

## Decisions

1. **Plugins are the carrier.** `muse plugins install <path> --scope user|project` copies a bundle into `~/.local/share/muse/plugins/cache/local/<id>/<digest>/package` and records it in `installed.json` **[CLI]**. Reinstalling the same id replaces it, `muse plugins update <id>` refreshes from the recorded source, and `muse plugins remove <id>` deletes it (`unknown-plugin` when absent) **[CLI]**.
2. **Two manifest families.**
   - Native: `.muse-plugin/plugin.json` (`schemaVersion: 1`, `compat.source: native`), with `capabilities.skills|commands|hooks|mcpServers|reminders` **[DOCS] [CLI]**. The validator rejects `tools`, `agents`, `outputStyles`, `settings` and `apps` **[DOCS]**.
   - Claude-compatible: `.claude-plugin/plugin.json`. Muse imports `skills/*/SKILL.md` and `agents/*.md`, and reports each declaration as supported or unsupported **[CLI]**.
   - When both manifests exist, the native one wins, and `agents/` is then ignored **[CLI]**. ycc ships the **Claude-compatible** manifest; ycc-mcp and ycc-rules ship the **native** one.
3. **No stable plugin root for skills.** The cache path embeds a content digest, and `muse exec` does not expand slash commands, so `${CLAUDE_PLUGIN_ROOT}` substitution in skill bodies could not be observed. The binary does export `MUSE_PLUGIN_ROOT`/`CLAUDE_PLUGIN_ROOT` to hooks and MCP servers **[INFERENCE from binary strings]**. The generator therefore rewrites `${CLAUDE_PLUGIN_ROOT}/skills/...` to a ycc-owned copy, `~/.local/share/ycc/muse/ycc/...` (`_shared` becomes `ycc-shared/`). The installer places that copy and installs Muse's plugin from it. The copy is always per user. `--project` only changes Muse's install scope (`muse plugins install --scope project`, which installs; the record still sits in the user lockfile with `user-local` trust **[CLI]**).
4. **Skills are the commands.** In the interactive TUI, Muse lists every plugin skill as the slash command `/ycc:<name>`, Claude's spelling (`/ycc:plan · ycc skill`), and `/ycc:plan …` ran the skill ("Loaded skill plan · ycc") **[LIVE]**. The claude-compatible family also imports `commands/<name>.md` **[CLI]**, but such wrappers listed every command twice, so none ship. The generator keeps `/ycc:<skill>` references and rewrites `ycc:<agent>` to the Muse agent id `ycc/<agent>`.
5. **Skill frontmatter.** Muse names them `plugin:ycc:<name>`. `disable-model-invocation: true` lists a skill as `user-invocable-only` **[CLI]**. `allowed-tools` raises an `unsupported-capability` warning and grants nothing **[CLI]**, so it is dropped. `argument-hint` is kept.
6. **Agents.**
   - Muse names them `ycc/<name>`, and each needs review (`review_needed`) until `muse plugins approve ycc` **[CLI]**.
   - A `name` must match `^[a-z]+(?:-[a-z]+)*$` **[CLI]**.
   - `color: magenta` (outside Muse's palette) silently marks an agent unsupported; other colors are just ignored **[CLI]**. `color` is never emitted.
   - `tools` must use Muse's native names (`read_file`, `search`, `write_file`, `edit_file`, `bash`, `web_fetch` and `web_search`). The validator reports Claude names such as `Read` as projected (only `Glob` as unsupported), but a live `subagent_spawn` refuses every such agent with `agent_definition_unavailable`, while the same agent with native names, or with no `tools`, spawns **[LIVE]**. The generator maps `Read`→`read_file`, `Grep`/`Glob`→`search`, `Write`→`write_file`, `Edit`/`NotebookEdit`→`edit_file`, `Bash(...)`→`bash`, `WebFetch`→`web_fetch`, `WebSearch`→`web_search`.
   - `model` is optional; `targets.muse.agentModels` maps every Claude alias to `inherit`, which omits the key.
7. **MCP.**
   - Claude-format `.mcp.json` accepts stdio servers only and drops `env` **[CLI]**, so ycc-mcp uses native `mcpServers`.
   - Native stdio `command` is argv, and any element containing `/` is resolved as a plugin file (`missing-capability-path`) **[CLI]**. Each stdio server therefore runs `sh mcp/<id>.sh`, a generated launcher.
   - Remote servers use `transport: http` with `url` **[CLI]**. Ids must match `^[a-z0-9][a-z0-9._-]{0,79}$` **[CLI]**: `openaiDeveloperDocs` is skipped by a marketplace scan, so it becomes `openai-developer-docs`.
   - Plugin MCP servers need review before activation; the installer approves them **[CLI]**.
8. **Rules.** Muse loads its user rules from `$XDG_CONFIG_HOME/muse/AGENTS.md` **[CLI: echo-provider session log]**. When that file is absent it can fall back to `~/.claude/CLAUDE.md`/`~/.codex/AGENTS.md` ("personal rules fallback") **[CLI strings]**. Project rules come from `AGENTS.md` (`muse init` writes one). Plugins have no rules family, so `ycc-rules` ships each flat ycc rule as a native skill (`rules/<rule>/SKILL.md`) whose description is the rule's "When …" trigger plus its globs; `muse plugins validate` classifies all of them supported **[CLI]**. Muse loads skills on relevance, which approximates a `model_decision`/glob rule, not an always-on one, so `install.sh --target muse --rules` also links the shared ycc `AGENTS.md`.
9. **Hooks.** The events are PreToolUse, PostToolUse, PostToolUseFailure, SessionStart, SessionEnd, UserPromptSubmit, Stop, Notification, PermissionRequest, Interrupt, SessionFork and ToolUseStart. There is no `WorktreeCreate` **[CLI strings]**. herdr ships its own Muse hooks plugin. `ycc-hooks` is excluded.
10. **No catalog.** `muse plugins marketplace add <name> <source>` takes a directory, a `marketplace.json` file, a Git URL or `owner/repo[#ref]`, and at the source root probes `marketplace.json`, then `.agents/plugins/marketplace.json`, then `.claude-plugin/marketplace.json` **[CLI]**. In this repository `.agents/plugins/marketplace.json` is the Codex catalog, which shadows the Claude one. A root `marketplace.json` is read in Muse's native catalog format only. Each entry needs `version`, `install.transport`/`install.source` and `integrity.digest` **[CLI]**. The digest is Muse's own `package_sha256`, which also covers files Muse derives at install time (`agent-definitions/`), so a deterministic generator cannot produce it. Simple file-hash schemes do not reproduce it **[CLI]**. Git sources cannot point at a subdirectory. So `--mode repo` is rejected, and installs come from the local `packages/muse` tree. Revisit if Muse documents its digest or accepts a digest-free catalog.
11. **Worktrees.** The generated bundle's default worktree root is `<repo-root>/.muse/worktrees/`. Muse's own `muse -w` session worktrees are separate.

## Live verification (2026-11-27, `muse exec`, API-key auth, muse-wonder-1.0)

- **Skill:** `read_skill plugin:ycc:plan` loaded, and its `ycc-shared/scripts/worktree-paths.sh` resolved to the owned copy and printed `<repo>/.muse/worktrees` **[LIVE]**.
- **Agent:** `subagent_spawn ycc/code-finder` was accepted and returned the repository's files **[LIVE]**. This was after the native tool-name fix in decision 6.
- **MCP:** `mcp__plugin_ycc_mcp_context7__resolve_library_id` (HTTP) returned `/reactjs/react.dev`, and `mcp__plugin_ycc_mcp_playwright.browser_tabs` (stdio, through `mcp/playwright.sh`) ran **[LIVE]**.
- **Stdio environment:** Muse starts stdio servers with `HOME`, `PATH`, `USER`, `LANG`, `LOGNAME`, `SHELL`, `PWD` and the plugin variables (`MUSE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_ROOT`, `PLUGIN_ROOT`, `MUSE_PLUGIN_DATA_DIR`, `MUSE_SESSION_ID`). It runs the launcher by absolute path from the workspace cwd **[LIVE]**. A mise/asdf shim then needs a global tool version, or the server exits ("transport closed unexpectedly").
- **Catalog budget:** with ycc and ycc-rules installed (108 skills), Muse trims its 32 KB `skills_catalog` by compacting 85 descriptions. No skill is omitted **[LIVE]**.

## Real-profile check (2026-11-28)

`./install.sh install --target muse` into the maintainer's real Muse profile, then one session: the `ycc-shared` helper resolved, `ycc/code-finder` was accepted and answered, and context7 returned `/reactjs/react.dev` **[LIVE]**. The package rows are no longer experimental.

## Remaining checks

- Re-run the live checks above on each new Muse release, along with `muse plugins validate` (below).
- `muse plugins validate packages/muse/{ycc,ycc-mcp,ycc-rules} --json`. `scripts/test_generate_muse_packages.py` does this when `muse` is on PATH, and asserts zero diagnostics and every declaration supported.
