# Claude Install Guide

This guide covers Claude Code and Claude Desktop. Claude Code can install the
`ycc` plugins. Claude Desktop does not load Claude Code plugins or slash
commands, but it can use the shared MCP server configuration.

## Claude Code Quick Start

The `ycc` marketplace lists four plugins: `ycc` (skills and agents), `ycc-mcp`
(MCP servers), `ycc-hooks` (the `WorktreeCreate` hook; needs Claude Code
2.1.300 or later), and `ycc-all` (installs the other three through
dependencies). Install straight from the published repository:

```bash
claude plugin marketplace add yandy-r/ystack
claude plugin install ycc-all@ycc    # or ycc@ycc, ycc-mcp@ycc, ycc-hooks@ycc individually
```

See [Claude native packages](v6/claude.md) for the package model and
[Migrating To Native Packages](README.md#migrating-to-native-packages) to move
an existing `install.sh` setup onto them. Rules, `CLAUDE.md` instructions,
settings, and the statusline stay on `install.sh`.

From a checkout, run this from the repository root:

```bash
./install.sh install --target claude
```

The default `base` step registers this checkout as a Claude plugin marketplace
source and installs `ycc@ycc` through the Claude CLI. Add the native add-ons
with `claude plugin install ycc-mcp@ycc` and `claude plugin install ycc-hooks@ycc`
(or use the marketplace command above).

After the command completes, run `/reload-plugins` in Claude Code or start a new
Claude Code session.

## Add Settings, Rules, MCP, Hooks, And Plugins

For a full local Claude Code sync without implicitly running plugin registration:

```bash
./install.sh sync --target claude --intent hooks,settings,mcp,plugins,rules
```

Add `base` to the intent list when you also want the Claude CLI to register and
install the plugin marketplace. The step-flag `install` form is equivalent:

```bash
./install.sh install --target claude --settings --rules --mcp --hooks
```

Step behavior:

| Step                           | Effect                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `base`                         | Runs `claude plugin marketplace add <repo> --scope user` and `claude plugin install ycc@ycc --scope user`.                                                                                                                                                                                                                                                                                         |
| `settings`                     | Merges managed keys from `ycc/settings/settings.json` into `~/.claude/settings.json` and copies `ycc/settings/statusline-command.sh` into `~/.claude/`.                                                                                                                                                                                                                                            |
| `rules`                        | Symlinks `ycc/settings/rules/CLAUDE.md` into `~/.claude/CLAUDE.md`, the user memory file Claude Code reads.                                                                                                                                                                                                                                                                                        |
| `mcp`                          | Merges `mcp-configs/mcp.json` into `<project>/.mcp.json` (or `~/.claude.json` with `--global`).                                                                                                                                                                                                                                                                                                    |
| `hooks`                        | Default (project): `claude plugin install ycc-hooks@ycc --scope project`, declaring the `ycc` marketplace at project scope (repo mode, committed to `.claude/settings.json`) or local scope (local mode, `.claude/settings.local.json`) only when no visible declaration already supplies it. With `--global`: symlinks `ycc/settings/hooks/` into `~/.claude/hooks/` and merges the hooks config. |
| `skills`, `agents`, `commands` | Claude `skills` installs standalone skill entries; `commands` is a compatibility alias for that same install. `agents` copies standalone agents. Skills are native `/name` invocations; `user-invocable: false` skills stay hidden. See [Standalone Slices](README.md#standalone-slices).                                                                                                          |
| `mods`                         | Registers `ycc/mods/` as the local `ycc-mods` marketplace and installs every mod it lists. Sync with `--intent mods`; see [`ycc/mods`](../../ycc/mods/README.md).                                                                                                                                                                                                                                  |

Settings are merge-safe: unmanaged local keys are preserved, and managed keys
you changed locally are kept unless `--force` is passed. Model defaults are
`claude-fable-5-1` at Medium effort for the main session and `opus[1m]` at High
effort for subagents. `--rules` symlinks the global rules file so edits stay live.

## Global Rules

Claude Code documents `~/.claude/CLAUDE.md` as its user memory file
([official memory guide](https://code.claude.com/docs/en/memory)). The `rules`
step links only that file. Older `~/.claude/AGENTS.md` links are left alone on
install; `remove --intent rules` still removes them if owned by this checkout.
Real files and foreign links are preserved on remove.

The directory-source plugin install model is local-mode guidance below, not a
user-global instruction: it does not belong in every project's rules prompt.

## Local Vs Repo Mode

Local mode is the default and points Claude Code at this checkout:

```bash
./install.sh install --target claude --mode local
```

Repo mode registers the upstream GitHub repository instead:

```bash
./install.sh install --target claude --mode repo
```

Use repo mode for a non-developer install that should track the published
repository instead of a local checkout.

## Selective Steps

Use `--only` when you want exactly one step or a small set of steps:

```bash
./install.sh install --target claude --only base
./install.sh install --target claude --only settings
./install.sh install --target claude --only rules
./install.sh install --target claude --only mcp           # writes <project>/.mcp.json
./install.sh install --target claude --only mcp --global  # writes ~/.claude.json
./install.sh install --target claude --only hooks         # project scope: ycc-hooks@ycc in this project (refused at $HOME)
```

Narrow the mods step or the managed hook events to named items with `--mods`
and (on `sync` / `remove` only) `--hooks`; `install --hooks` stays the boolean
"also run the hooks step" flag:

```bash
./install.sh sync   --target claude --intent mods --mods status-bar
./install.sh sync   --target claude --intent hooks --hooks WorktreeCreate --global
./install.sh remove --target claude --intent hooks --hooks WorktreeCreate --global
```

`--hooks <events>` narrows the `settings.json` hook events of the `--global`
hooks step only; the project plugin carries its own activation, so the
project-scope step accepts no event selection.

See [Selecting Mods And Hook Events](README.md#selecting-mods-and-hook-events).

Rules symlinks stop rather than overwrite an existing real rules file; pass
`--force` when you intentionally want to replace it. Structured config files
merge instead, so `--force` there only resolves conflicts on managed keys you
edited locally.

## MCP Scope And Removal

The `mcp` step writes `<project>/.mcp.json` by default (project = git root of
the current directory, else the current directory). Pass `--global` for
`~/.claude.json`, the pre-scope destination.

```bash
./install.sh remove --target claude --only mcp            # from <project>/.mcp.json
./install.sh remove --target claude --intent mcp --global # from ~/.claude.json
```

See [Project Vs Global Scope](README.md#project-vs-global-scope) and
[Removing Installed Config](README.md#removing-installed-config) for the rules shared by
every target.

## Skills As Slash Commands

Claude Code has no separate command layer for ycc. Public skills are native
`/ycc:<name>` slash invocations; skills with `user-invocable: false` stay hidden
from the slash menu.

Standalone installs use the same skills. On Claude, `commands` is an alias for
`skills`: `--intent commands` or `--only commands` installs the standalone skills
(including `_shared` helpers) into `~/.claude/skills/`. Older ycc releases wrote
per-command wrappers to `~/.claude/commands/`. A successful skills install removes
only the wrappers ycc recorded in `~/.config/ycc/installed-units.json`; foreign or
unrecorded files stay, even with `--force`. The directory is removed only when empty.
`remove --target claude --intent commands` retires only those recorded wrappers.

## Live Iteration

In local mode, edits under `ycc/` are picked up by Claude Code after
`/reload-plugins`. No rsync or cache clear is needed.

If you move or rename this checkout, refresh the registered marketplace path:

```bash
./install.sh install --target claude --only base
```

## Claude Desktop

Claude Desktop does not currently consume Claude Code plugin marketplaces, `ycc`
skills, or `ycc` slash commands. Use Claude Code for the plugin workflow.

Claude Desktop can use the shared MCP server definitions from
[`../../mcp-configs/mcp.json`](../../mcp-configs/mcp.json). Add the `mcpServers`
object from that file to your Claude Desktop config, preserving any existing
servers.

Common Claude Desktop config locations:

| Platform | Config path                                                       |
| -------- | ----------------------------------------------------------------- |
| macOS    | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Windows  | `%APPDATA%\\Claude\\claude_desktop_config.json`                   |

The resulting file should contain a top-level `mcpServers` object:

```json
{
  "mcpServers": {
    "example-server": {
      "command": "example",
      "args": []
    }
  }
}
```

Restart Claude Desktop after editing the config.

Note: `./install.sh install --target claude --mcp` (or `--only mcp`) now updates
`<project>/.mcp.json` by default. Pass `--global` to write `~/.claude.json` (the
Claude Code MCP file). It does not edit the Claude Desktop config path.
