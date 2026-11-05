# Target Capability Matrix

## Contents

- Parser Grammar
- Capability Matrix
- Native vs install.sh Fallback
- Notes
- Artifact store
- How to Update This Document

As of 2026-11-04

This file is the authoritative source for which ycc bundle capabilities are supported on each
deployment target. Downstream scripts parse the table below; read the Parser Grammar section
before editing the table.

---

## Parser Grammar

The first table below (Capability Matrix) is parsed by `ycc/skills/compatibility-audit/scripts/audit-target-features.sh`.
Follow these rules exactly or the parser will misread cells:

- **Column order**: `capability, claude, cursor, codex, opencode, omp, pi` — do not reorder.
- **Cell vocabulary**: exactly one of `supported`, `partial`, or `unsupported` — no other tokens,
  no trailing punctuation, no parenthetical notes inside the cell.
- **Notes** belong in the Notes section below the table, keyed as `capability:target`.
- The Native vs install.sh Fallback table comes after the parsed table and is descriptive only.
  The audit parser stops at the first non-table line after the Capability Matrix, so keep a
  heading or prose line between the two tables. Add a target column only by appending it and
  updating the scripts that parse it.
- Do not change column order or cell vocabulary without updating the parser in
  `ycc/skills/compatibility-audit/scripts/audit-target-features.sh`. Separator cells are dashes
  only (`---`); alignment colons are not allowed. Every header target must be a runtime in
  `ycc/settings/packages.schema.json`, and every `partial` or `unsupported` cell needs a
  `**CAPABILITY:target**` note; `scripts/validate_capability_matrix.py` enforces both.
- **Rows are pinned**: the capability rows and their order are fixed in
  `CANONICAL_CAPABILITIES` in `scripts/validate_capability_matrix.py`. Adding, removing, or
  reordering a capability requires updating that tuple and the capability detection in
  `audit-target-features.sh`.

---

## Capability Matrix

| capability        | claude    | cursor      | codex       | opencode    | omp         | pi          |
| ----------------- | --------- | ----------- | ----------- | ----------- | ----------- | ----------- |
| SKILLS            | supported | supported   | supported   | supported   | partial     | unsupported |
| COMMANDS          | supported | partial     | unsupported | supported   | partial     | unsupported |
| AGENTS            | supported | partial     | supported   | supported   | partial     | unsupported |
| HOOKS.PreToolUse  | supported | partial     | unsupported | partial     | unsupported | unsupported |
| HOOKS.PostToolUse | supported | partial     | unsupported | partial     | unsupported | unsupported |
| HOOKS.Stop        | supported | partial     | unsupported | partial     | unsupported | unsupported |
| MCP               | supported | supported   | partial     | supported   | partial     | unsupported |
| INSTALL_PATH      | supported | supported   | supported   | supported   | partial     | unsupported |
| DANGEROUS_MODE    | supported | unsupported | unsupported | unsupported | unsupported | unsupported |
| WORKTREE          | supported | partial     | partial     | partial     | partial     | unsupported |
| MODS              | supported | unsupported | unsupported | unsupported | unsupported | unsupported |

---

## Native vs install.sh Fallback

Packaging status as of v6.0.0 (2026-10-18). This descriptive companion separates shipping native packages
from installer-managed artifacts and gated work in `ycc/settings/packages.json`.
`listed: false` packages are not published catalog entries; generated trees and successful spikes
alone do not make them shipping user install paths. This does not revise the capability verdicts above.

| target   | native, listed today                                                                                                                          | install.sh today                                                                                                                                                                                                                           | unlisted or gated native packages                                                                             |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| Claude   | `ycc@ycc`, `ycc-mcp@ycc`, `ycc-hooks@ycc` (2.1.300+), `ycc-all@ycc`; `status-bar@ycc-mods`                                                    | Installs the native plugins via `claude plugin` (`mcp`/`hooks` at project scope by default, user scope with `--global`); rules, settings, statusline                                                                                       | `ycc-agents@ycc` in v7.0.0                                                                                    |
| Cursor   | `ycc`, `ycc-rules`, `ycc-mcp`, `ycc-hooks` via the root `.cursor-plugin/marketplace.json` (interactive `/plugins`); hooks `sessionStart` only | Registers the marketplace and prints the `/plugins` step; `cli-config.json` settings (`--global`)                                                                                                                                          | None                                                                                                          |
| Codex    | `ycc@ycc`, `ycc-mcp@ycc` via the root `.agents/plugins/marketplace.json`                                                                      | Installs both via `codex plugin add` (codex 0.160+ required); agent TOMLs, `AGENTS.md`, `config.toml`                                                                                                                                      | `ycc-hooks` excluded (YAN-1149)                                                                               |
| opencode | None                                                                                                                                          | Skills, agents, commands, shared, `opencode.json`, `AGENTS.md`                                                                                                                                                                             | `@yandy-r/ycc-opencode` npm plugin: experimental, opt-in, unpublished                                         |
| `agents` | None                                                                                                                                          | Skills and `ycc-shared` copied into `~/.agents/`                                                                                                                                                                                           | None planned                                                                                                  |
| `omp`    | `ycc@ycc`, `ycc-mcp@ycc`, `ycc-rules@ycc` via the root `.omp-plugin/marketplace.json` (omp `>=18.12.2`)                                       | `install.sh --target omp`: local export (`--mode local`) or the repository catalog (`--mode repo`) installed through `omp plugin` (user or project scope); opt-in `--rules` (`AGENTS.md`) and `--settings` (`config.yml`), user scope only | `ycc-hooks` and `ycc-all` excluded (herdr: `herdr integration install omp`)                                   |
| `pi`     | None                                                                                                                                          | None                                                                                                                                                                                                                                       | `ycc`, `ycc-mcp`, `ycc-rules` deferred to v6.3.0 (ADR 0003, pi `>=1.2.0`); `ycc-hooks` and `ycc-all` excluded |

