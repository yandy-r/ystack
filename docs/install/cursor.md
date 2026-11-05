# Cursor Install Guide

Cursor support is generated from the `ycc/` source tree and ships as native
plugins from the repository's Cursor marketplace. `install.sh` registers that
marketplace and merges the one piece no plugin carries: the CLI model
preference in `~/.cursor/cli-config.json`.

## Quick Start

The `ycc` marketplace lists `ycc` (skills, agents, commands), `ycc-rules`
(rules), `ycc-mcp` (MCP servers) and `ycc-hooks` (the `sessionStart` hook).
Add it from the agent CLI, then pick the packages in `/plugins` (the Cursor IDE
reaches the same marketplace under `/plugins` → Marketplace):

```bash
agent plugin marketplace add https://github.com/yandy-r/ystack
```

The agent CLI has no non-interactive `plugin install`, so the packages are
always selected in `/plugins`. From a checkout, `install.sh` does the same
registration:

```bash
./install.sh install --target cursor                       # register + /plugins hint for ycc
./install.sh install --target cursor --rules --mcp --hooks # the hint adds ycc-rules, ycc-mcp, ycc-hooks
```

The `base` step:

1. runs `agent plugin marketplace add https://github.com/yandy-r/ystack`, or
   reports `ycc marketplace already registered` when it is;
2. prints the `/plugins` step naming the packages the requested intents need:
   `Install the packages in Cursor: open /plugins (agent CLI or IDE), pick the 'ycc' marketplace and select: <packages>`;
3. runs the [legacy cleanup](README.md#automatic-legacy-cleanup), which retires
   the file copies, command wrappers, `sessionStart` hook, global MCP merges and
   rule links older installers wrote under `~/.cursor/`.

Cursor rejects filesystem marketplace sources, so local mode registers the
published GitHub catalog too (the installer says so). Without the `agent` CLI
the step warns with the manual IDE steps (open `/plugins`, add the marketplace
URL, install the packages) and does not fail.

Package IDs, payloads and evidence are in the
[Cursor package reference](v6/cursor.md).

## Intents And Steps

Cursor has two steps, `base` and `settings`:

| Intent                                 | Step       | `/plugins` hint names |
| -------------------------------------- | ---------- | --------------------- |
| `base`, `skills`, `agents`, `commands` | `base`     | `ycc`                 |
| `rules`                                | `base`     | `ycc-rules`           |
| `mcp`                                  | `base`     | `ycc-mcp`             |
| `hooks`                                | `base`     | `ycc-hooks`           |
| `settings`                             | `settings` | —                     |
| `plugins`, `mods`                      | no-op      | —                     |

```bash
./install.sh sync --target cursor --intent base,rules,mcp,hooks
./install.sh sync --target cursor --intent settings --global
./install.sh install --target cursor --package ycc,ycc-hooks
```

`install --package` maps every Cursor package to the `base` step (the hint
names the selected packages) plus the `settings` fallback. The selection flags
(`--skills`, `--agents`, `--commands`, `--mcps`, `--with-deps`,
`--skills-home`) do not apply to Cursor.

## Settings

```bash
./install.sh install --target cursor --only settings --global
```

`settings` merges `packages/cursor/installer-fallback/config/cli-config.json`
into `~/.cursor/cli-config.json`. The file is generated from
`ycc/settings/cursor/cli-config.json`; edit the source, not the generated copy.

Cursor settings have no project scope: Cursor's project `.cursor/cli.json`
carries permissions only, and every other CLI setting must be set globally.
Without `--global` the `settings` step is skipped with a notice and writes
nothing; an explicit `--project` is rejected. See
[Project Vs Global Scope](README.md#project-vs-global-scope).

## Model Configuration

Cursor splits model selection across two surfaces, so this repository manages
both:

| Surface         | File                                        | Value                                   |
| --------------- | ------------------------------------------- | --------------------------------------- |
| Main CLI model  | `~/.cursor/cli-config.json`                 | `claude-fable-5-1`                      |
| Sub-agent model | each agent in the `ycc` package's `agents/` | `claude-opus-5[effort=high,context=1m]` |

Sub-agent models live in each generated agent's frontmatter because that is
where Cursor resolves them. `scripts/cursor_fast_agents.json` remains an
explicit opt-in escape hatch for individual agents, but is empty by default so
every generated subagent uses Opus High.

Both values are placeholders in the sense that Cursor may override them: model
availability is plan- and admin-gated, and legacy request-based plans can force
subagents onto Composer regardless of configuration.

## Remove

```bash
./install.sh remove --target cursor --only base               # marketplace + legacy cleanup
./install.sh remove --target cursor --intent settings --global
```

`remove --only base` runs `agent plugin marketplace remove ycc` when the
marketplace is registered, then the legacy cleanup. Uninstall the packages
themselves in `/plugins`. Without the `agent` CLI it warns to remove them in
the Cursor IDE.

## Hooks: sessionStart Only

`ycc-hooks@ycc` registers Cursor's `sessionStart` event only. The canonical
herdr hook reports the agent session only when its herdr environment is
configured; otherwise it exits without reporting. `WorktreeCreate` is
unavailable on Cursor and is not implemented. The settings-only
`cli-config.json` registers no hooks.

## Global Rules

Cursor User Rules live in Cursor Settings (Customize → Rules); file-based
user-global provisioning is unsupported/unverified per
[cursor.com/docs/rules](https://cursor.com/docs/rules). The ycc rules ship as
the `ycc-rules` package. Older `~/.cursor/CLAUDE.md` / `AGENTS.md` links that
point at this checkout are retired by the legacy cleanup.

## MCP

The `ycc-mcp` package carries the managed servers (`mcp-configs/mcp.json`) with
`${VAR}` placeholders. Older installers merged them into `~/.cursor/mcp.json`;
the legacy cleanup takes back only the servers recorded as ycc-written, and
your own servers stay. A `<project>/.cursor/mcp.json` an older installer wrote
is not touched; remove its ycc servers by hand.

## Runtime Evidence And Native Limits

The v6.0.0 maintainer verification (tracked in YAN-1141) covered the
interactive Cursor marketplace installation of the four packages, through both
the agent CLI and the Cursor IDE. `agent --plugin-dir <dir>` loads a local
plugin's `sessionStart` hook in that one process without an account install.
See [the internal evidence record](../internal/cursor-native-packages.md#observed-verification).

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
`.cursor-plugin/marketplace.json`. Cursor installs them from the published
repository, so local edits reach Cursor only after they are pushed.
