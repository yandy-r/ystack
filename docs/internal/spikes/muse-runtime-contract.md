# Muse Code Runtime Contract (CLI-verified)

- **Date:** 2026-11-27
- **Target:** Muse Code (`muse`, Meta's terminal coding agent), version 1.4.25 (`1.4.25-R9361.1`)
- **Method:** run against the installed `muse` binary with isolated `XDG_CONFIG_HOME`/`XDG_DATA_HOME`/`HOME`: `muse plugins validate|install|inspect|approve|update|remove|list`, `muse skills list|inspect`, `muse plugins marketplace add`, and `muse exec --provider echo` (offline) for rule loading. Its bundled `create-plugin`, `create-skill`, `manage-settings` and `migrate` skills (in `~/.local/share/muse/plugins/cache/builtin/muse-core/`) supplied the native manifest contract. Facts are **[CLI]** (observed) or **[DOCS]** (from those bundled skills); anything not observed is **[INFERENCE]**. No authenticated model session was run (`muse login` was not available), so skill and agent behavior inside a live turn is still a release gate.
- **Generator:** [`scripts/generate_muse_packages.py`](../../../scripts/generate_muse_packages.py)
- **Installer:** [`scripts/muse_install.py`](../../../scripts/muse_install.py) and [`scripts/lib/install/targets/muse.sh`](../../../scripts/lib/install/targets/muse.sh)

## Decisions

1. **Plugins are the carrier.** `muse plugins install <path> --scope user|project` copies a bundle into `~/.local/share/muse/plugins/cache/local/<id>/<digest>/package` and records it in `installed.json` **[CLI]**. Reinstalling the same id replaces it, `muse plugins update <id>` refreshes from the recorded source, and `muse plugins remove <id>` deletes it (`unknown-plugin` when absent) **[CLI]**.
2. **Two manifest families.**
   - Native: `.muse-plugin/plugin.json` (`schemaVersion: 1`, `compat.source: native`), with `capabilities.skills|commands|hooks|mcpServers|reminders` **[DOCS] [CLI]**. The validator rejects `tools`, `agents`, `outputStyles`, `settings` and `apps` **[DOCS]**.
   - Claude-compatible: `.claude-plugin/plugin.json`. Muse imports `skills/*/SKILL.md` and `agents/*.md`, and reports each declaration as supported or unsupported **[CLI]**.
   - When both manifests exist, the native one wins, and `agents/` is then ignored **[CLI]**. ycc ships the **Claude-compatible** manifest; ycc-mcp and ycc-rules ship the **native** one.
3. **No stable plugin root for skills.** The cache path embeds a content digest, and `muse exec` does not expand slash commands, so `${CLAUDE_PLUGIN_ROOT}` substitution in skill bodies could not be observed. The binary does export `MUSE_PLUGIN_ROOT`/`CLAUDE_PLUGIN_ROOT` to hooks and MCP servers **[INFERENCE from binary strings]**. The generator therefore rewrites `${CLAUDE_PLUGIN_ROOT}/skills/...` to a ycc-owned copy, `~/.local/share/ycc/muse/ycc/...` (`_shared` becomes `ycc-shared/`). The installer places that copy and installs Muse's plugin from it. The copy is always per user. `--project` only changes Muse's install scope (`muse plugins install --scope project`, which installs; the record still sits in the user lockfile with `user-local` trust **[CLI]**).
4. **Skills and commands.** The claude-compatible family also imports `commands/<name>.md` as supported commands **[CLI]**; ycc ships one per public skill that loads `plugin:ycc:<skill>`.
5. **Skill frontmatter.** Muse names them `plugin:ycc:<name>`. `disable-model-invocation: true` lists a skill as `user-invocable-only` **[CLI]**. `allowed-tools` raises an `unsupported-capability` warning and grants nothing **[CLI]**, so it is dropped. `argument-hint` is kept.
6. **Agents.**
   - Muse names them `ycc/<name>`, and each needs review (`review_needed`) until `muse plugins approve ycc` **[CLI]**.
   - A `name` must match `^[a-z]+(?:-[a-z]+)*$` **[CLI]**.
   - `color: magenta` (outside Muse's palette) silently marks an agent unsupported; other colors are just ignored **[CLI]**. `color` is never emitted.
   - `Glob` has no tool projection (`agent-tool-projection` unsupported). Read, Grep, Write, Edit, Bash, WebFetch and WebSearch all project **[CLI]**. `Glob` is dropped, and scoped `Bash(...)` becomes `Bash`.
   - `model` is optional; `targets.muse.agentModels` maps every Claude alias to `inherit`, which omits the key.
7. **MCP.**
   - Claude-format `.mcp.json` accepts stdio servers only and drops `env` **[CLI]**, so ycc-mcp uses native `mcpServers`.
   - Native stdio `command` is argv, and any element containing `/` is resolved as a plugin file (`missing-capability-path`) **[CLI]**. Each stdio server therefore runs `sh mcp/<id>.sh`, a generated launcher.
   - Remote servers use `transport: http` with `url` **[CLI]**. Ids must match `^[a-z0-9][a-z0-9._-]{0,79}$` **[CLI]**: `openaiDeveloperDocs` is skipped by a marketplace scan, so it becomes `openai-developer-docs`.
   - Plugin MCP servers need review before activation; the installer approves them **[CLI]**.
8. **Rules.** Muse loads its user rules from `$XDG_CONFIG_HOME/muse/AGENTS.md` **[CLI: echo-provider session log]**. When that file is absent it can fall back to `~/.claude/CLAUDE.md`/`~/.codex/AGENTS.md` ("personal rules fallback") **[CLI strings]**. Project rules come from `AGENTS.md` (`muse init` writes one). Plugins have no rules family, so `ycc-rules` ships each flat ycc rule as a native skill (`rules/<rule>/SKILL.md`) whose description is the rule's "When …" trigger plus its globs; `muse plugins validate` classifies all of them supported **[CLI]**. Muse loads skills on relevance, which approximates a `model_decision`/glob rule, not an always-on one, so `install.sh --target muse --rules` also links the shared ycc `AGENTS.md`.
9. **Hooks.** The events are PreToolUse, PostToolUse, PostToolUseFailure, SessionStart, SessionEnd, UserPromptSubmit, Stop, Notification, PermissionRequest, Interrupt, SessionFork and ToolUseStart. There is no `WorktreeCreate` **[CLI strings]**. herdr ships its own Muse hooks plugin. `ycc-hooks` is excluded.
10. **No catalog.** `muse plugins marketplace add <name> <dir>` reads only `.agents/plugins/marketplace.json` at a repo root **[CLI]**, and in this repository that file is the Codex catalog. `--mode repo` is rejected, and installs come from the local `packages/muse` tree.
11. **Worktrees.** The generated bundle's default worktree root is `<repo-root>/.muse/worktrees/`. Muse's own `muse -w` session worktrees are separate.

## Gates before listing

- Live, authenticated session (`muse login`): invoke a ycc skill whose body runs a `ycc-shared` helper, spawn a `ycc/<agent>` subagent, and call one stdio and one HTTP ycc-mcp server.
- Re-run `muse plugins validate packages/muse/{ycc,ycc-mcp,ycc-rules} --json` on each Muse release. `scripts/test_generate_muse_packages.py` does this when `muse` is on PATH, and asserts zero diagnostics and every declaration supported.