Native dependency resolution is a Claude platform feature, not a cross-runtime guarantee.
The Claude `ycc-all` meta plugin's automatic dependency install was verified on Claude Code 2.1.301 and in the v6.0.0 maintainer clean-host verification; Cursor and Codex have no
dependency field, and the `agents` target is a directory convention, not a package system.
Claude rules, settings, and statusline stay on `install.sh`.

The recommendation in `docs/research/ystack/recommendation.md` is qualified by
`ycc/settings/packages.json` and the later verdicts in `docs/internal/spikes/`:

- `claude-hooks.md`: plugin `WorktreeCreate` was observed on 2.1.300, not 2.1.143. The
  hooks package requires a documented 2.1.300 minimum and tested command-level migration dedupe
  that preserves user-owned hooks. `claude-namespace.md` rejects a shared-name agents split;
  the qualified `ycc-agents:` namespace is deferred to v7.0.0.
- `codex-marketplace.md`: native catalog discovery is verified on 0.161.0, but `WorktreeCreate`
  is dropped and trusted plugin hook dispatch is unverified. Hooks remain excluded.
- `cursor-plugin.md`: user-scope GitHub marketplace registration is verified; interactive
  install was verified in the v6.0.0 maintainer release verification (YAN-1141). YAN-1132
  generates the native packages with a tested Cursor floor of 3.24.12, listed in the root marketplace.
  Native hooks are limited to `sessionStart`; do not infer `WorktreeCreate` or other Claude hook parity.
- `opencode-config-hook.md`: V2 registrations and context-hook instructions were verified on
  v2.0.29, not the V1 config-hook approach. The experimental npm path still needs CI publishing;
  `install.sh` file copy remains primary.
- `omp-runtime-contract.md`: tested on omp 18.12.2 (supported floor `>=18.12.2`). OMP gets a
  dedicated generated `.omp-plugin/` tree; shell hooks, `hooks.json`, and `WorktreeCreate` never
  run, and `ycc-all` is omitted because OMP ignores plugin dependencies. See ADR 0002. The
  opt-in harness installs a generated export of `ycc` (its catalog includes unlisted rows) from
  a local pinned fixture on omp 18.12.3 (YAN-1171). `install.sh install --target omp` installs the
  same export, now `ycc`, `ycc-mcp` and `ycc-rules`, from a checkout through `omp plugin`
  (YAN-1172, YAN-1173, YAN-1175). Since YAN-1180 the three rows are listed and the repository
  publishes the root `.omp-plugin/marketplace.json`.
  YAN-1174: ycc ships no OMP hooks; herdr reporting is herdr's own OMP integration.
- `pi-runtime-contract.md`: tested on Pi (`@earendil-works/pi-coding-agent`) 1.5.0 and 1.2.0;
  supported floor `>=1.2.0`, recommended 1.5.0. Pi gets a generated `packages/pi/` tree
  (YAN-1188) installed by absolute path with `pi install`; there is no catalog. Pi has no
  built-in subagents, no shell hooks or `hooks.json`, no `WorktreeCreate` event, and no approval
  modes, and a Pi package cannot depend on another, so `ycc-all` is omitted. See ADR 0003. No Pi
  generator or installer ships yet, so every `pi` cell above is `unsupported`.

---

## Notes

**COMMANDS:claude**
Claude Code has no separate ycc command-wrapper layer. Public skills are native slash
invocations (`/ycc:<name>`); `user-invocable: false` hides a skill from the slash menu.
Claude `skills`, `agents` and `commands` intents map to the `ycc@ycc` plugin; the
installer writes no standalone copies. Its legacy cleanup retires only wrappers and
copies recorded in installer ownership state (or identical to the bundle). Foreign
wrappers are never touched.

**INVOCATION POLICY**
`disable-model-invocation: true` is source frontmatter for manual-only skills; it is
distinct from `user-invocable: false`. Claude and Cursor keep the native flag. Codex
emits a skill-local `agents/openai.yaml` with `policy.allow_implicit_invocation: false`.
opencode emits skill metadata `opencode/autoinvoke: 'false'`. The cross-tool `agents`
target has no portable key, so it omits the flag and keeps the description.

**COMMANDS:cursor**
The native `packages/cursor/ycc/commands/` contains thin commands derived from
user-invocable skills in `ycc/skills/`; each loads its package-local skill. This is not
an installed-plugin dispatch proof. The installer writes no Cursor command or hook files:
native plugin install is interactive (`/plugins`), and the agent CLI has no
non-interactive `plugin install`.

**COMMANDS:codex**
The Codex customization platform does not support a slash-command layer. Skills are exposed
via the plugin bundle; there is no Codex analog for slash commands.

**AGENTS:cursor**
Agents from `ycc/agents/` are adapted into `packages/cursor/ycc/agents/` and copied by
the installer to `~/.cursor/agents/`. The same generated definitions are packaged in the
native `ycc` package. Shell scope is not enforced (YAN-1276): Cursor subagent frontmatter
documents only `name`, `description`, `model`, `readonly` and `is_background`, so the copied
`Bash(<prefix>:*)` entries in `tools:` are not a documented grant, and `readonly` cannot
express "these validation commands only". Cursor's `beforeShellExecution` / `preToolUse` hook
input carries no subagent name, so a hook cannot apply one agent's prefixes either. The
restricted fixers (`pr-comment-fixer`, `review-fixer`, `release-fix-applier`) keep their
allowlist as prompt instructions only. Sources: cursor.com/docs/subagents, cursor.com/docs/hooks.

