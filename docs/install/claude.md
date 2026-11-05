# Claude Install Guide

This guide covers Claude Code and Claude Desktop. Claude Code installs `ycc` as
native plugins. Claude Desktop does not load Claude Code plugins or slash
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

From a checkout, `install.sh` runs the same plugin CLI and also delivers what
plugins cannot carry (settings, the statusline, the `CLAUDE.md` rules, and the
mods). Run this from the repository root:

```bash
./install.sh install --target claude                 # ycc@ycc
./install.sh install --target claude --mcp --hooks   # + ycc-mcp@ycc and ycc-hooks@ycc in this project
```

The `base` step registers this checkout as the `ycc` marketplace
(`claude plugin marketplace add <checkout> --scope user`) and installs `ycc@ycc`
at user scope. After the command completes, run `/reload-plugins` in Claude Code
or start a new Claude Code session.

Package IDs, the config shape and tested versions are in the
[Claude package reference](v6/claude.md).

## Add MCP, Hooks, Settings, Rules, And Plugins

```bash
./install.sh sync --target claude --intent base,mcp,hooks,settings,rules       # this project
./install.sh sync --target claude --intent mcp,hooks,settings,plugins --global # user scope
```

`sync` never runs `base` unless you name it. The step-flag `install` form is
equivalent:

```bash
./install.sh install --target claude --settings --rules --mcp --hooks
./install.sh install --target claude --only mcp,hooks --global
./install.sh install --target claude --only settings --global
```

Step behavior:

