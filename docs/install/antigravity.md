# Antigravity Install Guide

This guide covers installing the `ycc` workflow bundle into Google Antigravity
with `install.sh`. The Antigravity App, the IDE and the `agy` CLI all read the
same global folder, `~/.gemini/config/`, so one install serves all three.

> **Status: experimental.** The plugin layout follows Antigravity's published
> plugin format, but the install has not yet passed a live acceptance run
> against `agy` and the App on a clean profile. Report anything that does not
> load. The research and the decisions behind this target are recorded in
> [`antigravity-runtime-contract.md`](../internal/spikes/antigravity-runtime-contract.md).

## What Gets Installed

`./scripts/sync.sh --only antigravity` generates three plugins under
`packages/antigravity/` from the Claude-facing `ycc/` source:

| Plugin      | Contents                                                                                                                  |
| ----------- | ------------------------------------------------------------------------------------------------------------------------- |
| `ycc`       | Every public skill (`skills/<name>/SKILL.md`), the shared helpers (`ycc-shared/`) and the custom agents (`agents/`).      |
| `ycc-mcp`   | The ycc MCP servers in `mcp_config.json` (HTTP servers use `serverUrl`; stdio servers keep `command` and `args`).         |
| `ycc-rules` | The ycc language and workflow rules (`rules/ycc-*.md`) with Antigravity triggers (`always_on`, `glob`, `model_decision`). |

Agents use Antigravity's tool names (`view_file`, `grep_search`,
`run_command`, …) and models (`pro`, `flash`, `inherit`). Claude-only MCP tool
grants are dropped. Skills reach their helpers by absolute paths under
`~/.gemini/config/plugins/ycc/`, so the install is global only.

Not shipped: hooks and settings (Antigravity has no ycc-managed equivalent), the
Claude mods, and custom slash commands (skills cover them).

## Prerequisites

- Bash 4 or newer and `python3`.
- A checkout of this repository.
- Optional: `agy` on `PATH`. With it, the installer runs
  `agy plugin install <path>` and `agy plugin uninstall <name>`. Without it, the
  installer places a ycc-owned copy of each plugin in
  `~/.gemini/config/plugins/`, which Antigravity loads the same way.

## Install

```bash
./install.sh install --target antigravity                          # ycc, ycc-mcp, ycc-rules
./install.sh install --target antigravity --package ycc            # skills and agents only
./install.sh install --target antigravity --dry-run                # preview; no writes
./install.sh sync    --target antigravity --intent base,rules      # plugins + AGENTS.md link
./install.sh remove  --target antigravity --intent base,rules      # take back what ycc installed
```

Intent mapping:

| Intent                                                   | Antigravity step |
| -------------------------------------------------------- | ---------------- |
| `base`, `skills`, `agents`, `commands`, `mcp`, `plugins` | `base`           |
| `rules`                                                  | `rules`          |
| `settings`, `hooks`, `mods`                              | no-op            |

- **`base`** installs the three plugins. Re-running it is idempotent: an
  unchanged plugin reports `is up to date`.
- **`rules`** is opt-in. It links `ycc/settings/rules/AGENTS.md` to
  `~/.gemini/config/AGENTS.md`; `remove` unlinks it only when it still points
  at this checkout.

`--project` and `--mode repo` are rejected: there is no project scope and no
published marketplace format. `--target all` includes antigravity only when
`agy` is on `PATH` or `~/.gemini/config/` already exists.

## Ownership

The installer records each plugin it places in
`~/.config/ycc/antigravity-install.json` (route, source and a content digest).

- A plugin folder ycc did not install is refused; `--force` replaces it.
- A copy identical to the generated plugin is adopted.
- `remove` deletes only unedited ycc-owned plugins. A plugin you edited after
  install is kept with a warning.

## Overrides

| Variable                     | Default            | Purpose                                                                                                                                       |
| ---------------------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `YCC_ANTIGRAVITY_CONFIG_DIR` | `~/.gemini/config` | The Antigravity config folder. Copy route only: the installed skills and agents are rewritten to point at it, and the `agy` route refuses it. |
| `YCC_ANTIGRAVITY_AGY`        | `agy` on `PATH`    | The `agy` binary to call.                                                                                                                     |

## Worktrees

ycc skills that create worktrees under Antigravity put them in
`<repo-root>/.antigravity/worktrees/`. Keep that path gitignored.

## Validate

```bash
./scripts/sync.sh --only antigravity
./scripts/validate.sh --only antigravity
```