**AGENTS:codex**
Agents are emitted as custom-agent TOMLs (`name`, `description`, `developer_instructions`)
and installed under `~/.codex/agents/`. Shell scope is not enforced (YAN-1276): a custom agent
can only switch off whole capabilities (`features.shell_tool`, `apps`, `plugins`, `memories`,
`request_permissions_tool`); `sandbox_mode`, `approval_policy` and command rules come from the
parent session (codex-rs `core/src/agent/role.rs`, rust-v0.164.0). Prefix rules
(`rules/*.rules`) apply per config layer, never per agent. The restricted fixers need their
validation commands, so the shell stays on and the allowlist is a prompt instruction only. A
`PreToolUse` hook input does carry `agent_type`, but ycc ships no Codex hooks (YAN-1149).
Sources: learn.chatgpt.com/docs/agent-configuration/subagents, `.../rules`, `.../hooks`.

**HOOKS.PreToolUse:cursor**
Cursor does not expose a native PreToolUse hook execution surface equivalent to Claude Code's
`~/.claude/settings.json` hooks. Existing repo hook guidance (e.g., `ycc/rules/*/hooks.md`)
is embedded as rule-file notes, not executed by a hook runner.

**HOOKS.PostToolUse:cursor**
Same constraint as HOOKS.PreToolUse:cursor. PostToolUse hook guidance is rule-embedded only.

**HOOKS.Stop:cursor**
Same constraint as HOOKS.PreToolUse:cursor. Stop hook guidance is rule-embedded only.

**HOOKS.PreToolUse:codex**
The Codex config reference documents `features.codex_hooks` as under development as of
the April 2026 research audit. No primary source confirms production availability. Marked
`unsupported` pending a verified Codex GA announcement.

**HOOKS.PostToolUse:codex**
Same constraint as HOOKS.PreToolUse:codex.

**HOOKS.Stop:codex**
Same constraint as HOOKS.PreToolUse:codex.

**MCP:codex**
MCP integration is referenced in the Codex customization docs
(`developers.openai.com/codex/concepts/customization`) but is less mature than the Claude Code
or Cursor MCP surfaces. Treat as partial until a verified stable API is documented.

**DANGEROUS_MODE:cursor**
The `--dangerously-skip-permissions` flag is a Claude Code CLI concept with no equivalent in
Cursor.

**DANGEROUS_MODE:codex**
No equivalent to Claude Code's dangerous mode exists in the Codex runtime.

**INSTALL_PATH:claude**
`install.sh install --target claude` registers the `ycc` marketplace through the `claude` CLI, then
runs `claude plugin install ycc@ycc --scope user`. Directory mode (default) runs
`claude plugin marketplace add <absolute-repo-root> --scope user`, so the marketplace
points at the repo checkout (`.claude-plugin/marketplace.json`, name `ycc`) and edits in `ycc/`
apply on `/reload-plugins` with no rsync or cache clear; rerun `--only base` if the repo moves.
Repo mode runs `claude plugin marketplace add yandy-r/ystack --scope user`, a GitHub
source; update with `claude plugin install ycc@ycc --scope user` or the `/plugins` UI. The CLI
writes to `~/.claude/settings.json`. The installer first replaces a symlink there with a real
file so the committed `ycc/settings/settings.json` is not modified, and the `settings` step
later merges repo-managed keys while preserving the CLI-written marketplace entry. It also
removes legacy `local-ycc-plugins` marketplace and `ycc@local-ycc-plugins` entries from
`~/.claude.json` and `~/.claude/settings.local.json`, deleting `settings.local.json` if that
leaves it empty. Other steps: `rules` links `~/.claude/CLAUDE.md`; `mcp` and `hooks`
install the native `ycc-mcp@ycc` and `ycc-hooks@ycc` plugins at project scope (the
default), declaring the `ycc` marketplace at project scope (repo mode, committed) or
local scope (local mode) only when no visible declaration supplies it — never
repointing an existing declaration — or at user scope with `--global`; `mods`
registers the `ycc-mods` directory marketplace. A successful native install then
retires proven installer-owned legacy state (standalone `~/.claude/{skills,agents}`
copies, command wrappers, and — once the add-on is explicitly enabled in
`~/.claude/settings.json` — the settings hook, `~/.claude/hooks` link and managed MCP
servers). The `base` step of `remove --target claude` uninstalls `ycc@ycc` and the
`ycc` marketplace. The `mcp`/`hooks` intents uninstall the plugin at the step's scope;
at project scope they remove only installer-written marketplace declarations when no
other `@ycc` install remains.

**INSTALL_PATH:cursor**
Sources under `ycc/` generate `packages/cursor/ycc/{skills,agents,commands}/`,
`packages/cursor/ycc-rules/rules/`, `packages/cursor/ycc-mcp/mcp.json`, and
`packages/cursor/ycc-hooks/hooks/`. Canonical `ycc/settings/cursor/cli-config.json`
is copied byte-for-byte to `packages/cursor/installer-fallback/config/cli-config.json`.
`install.sh install --target cursor` runs `agent plugin marketplace add
https://github.com/yandy-r/ystack` (also in local mode: Cursor rejects filesystem
marketplaces), prints the `/plugins` step naming the packages for the requested intents,
and retires proven installer-owned copies an older installer wrote under `~/.cursor/`.
Its only other step merges `cli-config.json` (`--global`). All four native packages are
listed in the generated root `.cursor-plugin/marketplace.json`; native installation is
interactive (`/plugins`). See `docs/internal/cursor-native-packages.md`.

