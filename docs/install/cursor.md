# Cursor Install Guide

Cursor support is generated from the `ycc/` source tree. It is available as
native plugins from the repository's Cursor marketplace and as files synced
into Cursor-native config directories by `install.sh`.

## Native Plugins

The `ycc` marketplace lists `ycc`, `ycc-mcp`, `ycc-hooks`, and `ycc-rules`.
Add it from the agent CLI, then pick the packages in `/plugins` (the Cursor IDE
reaches the same marketplace under `/plugins` → Marketplace):

```bash
agent plugin marketplace add https://github.com/yandy-r/ystack
```

`ycc-hooks` registers `sessionStart` only; `WorktreeCreate` is not available
on Cursor. See [Cursor native packages](v6/cursor.md) for the package model, and
[Migrating To Native Packages](README.md#migrating-to-native-packages) to move
an existing file-copy install onto them (`migrate --target cursor` prints the
`/add-plugin` step).

## Quick Start (file copy)

From the repository root:

```bash
./install.sh install --target cursor
```

The default `base` step generates, validates, formats, and rsyncs the Cursor
bundle into `~/.cursor/`.

## Add Commands, Settings, Rules, MCP, And Optional Hooks

After the base install, add the command wrappers and optional configuration:

```bash
./install.sh sync --target cursor --intent commands,settings,rules,mcp
```

To combine the base install with those steps:

```bash
./install.sh install --target cursor --only base,commands,settings,rules,mcp
```

Step behavior:

| Step       | Effect                                                                                                                                                                                                                 |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `base`     | Generates and validates `packages/cursor/ycc/{skills,agents}` and `packages/cursor/ycc-rules/rules`, then rsyncs them into `~/.cursor/`.                                                                               |
| `skills`   | Generates the skills and installs each into `~/.cursor/skills/<name>`, leaving your own skills alone.                                                                                                                  |
| `agents`   | Generates the agents and installs each into `~/.cursor/agents/<name>.md`.                                                                                                                                              |
| `commands` | Installs user-invocable skill wrappers into `~/.cursor/commands/<name>.md`, rewriting plugin-local skill references to absolute installed skill paths. Install the corresponding skills with `base` or `skills` first. |
| `settings` | Merges `packages/cursor/installer-fallback/config/cli-config.json` into `~/.cursor/cli-config.json`. This file is generated from `ycc/settings/cursor/cli-config.json`; edit the source, not the generated copy.       |
| `rules`    | Links nothing: Cursor User Rules are set in Settings → Rules, not a file. Prints how to paste `ycc/settings/rules/CLAUDE.md`.                                                                                          |
| `mcp`      | Merges `mcp-configs/mcp.json` into `<project>/.cursor/mcp.json` (or `~/.cursor/mcp.json` with `--global`).                                                                                                             |
| `hooks`    | Optionally copies the canonical herdr session script into `~/.cursor/hooks/` and merges its `sessionStart` registration into `~/.cursor/hooks.json`, preserving unrelated user hooks.                                  |

Only `plugins` remains a no-op among these intents: the installer does not
activate account-native plugins. The generated `rules/` bundle unit ships with
`base` only. Default `base` remains skills, agents, and rules; commands and
hooks are explicit steps. Adding hooks is optional (`--hooks` also enables it).

For package-aware file delivery:

```bash
./install.sh install --target cursor --package ycc
./install.sh install --target cursor --package ycc-hooks
```

`ycc` owns the commands carrier (`ycc` selects `base,commands,settings`);
`ycc-hooks` owns the hooks carrier (`ycc-hooks` selects `settings,hooks`).
`ycc-mcp` selects `settings,mcp`; `ycc-rules` selects `base` (rules unit) plus
`settings`. Selecting `ycc` or `ycc-rules` does not inherit the fallback's
optional hooks. Neither package form registers a marketplace, activates a
native account plugin, or treats a plugin cache as evidence of activation.

### Optional Session Hook

```bash
./install.sh sync --target cursor --intent hooks
./install.sh remove --target cursor --intent hooks
```

Only Cursor's `sessionStart` event is managed. The canonical herdr hook reports
the agent session only when its herdr environment is configured; otherwise it
exits without reporting. `WorktreeCreate` is unavailable for Cursor and is not
implemented by the fallback. The settings-only `cli-config.json` does not
register hooks.

Command wrappers and the hook script have per-entry ownership in
`installed-units.json`; the hook registration has ownership hashes in
`managed-config-state.json`. Hook registration uses list-union on
`hooks.sessionStart`, preserving foreign commands and unrelated event keys;
removal takes back only tool-appended items. A conflicting foreign file is not
overwritten without `--force`, and locally edited managed entries are not
silently overwritten or deleted. Invalid `hooks.json` shapes (a version other
than `1`, non-list events, or non-command `sessionStart` entries) fail closed
before carrier writes. Back up configuration before using `--force`.

## Model Configuration

Cursor splits model selection across two surfaces, so this repository manages
both:

| Surface         | File                        | Value                                   |
| --------------- | --------------------------- | --------------------------------------- |
| Main CLI model  | `~/.cursor/cli-config.json` | `claude-fable-5-1`                      |
| Sub-agent model | `~/.cursor/agents/*.md`     | `claude-opus-5[effort=high,context=1m]` |

Sub-agent models live in each generated agent's frontmatter because that is
where Cursor resolves them. `scripts/cursor_fast_agents.json` remains an
explicit opt-in escape hatch for individual agents, but is empty by default so
every generated subagent uses Opus High.

Both values are placeholders in the sense that Cursor may override them: model
availability is plan- and admin-gated, and legacy request-based plans can force
subagents onto Composer regardless of configuration.

## Selective Steps

Use `--only` to run exactly the listed steps:

```bash
./install.sh install --target cursor --only base
./install.sh install --target cursor --only settings
./install.sh install --target cursor --only rules
./install.sh install --target cursor --only commands             # requires installed skills
./install.sh install --target cursor --only hooks                # optional sessionStart hook
./install.sh remove --target cursor --intent commands,hooks      # managed entries only
./install.sh install --target cursor --only mcp                   # <project>/.cursor/mcp.json
./install.sh install --target cursor --only mcp --global          # ~/.cursor/mcp.json
./install.sh remove --target cursor --only mcp --global   # remove managed servers
```

MCP servers are merged, not symlinked, so servers you add survive; a symlink
left at `~/.cursor/mcp.json` by older installers becomes a real file on the
next `--global` run. See
[Project Vs Global Scope](README.md#project-vs-global-scope) and
[Removing Installed Config](README.md#removing-installed-config).

`--mode repo` is not supported for Cursor. Cursor reads files from local config
directories, so use the default local mode.

## Installed Surfaces

| Surface      | Location                                             |
| ------------ | ---------------------------------------------------- |
| Skills       | `~/.cursor/skills/`                                  |
| Agents       | `~/.cursor/agents/`                                  |
| Commands     | `~/.cursor/commands/`                                |
| Hooks        | `~/.cursor/hooks.json` and `~/.cursor/hooks/`        |
| Cursor rules | `~/.cursor/rules/`                                   |
| CLI config   | `~/.cursor/cli-config.json`                          |
| MCP config   | `<project>/.cursor/mcp.json` or `~/.cursor/mcp.json` |

Cursor User Rules live in Cursor Settings (Customize → Rules); file-based
user-global provisioning is unsupported/unverified per
[cursor.com/docs/rules](https://cursor.com/docs/rules), so `rules` creates no
files. Older `~/.cursor/CLAUDE.md` / `AGENTS.md` links are left in place on
install and removed by `remove --intent rules` only while they point at this checkout.

## Runtime Evidence And Native Limits

User-file command and hook loading was exercised with `cursor-agent
2026.10.14-941492e` in an isolated `HOME` and `XDG_CONFIG_HOME`. A fixture
command wrapper returned its exact marker. The opt-in full-installer smoke
then installed the canonical `go-patterns` wrapper and skill: `/go-patterns`
read the absolute installed skill path and returned `Go Development Patterns`.
The installed herdr `sessionStart` hook reported the same session ID as the
runtime result, a foreign `sessionStart` hook fired for that session, the
foreign command survived, and `$ARGUMENTS` substitution reached the model.
See [the internal evidence record](../internal/cursor-native-packages.md#observed-verification).

Maintainers can repeat the authenticated, opt-in carrier smoke with
`python3 scripts/cursor_live_smoke.py --keep`. It runs the real package installer
with build/generation phases skipped, uses disposable configuration, performs
real model inference, and removes the copied credential even when retaining the
lab. It is not a CI or validation-suite check.

This proves the user-file carriers; the native plugins are installed
interactively through the marketplace described under
[Native Plugins](#native-plugins).

Agent shell scope is not enforced on Cursor. Cursor subagents have no
per-command allowlist (only `readonly`), and shell hooks do not identify the
subagent that runs a command. The fixer agents (`pr-comment-fixer`,
`review-fixer`, `release-fix-applier`) therefore keep their validation-command
allowlist as a prompt instruction. OpenCode and OMP enforce the same lists
natively.

## Regenerate Only Cursor Artifacts

After editing source files under `ycc/`, regenerate Cursor artifacts directly or
through the unified sync script:

```bash
./scripts/sync.sh --only cursor
./scripts/validate.sh --only cursor,cursor-native,packages
```

The generated native packages live under `packages/cursor/` (`ycc`, `ycc-rules`,
`ycc-mcp`, and `ycc-hooks`) and are listed by the root
`.cursor-plugin/marketplace.json`; the file-copy installer above remains the
fallback route.
