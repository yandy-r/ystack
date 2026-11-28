# Muse Code Install Guide

This guide covers installing the `ycc` workflow bundle into Muse Code (`muse`)
with `install.sh`.

> **Status: supported (muse 1.4.25).** The packages were checked against the
> `muse` 1.4.25 CLI: `muse plugins validate` reports no diagnostics and every
> skill, agent and MCP server as supported, and `muse plugins install`,
> `approve` and `remove` were run end to end. In live `muse exec` sessions, a
> ycc skill ran its `ycc-shared` helper, a `ycc/<agent>` subagent was spawned,
> and an HTTP (context7) and a stdio (playwright) ycc-mcp server were called.
> In the interactive TUI, `/ycc:plan` loaded and ran the skill. The same
> checks passed on a real user profile installed with `install.sh`. Report
> anything that does not load. The findings and
> decisions behind this target are in
> [`muse-runtime-contract.md`](../internal/spikes/muse-runtime-contract.md).

## What Gets Installed

`./scripts/sync.sh --only muse` generates three plugins under `packages/muse/`
from the Claude-facing `ycc/` source:

| Plugin      | Manifest                                         | Contents                                                                                                                                                                                                                  |
| ----------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ycc`       | `.claude-plugin/plugin.json` (Claude-compatible) | Every public skill (`skills/<name>/SKILL.md`, run in Muse as the slash command `/ycc:<name>`), the shared helpers (`ycc-shared/`) and the custom agents (`agents/<name>.md`, shown as `ycc/<name>`).                      |
| `ycc-mcp`   | `.muse-plugin/plugin.json` (native)              | The ycc MCP servers. HTTP servers use `transport: http`. Each stdio server starts through a generated `mcp/<id>.sh` launcher, because Muse treats any command argument that contains `/` as a file in the plugin.         |
| `ycc-rules` | `.muse-plugin/plugin.json` (native)              | The ycc language and common rules, each as a skill (`rules/<rule>/SKILL.md`) whose description is the rule's trigger plus its file globs. Muse plugins have no rules family, so Muse loads each rule when it is relevant. |

The `ycc` plugin uses the Claude-compatible manifest because Muse's native
manifest cannot carry agents. Agent `tools` use Muse's own tool names
(`read_file`, `search`, `write_file`, `edit_file`, `bash`, `web_fetch` and `web_search`). Muse's validator accepts Claude names
such as `Read`, but its runtime refuses to spawn an agent that uses them.
`Glob` and `Grep` both become `search`. `color` is never set, because a color Muse does not
recognize quietly disables the agent. MCP server ids use kebab-case:
`openaiDeveloperDocs` becomes `openai-developer-docs`.

Muse stores each installed plugin in a cache folder whose name changes with
every version. So skills cannot use a stable plugin path to reach their
helpers. Instead, the installer keeps its own copy of each plugin in
`~/.local/share/ycc/muse/<name>`, installs Muse's plugin from that copy, and
the skills point at that copy. The copy is always per user; `--project` only
changes the scope Muse installs the plugins at.

Not shipped:

- Hooks. Muse has no `WorktreeCreate` event, and herdr ships its own Muse hooks
  plugin.
- Always-on rules. Rules reach Muse as relevance-loaded skills; add `--rules`
  for the always-on `AGENTS.md`.
- Settings and the Claude mods. Separate `commands/` wrappers are not needed:
  Muse already lists every skill as `/ycc:<name>`.

## Prerequisites

- Bash 4 or newer and `python3`.
- A checkout of this repository.
- `muse` on `PATH`, or `YCC_MUSE_BIN` set to its path. The installer runs
  `muse plugins install`, `approve` and `remove`, and fails if it cannot find
  `muse`.

## Install

```bash
./install.sh install --target muse                           # ycc, ycc-mcp, ycc-rules
./install.sh install --target muse --package ycc             # skills and agents only
./install.sh install --target muse --project                 # Muse project scope
./install.sh install --target muse --dry-run                 # preview; no writes
./install.sh sync    --target muse --intent base,rules       # plugins + AGENTS.md link
./install.sh remove  --target muse --intent base,rules       # take back what ycc installed
```

Intent mapping:

| Intent                                                   | Muse step |
| -------------------------------------------------------- | --------- |
| `base`, `skills`, `agents`, `commands`, `mcp`, `plugins` | `base`    |
| `rules`                                                  | `rules`   |
| `settings`, `hooks`, `mods`                              | no-op     |

- **`base`** copies each plugin to `~/.local/share/ycc/muse/<name>`, then runs
  `muse plugins install <copy> --scope user` and
  `muse plugins approve <name>`. Muse holds plugin agents and MCP servers for
  review until they are approved. Set `YCC_MUSE_APPROVE=0` to skip approval and
  review them yourself with `muse plugins inspect`. You can run `base` again
  safely: a plugin that has not changed reports `is up to date`.
- **`rules`** (opt-in) links the shared ycc `AGENTS.md` to Muse's user rules
  file, `${XDG_CONFIG_HOME:-~/.config}/muse/AGENTS.md`. If you already have a
  rules file there, it is kept.
- `--project` installs the plugins at Muse's project scope
  (`muse plugins install --scope project`). `rules` stays user scope only.
- `--mode repo` is rejected: the only marketplace file Muse reads at a
  repository root, `.agents/plugins/marketplace.json`, is this repository's
  Codex catalog.
- `--target all` includes Muse only when `muse` is on `PATH`.

## Ownership and Removal

The installer records what it placed in `~/.config/ycc/muse-install.json`: a
fingerprint of each copy and of its source.

- If you edit an installed copy, `install` refuses to replace it and `remove`
  keeps it. Add `--force` to override.
- If a folder in `~/.local/share/ycc/muse/` was not placed by ycc, it is never
  touched without `--force`. A folder identical to the generated plugin is
  taken over as ycc's own.
- `remove` runs `muse plugins remove <name>` and then deletes the copy.

Overrides:

| Variable               | Effect                                                                                  |
| ---------------------- | --------------------------------------------------------------------------------------- |
| `YCC_MUSE_BIN`         | The `muse` binary to run.                                                               |
| `YCC_MUSE_PACKAGE_DIR` | Where the copies go. The copies' helper paths are rewritten to point at the new folder. |
| `YCC_MUSE_CONFIG_DIR`  | The folder that receives the `AGENTS.md` link.                                          |
| `YCC_MUSE_APPROVE=0`   | Skip `muse plugins approve`.                                                            |

## Troubleshooting

- **A stdio MCP server is skipped ("the transport closed unexpectedly").** Muse
  starts stdio servers with only a small part of your environment (`HOME`,
  `PATH`, `USER`, `LANG` and a few others). A version manager shim such as
  mise or asdf then needs a global tool version: run, for example,
  `mise use -g node@lts` so `npx` resolves without a project config.
- **"`skills_catalog` was trimmed to fit its size limit".** With `ycc`
  and `ycc-rules` installed, Muse shortens some skill descriptions in its
  catalog. Every skill still loads. Install `--package ycc,ycc-mcp` if you
  prefer full descriptions over the rule skills.
- **Remote servers ask for a sign-in.** Run the `muse mcp login ...` command
  Muse prints for that server, then restart Muse.

## Verify

```bash
muse plugins list                      # ycc, ycc-mcp and ycc-rules, enabled
muse plugins inspect ycc               # agents trusted_enabled after approval
muse skills list --source plugin       # plugin:ycc:<name> skills
python3 scripts/muse_install.py status # ycc's ownership view
```

In a Muse session, run a skill such as `/ycc:plan`, or ask Muse to use one of
the `ycc/<agent>` subagents.