**INSTALL_PATH:codex**
`install.sh install --target codex` syncs custom agents to `~/.codex/agents/`, registers the
checkout (local mode) or `https://github.com/yandy-r/ystack.git` at `main` (repo mode) as the
Codex marketplace `ycc` with `codex plugin marketplace add`, and installs + enables
`ycc@ycc` and `ycc-mcp@ycc` with `codex plugin add`, which snapshots each into
`~/.codex/plugins/cache/ycc/<package>/<version>/`. The codex CLI 0.160+ is required; there
is no copy fallback. It then retires proven legacy state (`ycc@local-ycc-plugins`, its links,
cache and catalog entry, `~/.codex/skills` copies, merged `[mcp_servers]`), keeping every
`~/.codex/agents/` file. Rerun the base install step after regenerating the bundle via
`./scripts/sync.sh --only codex` or after clearing `~/.codex/plugins/cache/`.

**INSTALL_PATH:opencode**
Generated bundle lives at `.opencode-plugin/` (skills, agents, commands, AGENTS.md,
opencode.json). Consumed by opencode from `~/.config/opencode/` (global) or `.opencode/`
(project-local) after `install.sh install --target opencode` rsyncs the files.

**SKILLS:opencode**
Native support at `.opencode/skills/<name>/SKILL.md` with strict YAML frontmatter
(`name`, `description` required; `license`, `compatibility`, `metadata` optional). Descriptions
are limited to 1024 chars. opencode also reads `.claude/skills/*/SKILL.md` and
`.agents/skills/*/SKILL.md` as compatibility fallbacks. Source: opencode.ai/docs/skills/.

**COMMANDS:opencode**
Generated thin native commands, one per public skill, sourced from that skill's
`SKILL.md` (frontmatter drives description, argument hint, and model mapping). Each
command body loads the skill through the `skill` tool and forwards `$ARGUMENTS`;
workflow logic stays in the skill. They exist for commands-only compatibility; use
the skill tool rather than chaining commands. Source: opencode.ai/docs/commands/.

**AGENTS:opencode**
Native agent support at `.opencode/agents/<name>.md`. Frontmatter: `description` (required),
`mode` (`primary` | `subagent` | `all`), `model` (`provider/model-id[#variant]`), `system`,
ordered `permissions` rules, `steps`, `hidden`, `color`, `disabled`, and `request`. Legacy
fields such as `prompt`, `tools`, `permission`, `temperature`, `top_p`, and `disable` must not
be generated for V2 agents. Invoke subagents via `@mention` or the native
`subagent(agent, description, prompt, sessionID?, background?)` tool. Sources:
opencode.ai/v2/docs/agents/ and opencode.ai/v2/docs/tools/.

**HOOKS.PreToolUse:opencode**
opencode has a TypeScript plugin system with a `tool.execute.before` event that covers the
same surface area as Claude Code's PreToolUse hook. Marked `partial` because the `ycc` bundle
does not ship a TypeScript plugin in v1 — hook guidance is emitted as rule-embedded notes
only. Upgrading to `supported` requires publishing an `@yandy/opencode-ycc-hooks` npm package.

**HOOKS.PostToolUse:opencode**
Same constraint as HOOKS.PreToolUse:opencode. The underlying opencode event is
`tool.execute.after`.

**HOOKS.Stop:opencode**
Same constraint as HOOKS.PreToolUse:opencode. Closest opencode event is `session.idle`
(fires when a session's agentic loop halts).

**MCP:opencode**
Native MCP support in the top-level `"mcp"` key of `opencode.json`. Server values are either
`{type: "local", command: [argv0, …args], environment, timeout}` or
`{type: "remote", url, headers, oauth, timeout}`. Note the critical shape difference from
Claude Code: opencode's `command` is a single array containing both argv0 and args (no
separate `args` key), and `env` is spelled `environment`. OAuth uses RFC 7591 Dynamic Client
Registration when `clientId` is omitted. Source: opencode.ai/docs/mcp-servers/.

**DANGEROUS_MODE:opencode**
No equivalent to Claude Code's `--dangerously-skip-permissions` flag exists in opencode. The
OpenCode V2 permission model uses ordered `{action, resource, effect}` rules. Native actions
include `edit`, `shell`, `subagent`, `read`, `glob`, `grep`, `webfetch`, and `websearch`; the
last matching rule wins. Source: opencode.ai/v2/docs/permissions/.

**WORKTREE:claude**
Full support. Worktree isolation is **on by default** for the 9 worktree-aware skills; pass
`--no-worktree` to opt out. The legacy `--worktree` flag is accepted as a silent no-op.
Harness-managed worktrees exist (`Agent(isolation: "worktree")`, `EnterWorktree`, plus the
`WorktreeCreate` hook shipped by the native `ycc-hooks@ycc` plugin), but the current ycc
single-worktree contract should not use per-agent tool-side isolation for parallel task fan-out.
Instead, pre-create one feature worktree and point every agent at it via `Working directory:`.
A Bash fallback (`git worktree add`) is always available. See
`ycc/skills/_shared/references/worktree-strategy.md` for the single-worktree naming scheme.

**WORKTREE:cursor**
Partial. Worktree mode is on by default for the 9 worktree-aware skills; pass `--no-worktree`
to opt out. The legacy `--worktree` flag is a silent no-op. Skills emit `git worktree add`
instructions for the user; no auto-creation from the skill layer. Worktree support is
editor-side in Cursor and is not skill-programmable. See
`ycc/skills/_shared/references/worktree-strategy.md` for Cursor-specific guidance.