| Step       | Effect                                                                                                                                                                                                                                                                                                                      |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `base`     | Runs `claude plugin marketplace add <checkout or yandy-r/ystack> --scope user` and `claude plugin install ycc@ycc --scope user`, then the [legacy cleanup](README.md#automatic-legacy-cleanup). The `skills`, `agents` and `commands` intents map here: those components ship only inside `ycc@ycc`.                        |
| `mcp`      | `claude plugin install ycc-mcp@ycc --scope project` (default) or `--scope user` (`--global`).                                                                                                                                                                                                                               |
| `hooks`    | `claude plugin install ycc-hooks@ycc --scope project` (default) or `--scope user` (`--global`). Needs Claude Code 2.1.300 or later. The hook keeps worktrees in `<repo>/.claude/worktrees/`.                                                                                                                                |
| `settings` | Default (project): merges the preference keys (`env`, `attribution`, `model`, `modelSettings`, `alwaysThinkingEnabled`, `effortLevel`) from `ycc/settings/settings.json` into `<project>/.claude/settings.json`. With `--global`: merges every managed key into `~/.claude/settings.json` and copies the statusline script. |
| `rules`    | Symlinks `ycc/settings/rules/CLAUDE.md` into `~/.claude/CLAUDE.md`, the user memory file Claude Code reads.                                                                                                                                                                                                                 |
| `mods`     | Registers `ycc/mods/` as the local `ycc-mods` marketplace and installs every mod it lists. Sync with `--intent mods`; see [`ycc/mods`](../../ycc/mods/README.md).                                                                                                                                                           |

The `plugins` intent maps to `settings` and merges `enabledPlugins` and
marketplace entries into `~/.claude/settings.json` (`--global` only).

Settings are merge-safe: unmanaged local keys are preserved, and managed keys
you changed locally are kept unless `--force` is passed. Model defaults are
`claude-fable-5-1` at Medium effort for the main session and `opus[1m]` at High
effort for subagents. `--rules` symlinks the global rules file so edits stay live.

## MCP And Hooks Scope

The `mcp` and `hooks` steps install the native plugins at project scope by
default (project = git root of the current directory, else the current
directory). Claude Code writes the enablement to `<project>/.claude/settings.json`.
Pass `--global` to install them at user scope instead:

```bash
./install.sh sync --target claude --intent mcp,hooks             # this project
./install.sh sync --target claude --intent mcp,hooks --global    # every project
./install.sh remove --target claude --intent mcp,hooks           # uninstall the project plugins
./install.sh remove --target claude --intent mcp,hooks --global  # uninstall the user plugins
```

- Project scope is refused at `$HOME`.
- When the project does not yet know the `ycc` marketplace, the installer
  declares it in `<project>/.claude/settings.local.json` (local mode) or
  `<project>/.claude/settings.json` (repo mode), and never repoints an existing
  declaration. See [Claude Project Plugins](README.md#claude-project-plugins).
- `hooks` at either scope needs Claude Code 2.1.300 or later. An explicit
  `--target claude` run stops with `ycc-hooks needs Claude Code 2.1.300 or later`
  on an older client; `--target all` warns and skips the step.
- `install --package ycc-mcp` or `ycc-hooks` installs the plugin at user scope.

The native plugins replace the MCP servers and `WorktreeCreate` hook older
installers merged into `~/.claude.json` and `~/.claude/settings.json`. Those
are retired automatically once `ycc-mcp@ycc` / `ycc-hooks@ycc` is enabled in
`~/.claude/settings.json`, which a `--global` install does. A project install
leaves them in place, and a plugin hook plus a leftover settings hook would both
run. See [Automatic Legacy Cleanup](README.md#automatic-legacy-cleanup).

## Settings Scope

The `settings` step defaults to the project's shared `.claude/settings.json`,
the file Claude Code reads from the session's working directory and that
outranks `~/.claude/settings.json`. Only preference keys go there.
`statusLine` (it points at a script only the global step installs),
`permissions`, `skipAutoPermissionPrompt` and
`skipDangerousModePermissionPrompt` stay global, as does the `plugins` config
group: `--intent plugins` without `--global` is skipped with a notice.

`.claude/settings.json` is usually committed, so its values apply to everyone
who works in the repository. Review the diff before committing, or keep these
preferences global with `--global`. From `$HOME` a default run skips the step
with a notice. A defaulted run warns while `~/.claude/settings.json` still holds
ycc-managed keys. See
[Project Vs Global Scope](README.md#project-vs-global-scope).

## Global Rules

Claude Code documents `~/.claude/CLAUDE.md` as its user memory file
([official memory guide](https://code.claude.com/docs/en/memory)). The `rules`
step links only that file. Older `~/.claude/AGENTS.md` links are left alone on
install; `remove --intent rules` still removes them if owned by this checkout.
Real files and foreign links are preserved on remove.

Rules symlinks stop rather than overwrite an existing real rules file; pass
`--force` when you intentionally want to replace it. Structured config files
merge instead, so `--force` there only resolves conflicts on managed keys you
edited locally.

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
repository instead of a local checkout. Update it with
`claude plugin install ycc@ycc --scope user` or the in-Claude `/plugins` UI.

## Mods

Narrow the mods step to named mods with `--mods`:

```bash
./install.sh sync   --target claude --intent mods --mods status-bar
./install.sh remove --target claude --intent mods --mods status-bar
```

See [Selecting Mods](README.md#selecting-mods).

## Skills As Slash Commands

Claude Code has no separate command layer for ycc. Public skills are native
`/ycc:<name>` slash invocations from `ycc@ycc`; skills with
`user-invocable: false` stay hidden from the slash menu.

Older ycc releases also installed standalone copies into `~/.claude/skills` and
`~/.claude/agents`, and wrappers into `~/.claude/commands`. The `base` step
retires the ones ycc recorded in `~/.config/ycc/installed-units.json` (or that
are identical to the bundle); foreign or edited files stay.

## Live Iteration

In local mode, edits under `ycc/` are picked up by Claude Code after
`/reload-plugins`. No rsync or cache clear is needed. The `WorktreeCreate` hook
ships in `ycc-hooks@ycc` from the generated `packages/claude/ycc-hooks/`; rerun
`./scripts/sync.sh --only claude` after editing `ycc/settings/hooks/`.

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

Restart Claude Desktop after editing the config. The installer's `mcp` step
installs the Claude Code `ycc-mcp@ycc` plugin; it does not edit the Claude
Desktop config.
