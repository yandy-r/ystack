# Google Antigravity Runtime Contract (desk research)

- **Date:** 2026-11-24
- **Target:** Google Antigravity: the App, the IDE and the `agy` CLI
- **Method:** desk research against the official docs at `antigravity.google/docs/*`. No `agy` binary was run, so every behavior below is **[DOCS]** unless it is labeled **[INFERENCE]**. Before listing a catalog entry, verify live with `agy plugin install` / `agy plugin list --json`.
- **Generator:** [`scripts/generate_antigravity_packages.py`](../../../scripts/generate_antigravity_packages.py)
- **Installer:** [`scripts/antigravity_install.py`](../../../scripts/antigravity_install.py) and [`scripts/lib/install/targets/antigravity.sh`](../../../scripts/lib/install/targets/antigravity.sh)

Sources: `antigravity.google/docs/customization-discovery/`, `/docs/plugins/`, `/docs/build-plugins/` (only partly read), `/docs/skills/`, `/docs/subagents/`, `/docs/rules/`, `/docs/mcp/`, `/docs/hooks/`, `/docs/settings/`, `/docs/migration/workflows-to-skills/`. Secondary sources (lower weight): Mete Atamel, "Where does Antigravity look for configurations?" (2026-08) and the `cfgaudit` issue #1057 (CLI 1.4.10).

## One configuration tree for every surface

- The App, IDE and CLI read the same global folder, `~/.gemini/config/`, and the workspace folder `.agents/`. Global and workspace customizations apply "in both the Antigravity App and the Antigravity CLI".
- Per-surface app data lives in separate folders: `~/.gemini/antigravity`, `~/.gemini/antigravity-cli` and `~/.gemini/antigravity-ide`. These hold caches, transcripts and the CLI's `settings.json`.
- The CLI alone also reads `~/.gemini/antigravity-cli/skills/` and the legacy `~/.gemini/skills/`. ycc writes to neither.

## Decisions

1. **Plugins are the carrier.** A plugin root holds `plugin.json` (`$schema` `https://antigravity.google/schemas/v1/plugin.json`, only `name` is required, `additionalProperties: false`) and default folders: `skills/<name>/SKILL.md`, `agents/<name>.md`, `rules/`, `hooks.json` and `mcp_config.json`. ycc generates three plugins under `packages/antigravity/`: `ycc`, `ycc-mcp` and `ycc-rules`.
2. **Install route.**
   - `agy plugin install <local-path>` stages a copy into `~/.gemini/config/plugins/<name>/`, a read-only folder that is replaced on update. `agy plugin uninstall <name>` removes it and cleans up the registries.
   - A folder placed directly in `~/.gemini/config/plugins/` also activates in every workspace.
   - The installer therefore uses `agy` when it is on PATH, and otherwise places an owned copy itself. That second path covers App- or IDE-only machines.
3. **Global scope only.**
   - Skills get no plugin-root variable. The docs say to use paths relative to the skill folder, and give no placeholder.
   - ycc skills reach `_shared` helpers by absolute path, so the generator rewrites `${CLAUDE_PLUGIN_ROOT}/skills/...` to `~/.gemini/config/plugins/ycc/...`.
   - A workspace install (`.agents/plugins/`) would break those paths, so `--project` is rejected.
4. **No `--mode repo`.** `agy plugin install https://github.com/<owner>/<repo>` takes a whole repository. Installing a plugin from a subfolder is not documented, and the marketplace format is not published.
5. **Skills.**
   - Frontmatter: `name` (kebab-case, must match the folder), `description` (1–1,024 characters), optional `disable-model-invocation`, `license` and `compatibility`. `allowed-tools` is not documented, so it is dropped.
   - Plugin skills are exposed as `/<name>`, so `/ycc:<skill>` references become `/<skill>`.
   - `_shared` ships as the sibling `ycc-shared/`, the same layout as the cross-tool agents bundle.
6. **Agents.**
   - Frontmatter: `name`, `description`, `tools` (string[], default `[]`) and `model` (`inherit`, `flash` or `pro`).
   - A misspelled or unmapped tool name "may cause the subagent process to hang", so the tool map is closed. It uses the standard tool names from the hooks reference: `view_file`, `list_dir`, `grep_search`, `find_by_name`, `write_to_file`, `replace_file_content`, `multi_replace_file_content`, `run_command`, `read_url_content` and `search_web`.
   - Scoped `Bash(...)` grants become `run_command`, governed by the default `commandExecutionPolicy: sandbox`.
   - `mcp__*` tools are dropped; their servers ship in `ycc-mcp`.
   - Model tiers come from `ycc/settings/models.json` `targets.antigravity.agentModels`.
7. **Rules.**
   - Rule files need `trigger` frontmatter: `always_on`, `model_decision`, `glob` (with comma-separated `globs`) or `manual`. An invalid or missing trigger silently drops the rule.
   - Limits: 24,000 bytes per file, and a 20,000-token budget for global plus `always_on` rules.
   - ycc reuses the flat OMP rule set: `paths` maps to `glob`, `alwaysApply` maps to `always_on`, and common rules map to `model_decision`. Rule links point at sibling files. The OMP-only TTSR trigger rules are omitted.
8. **MCP.**
   - `mcp_config.json` has a top-level `mcpServers` object. Remote servers use `serverUrl` over Streamable HTTP; `httpUrl` and SSE are not supported.
   - Plugin servers are namespaced `<plugin>_<server>`.
   - Identity env pass-throughs (`FOO: ${FOO}`) are dropped, so the server inherits the variable **[INFERENCE: Antigravity passes its environment to stdio servers]**.
9. **Instructions.** The global rules file is `~/.gemini/config/AGENTS.md` (also `~/.gemini/AGENTS.md` and `GEMINI.md`). `install.sh --rules` links the shared ycc instructions there.
10. **Not shipped.**
    - **Hooks:** Antigravity has `hooks.json` with `SessionStart`, `PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation` and `Stop`, but ycc's hooks are Claude-specific (`WorktreeCreate`, the herdr reporter).
    - **Settings:** `~/.gemini/antigravity-cli/settings.json` has no documented model or approval keys that ycc manages.
    - **Workflows:** these are deprecated in favor of skills.

## Worktrees

A worktree root under `.agents/` would sit inside Antigravity's workspace customization folder. Antigravity builds therefore pin `<repo-root>/.antigravity/worktrees/`, and `YCC_WORKTREE_ROOT` still overrides it.