**WORKTREE:codex**
Partial. Worktree mode is on by default for the 9 worktree-aware skills; pass `--no-worktree`
to opt out. The legacy `--worktree` flag is a silent no-op. No tool-side isolation equivalent.
Skills instruct the agent to run `git worktree add` via Bash; auto-creation happens when the
instruction is embedded in the agent prompt. See
`ycc/skills/_shared/references/worktree-strategy.md` for the Bash-fallback protocol.

**WORKTREE:opencode**
Partial. Worktree mode is on by default for the 9 worktree-aware skills; pass `--no-worktree`
to opt out. The legacy `--worktree` flag is a silent no-op. Same as Codex — Bash via prompt,
no tool-side isolation. Skills embed `git worktree add` commands in agent prompts. See
`ycc/skills/_shared/references/worktree-strategy.md` for the Bash-fallback protocol.

**MODS:claude**
Supported from Claude Code 2.1.287 (CLI and desktop app). Mods live under `ycc/mods/` with their
own `ycc-mods` marketplace and install via `ycc sync --target claude --intent mods`.

**MODS:cursor**
Unsupported. `--intent mods` is reported and skipped; a translator step would map a mod's hooks
module onto Cursor's extension surface.

**MODS:codex**
Unsupported. Codex has no in-process hook module API; the intent is reported and skipped.

**MODS:opencode**
Unsupported. opencode plugins are the closest analogue, but no translator exists yet; the intent
is reported and skipped.

**SKILLS:omp**
Partial: `scripts/generate_omp_skills.py` generates every skill under `packages/omp/ycc/skills/`,
and it loads via `omp --plugin-dir`. Skills run as `/skill:<name>`, and `disable-model-invocation`
maps natively. `${CLAUDE_PLUGIN_ROOT}` and `_shared` paths become `skill://` URLs, and `_shared`
ships once as the hidden `ycc-shared` skill. `/ycc:<name>` becomes `/skill:<name>`. The tree ships
in the generated `ycc` package (YAN-1171), which is unlisted until release; `install.sh install
--target omp` installs it from a checkout (see INSTALL_PATH:omp). Workflow semantics (YAN-1170):
repo-local worktrees under `.omp/worktrees` (see WORKTREE:omp); fan-out uses one `task` batch and
calls `wait` until every owned job settles, because `-p`/JSON runs exit and drop pending async
results; `ask` exists only in the TUI and `--mode rpc-ui`, so `-p`, `--mode json`, `--mode rpc`
and subagents take each skill's declared default from `question-policy.md`; `--team` is
unsupported and fails closed. Per-skill status: `docs/internal/omp-workflow-semantics.md`.
Coexistence (YAN-1176): OMP also reads `~/.agents/skills` by default and lists a differing
same-name copy as `agents/<name>`. The default-on `dedupe` step of `install.sh install --target
omp` adds hash-owned `agents/<name>`, `codex/<name>` and `opencode/<name>` entries for
ycc-installed skills to the user `<agentDir>/config.yml` `skills.ignoredSkills` (never project
config), so each skill loads once from the package; `--only base` skips it and `remove --target
omp --only dedupe` takes the entries back. With `enabledProviders` including `claude`, standalone
`~/.claude/skills` copies outrank the package, and the installer warns.
Source: ADR 0002; spike §3; `docs/install/omp.md` (Coexistence With Other Runtimes).

**COMMANDS:omp**
Partial: `scripts/generate_omp_commands.py` writes one thin command per public skill to
`packages/omp/ycc/commands/<skill>.md`. Public means the directory is not `_`-prefixed and
`user-invocable` is not `false`; manual-only skills (`disable-model-invocation: true`) still get
one. Each command keeps the skill's `description` and `argument-hint`, reads `skill://<skill>`,
and passes `$ARGUMENTS`. OMP registers plugin commands as `<plugin>:<stem>`; the prefix is the catalog plugin name
for marketplace installs, else the `name` in `.claude-plugin/plugin.json` (or root
`plugin.json`), else the `--plugin-dir` basename. `.omp-plugin/plugin.json` does not set it, but
OMP keeps agent `model:` only with it, so the package root ships both manifests, named `ycc`,
for `/ycc:<skill>` (verified live on omp 18.12.3).
`omp plugin link` registers bare names, and OMP's built-ins (such as `/plan`) and bundled file
commands (such as `/init`) shadow them. Generation fails on names OMP cannot dispatch, duplicate
names, a `ycc` namespace or `ycc:<name>` equal to an OMP built-in name or alias (the set is pinned
from omp 18.12.3), empty descriptions, non-string hints and a non-boolean `user-invocable`.
`/skill:<name>` is an alternative when `skills.enableSkillCommands` is on (the default). The
generated root carries both manifests (YAN-1171); a checkout installs it with `install.sh install
--target omp`, and the repository publishes no OMP catalog until the package is listed (see
INSTALL_PATH:omp).
Source: spike §3.

**AGENTS:omp**
Partial: `scripts/generate_omp_agents.py` generates every agent as an OMP task agent under
`packages/omp/ycc/agents/`, and it loads via `omp --plugin-dir`. `name` and `description` are kept.
Tools map to OMP IDs (`WebSearch` → `web_search`, `WebFetch` → `read`, `NotebookEdit` → `edit`).
Claude tool names in agent prose are rewritten the same way, but only in tool contexts; fenced
code and other code spans stay verbatim. An `mcp__<server>__<tool>` entry must name a server
configured in `mcp-configs/mcp.json` (an unknown server fails generation) and is not a frontmatter
tool: OMP mounts every MCP tool in every agent. Models map to roles from `ycc/settings/models.json`
`targets.omp.agentModels`: `opus` → `@slow`, `sonnet` → `@task`, and `inherit` emits no `model:`.
`@slow` and `@task` resolve through the user's `modelRoles`, which `install.sh --target omp --settings`
can set (opt-in). `color` is dropped. Generation fails on any
other key, tool or model. It also fails on OMP's reserved session names (`main`, `sub`) and on
names that would shadow OMP's bundled agents (`task`, `sonic`, `scout`, `reviewer`,
`security-reviewer`, `seance`). Agent tool scope is enforced (YAN-1250): the generator renders each
agent's `Bash(<prefix>:*)` prefixes and `mcp__*` tools once, into
`packages/omp/ycc/extensions/agent-scopes.json`, and the scope guard extension beside it
(`extensions/scope-guard.ts`, declared in the package's `package.json` `omp.extensions`) reads that
file at load. Its `tool_call` handler acts only when `ctx.agent.kind` is `sub` and `ctx.agent.name`
is a ycc agent; the main session and other agents pass through. A scoped agent's `bash` command is
split into every pipeline, `&&`/`||`/`;`/`&`/newline chain, `( )` subshell and `{ }` group segment,
and each must match a prefix token by token after quote removal (`*` is exactly one argument). The
guard fails closed on `$` expansions, command substitution, backticks, process substitution,
here-documents, output redirection other than `/dev/null`, leading `VAR=value`, unbalanced quotes
or groups, and `find -exec`; wrappers such as `sudo`, `env`, `xargs` or `bash -c` are blocked unless
a prefix names them. The same data renders the agent's `## Shell scope (OMP)` prompt section. MCP
calls (`mcp__*`, top-level or through `write xd://mcp__*`, which OMP re-emits as a nested
`tool_call`) are blocked for agents that declared none and limited to the declared
`<server>`/`ycc-mcp:<server>` tools otherwise; `mcp://` resource reads are blocked for agents with a
declared MCP list. Plain `Bash` keeps full shell access. Limits: an allowed prefix trusts that
command's own options (`git -c`, `gh api`); MCP resources read through a server's native URI scheme
are not caught; the guard loads only from an installed package (`install.sh --target omp`, `omp
plugin install` or `link`), not from `omp --plugin-dir`, and not under `--no-extensions`; OMP
loads extensions at session start, so a running session needs a restart. Verified live on omp
18.12.5 (`ctx.agent` since 18.12.2) with a scripted model provider. OMP drops
agent `model:` only for Claude-dialect roots (a `.claude-plugin/plugin.json` without an
`.omp-plugin/plugin.json`). The generated `packages/omp/ycc` root ships `.omp-plugin/plugin.json`,
so it keeps agent `model:` both under `--plugin-dir` and as a marketplace install (YAN-1171).
Delegation: OMP `task` runs agents in the background
when `async.enabled` is set and inline otherwise; worktree isolation is the per-call `isolated`
flag (`task.isolation.enabled`, default off). Since YAN-1170 the generated dispatch reference
uses the `task({context, tasks: [...]})` batch shape (`agent`, not `subagent_type`), never sets
`isolated` for ycc fan-out, calls `wait` before yielding, and reads `agent://<id>` when an inline
summary is truncated at 5000 chars. Subagents have no `ask` tool and return choices to the
parent. OMP has no team tools; `--team` aborts, and `write agent://<id>` peer messaging is not a
team lifecycle.
Source: ADR 0002.

**HOOKS.PreToolUse:omp**
Unsupported. OMP never runs shell hooks or `hooks/hooks.json`; hooks load only as TypeScript
`ExtensionAPI` factories (`pi.on` events such as `tool_call`, `tool_result`, `session_stop`).
ycc ships no OMP hooks; herdr session reporting is herdr's own integration (`herdr integration install omp`)
and `WorktreeCreate` has no OMP event (YAN-1174). The one ycc OMP extension is the agent scope guard
(`tool_call`, see AGENTS:omp); it ports no Claude hook. Source: ADR 0002; spike §2.4.

**HOOKS.PostToolUse:omp**
Same constraint as HOOKS.PreToolUse:omp. The closest OMP event is `tool_result`.

**HOOKS.Stop:omp**
Same constraint as HOOKS.PreToolUse:omp. The closest OMP event is `session_stop`.

**MCP:omp**
Partial: `scripts/generate_omp_packages.py` builds `packages/omp/ycc-mcp/` whose `.mcp.json` is
`mcp-configs/mcp.json` after a secret-literal audit (credential keys must hold only `${VAR}`
placeholders). `install.sh install --target omp` installs it as
`ycc-mcp@ycc` with `ycc@ycc` (see INSTALL_PATH:omp). OMP's plugin MCP loader reads it natively,
names servers `ycc-mcp:<server>`, and expands `${VAR}` in `env`, `url` and `headers` at load
(unset variables arrive literally). The generator would add `?ycc-server=<name>` to the URL of a
later http/sse server whose connection equals an earlier one (YAN-1291), so both could load with
their own OAuth logins; the current source has no such duplicates, so the generated `.mcp.json`
equals the source byte-for-byte. Listed in the root OMP catalog
since YAN-1180, after the YAN-1178 live acceptance on the real tree. Gaps:
`ycc-mcp:playwright` is dropped while `browser.enabled` is on; plugin timeouts below 1000 ms are
ignored; per-server disable is the user `disabledServers` list, and `plugin-overrides.json` does
not hide plugin MCP; with `enabledProviders` including `claude`, equivalent `~/.claude.json`
servers shadow `ycc-mcp:*`.
Source: spike §2.5, §3; `docs/install/omp.md` (MCP Servers).

**INSTALL_PATH:omp**
Partial: native catalog plus `install.sh install --target omp` (omp `>=18.12.2` on PATH), with
live acceptance on Linux x86_64 only. `scripts/generate_omp_packages.py` builds `packages/omp/ycc/`,
`packages/omp/ycc-mcp/` and `packages/omp/ycc-rules/` with `.omp-plugin/plugin.json`,
`.claude-plugin/plugin.json` and `package.json` at the lockstep version, and the root
`.omp-plugin/marketplace.json` (relative `./packages/omp/<package>` sources) listing every row
`listed` in `ycc/settings/packages.json`: `ycc`, `ycc-mcp` and `ycc-rules` since YAN-1180. So
`omp plugin marketplace add https://github.com/yandy-r/ystack.git` then
`omp plugin install ycc@ycc` works without a checkout. `scripts/omp_install.py` either exports
the packages to `${XDG_DATA_HOME:-~/.local/share}/ycc/omp-marketplace` (`--mode local`, the
default) or uses `https://github.com/yandy-r/ystack.git` (`--mode repo`), registers that as the
`ycc` marketplace, and runs `omp plugin install --scope user <package>@ycc`
for `ycc`, `ycc-mcp` and `ycc-rules`
(`--project`: `--scope project` in the git root). Ownership is recorded per omp profile in
`~/.config/ycc/omp-native-install.json`; a re-run updates the marketplace and upgrades only on a
version change, and `remove` uninstalls only recorded installs. `--dry-run` previews every `omp`
call. `--target all` includes omp when omp `>=18.12.2` is on PATH and skips it otherwise.
`ycc-hooks` is excluded on OMP. Opt-in `--rules` symlinks `ycc/settings/rules/AGENTS.md` to
`<agentDir>/AGENTS.md`, and `--settings` merges `modelRoles.{default,slow,task}`,
`retry.fallbackChains.{default,slow,task}` (request-failure fallback to the bare fallback model,
keeping the turn's thinking level; OMP also uses `default` for chat roles without a chain and
single-model subagents, while `@slow`/`@task` subagents retry along the role's comma list) and
`tools.approvalMode: write` into the user `<agentDir>/config.yml` (hash-owned per leaf; user edits
win). Both are user scope only: `--project` with either is rejected. The default-on `dedupe` step
writes the user `config.yml` `skills.ignoredSkills` (see SKILLS:omp), also with `--project`;
`remove --project` also deletes the empty `.omp/plugins/` files omp leaves. OMP has no trust
prompt: installed plugin code runs in-process with full user privileges. Platforms (YAN-1556):
live acceptance covers Linux x86_64 only; macOS, Linux arm64/musl and WSL 2 are expected but
unverified, and native Windows (including Git Bash/MSYS) is unsupported: `install.sh` and the OMP
harnesses are Bash and use Bash 4+ features, `--rules` needs a symlink, and no Windows host has
run them. Source: ADR 0002;
`docs/install/omp.md` (Platform Support); `docs/internal/omp-acceptance.md`.

**DANGEROUS_MODE:omp**
Unsupported. ycc ships no mapping for `--dangerously-skip-permissions`. OMP's default
`tools.approvalMode` is already `yolo` and subagents are forced to yolo, so there is no Claude
flag analogue to emit. The opt-in `install.sh --target omp --settings` sets the user
`tools.approvalMode: write` (exec prompts in the main session); subagents still run as `yolo`, and a
project `.omp/config.yml` overrides it. Source: spike §2.10; `docs/install/omp.md` (Approvals).

**WORKTREE:omp**
Partial: skill-managed worktrees use `<repo-root>/.omp/worktrees/`. The OMP generator rewrites the
`worktree-paths.sh` default to `.omp`, and the portable `agents` bundle resolves `.omp` from
`OMPCODE=1` (OMP bash also sets `CLAUDECODE=1`, which `OMPCODE` consumes). Tested by
`scripts/test-worktree-roots.sh` (omp bundle and agents-bundle OMP cases). Gaps: OMP has no
`WorktreeCreate` event, so there is no native hook. OMP's own task isolation and
`omp worktree` place workspaces under `~/.omp/wt` (`OMP_WORKTREE_DIR`); ycc never sets
`isolated` and never deletes `~/.omp/wt`. The bash tool rewrites a literal `git worktree add`
to clone-first `omp worktree add`, which falls back to a plain checkout for in-repo roots.
No native-parity claim. Source: ADR 0002; `worktree-strategy.md` §1.

**MODS:omp**
Unsupported. The Claude Code mod API differs from OMP's `ExtensionAPI`; the status-bar mod is
not ported. Source: ADR 0002.

**SKILLS:pi**
Unsupported today: ycc ships no Pi skill tree. Planned `partial` (YAN-1184): Pi discovers package
`skills/<name>/SKILL.md` natively as `/skill:<name>`, and `disable-model-invocation` maps natively,
but Pi leaves `${CLAUDE_PLUGIN_ROOT}`, `/ycc:<name>` and body `$ARGUMENTS` literal, so the generator
must rewrite them and ship `_shared` inside the package. Floor pi `>=1.2.0`. Coexistence: Pi
discovers `~/.agents/skills` by default, so copies from the `agents` target load unadapted and
outrank a package skill of the same name (no namespacing, spike §1.5); YAN-1193 adds owned
`-~/.agents/skills/<n>/SKILL.md` dedupe overrides. Source: ADR 0003; spike §1.5, §3.

**COMMANDS:pi**
Unsupported today: ycc ships no Pi commands. Planned `partial` (YAN-1185): public entrypoints are
`ycc:<name>` extension commands that call `sendUserMessage("/skill:<name> …", {expandPromptTemplates: true})`,
because a prompt template that emits `/skill:x` is not expanded again. Source: ADR 0003 decision 2.

**AGENTS:pi**
Unsupported today: Pi has no built-in subagents and ycc ships no Pi agents. Planned `partial`
(YAN-1186): a ycc `subagent` extension tool loads the generated agent definitions from the package,
maps Claude tool names and models, and spawns child `pi --mode json -p --no-session` runs with depth
and concurrency limits. A verbatim ycc agent fails on Pi. Source: ADR 0003 decision 3; spike §2.7.

**HOOKS.PreToolUse:pi**
Unsupported. Pi never runs shell hooks or `hooks/hooks.json`; the closest surface is a TypeScript
extension `tool_call` handler, and `ycc-hooks` is excluded on Pi, so ycc ships no hook port (YAN-1191).
The ADR 0003 planned verdict is `partial` only for TypeScript handlers, never for shell hooks.
Source: ADR 0003 decision 5; spike §3.

**HOOKS.PostToolUse:pi**
Same constraint as HOOKS.PreToolUse:pi. The closest Pi event is `tool_result`.

**HOOKS.Stop:pi**
Same constraint as HOOKS.PreToolUse:pi. The closest Pi events are `agent_settled` and
`agent_before_settle`.

**MCP:pi**
Unsupported today: ycc ships no Pi MCP package. Planned `partial` (YAN-1190): Pi never reads
`mcp.json` from a package, so `ycc-mcp` becomes a registrar extension calling `pi.registerMcpServer`
(a same-name user `mcp.json` entry wins), with an opt-in `install.sh --mcp` merge into
`<agentDir>/mcp.json` as the fallback. Tools are named `mcp__<server>__<tool>` and SSE is rejected.
Source: ADR 0003 decision 4; spike §2.5.

**INSTALL_PATH:pi**
Unsupported today: no installable Pi package (`packages/pi/*/package.json`, written by the
YAN-1188 generator) and no `install.sh --target pi` exist. Skills generated earlier under
`packages/pi/ycc/skills` (YAN-1184) do not count. `scripts/validate_capability_matrix.py` and the
`PI1` audit fail if an installable package exists while this cell is `unsupported`, and fail if any
`pi` cell claims support or any `pi` package row is `included` without one. Planned `partial`
(YAN-1188, YAN-1189): `pi install <abs path>` at user scope or `pi install -l --approve <dir>` at
project scope, with no catalog. Floor pi `>=1.2.0`, recommended 1.5.0. Installed extensions are
full-trust code with no sandbox. Source: ADR 0003 decisions 1, 7, 8.

**DANGEROUS_MODE:pi**
Unsupported by design. Pi has no approval modes ("does not ask for approval before every tool
call"), so there is no `--dangerously-skip-permissions` analogue to emit; an extension `tool_call`
gate is the only way to add approvals. Source: ADR 0003 decision 6; spike §2.6.

**WORKTREE:pi**
Unsupported today: no ycc skill tree ships on Pi, and Pi has no `WorktreeCreate` event or
worktree API. Planned `partial` (YAN-1187): skills run `git worktree add` under `.pi/worktrees/`
through `bash`, and subagent `cwd` points there. Source: ADR 0003; spike §2.4.

**MODS:pi**
Unsupported by design. The Claude Code mod API differs from Pi's `ExtensionAPI`
(`ctx.ui.setStatus`/`setWidget`/`setFooter`); a status-bar port is new code outside the lockstep.
Source: ADR 0003 package matrix.

---

## Artifact store

Descriptive only; this is not a parsed capability row. The artifact store (`ycc/skills/_shared/references/artifact-store.md`) is skill-level and identical on claude, cursor, codex, opencode and omp: store resolution, the `.ycc/artifacts/` cache and the `.plans-config` pointer are plain files and Bash helpers, so no target needs extra support for `store: local`.

- **Linear mode needs a Linear MCP in the running runtime.** ycc ships the `linear` server from `ycc-mcp` where the MCP row is supported (claude, cursor, opencode). On codex and omp the MCP row is `partial`: the server installs, but a user's runtime may lack, shadow or not yet have authorized it (see the MCP:codex and MCP:omp notes), so linear mode can be unavailable there until a Linear MCP is configured by hand.
- Without a reachable, authorized Linear MCP, skills stop at the Linear call gate before any local write and suggest `store: local`. Local mode never calls Linear.
- Every generator emits `.ycc/artifacts/` and `.plans-config` paths verbatim; no target rewrites them. `scripts/validate-artifact-store.sh` checks the occurrence counts of each generated skills tree against `ycc/skills` and that a committed `store: linear` pointer is tracked and not ignored.

---

## How to Update This Document

Before changing any cell value, consult the three primary research artifacts that produced the
current verdicts:

1. `research/plugin-additions/report.md` — executive synthesis with platform source citations.
2. `research/plugin-additions/synthesis/innovation.md` — prioritized recommendations and
   rejected ideas, including the explicit warning against claiming cross-platform hook parity.
3. `research/plugin-additions/evidence/verification-log.md` — contradiction log and confidence
   ratings; specifically the Codex hook contradiction entry which drives the `unsupported`
   verdict for all HOOKS.\*:codex cells.

After updating a cell value, also update the corresponding note in the Notes section (or add
one if absent), and re-run the compatibility audit:

```
ycc:compatibility-audit
```

If the change affects generated bundles, follow the regeneration steps in `AGENTS.md` under
"Testing Changes".
