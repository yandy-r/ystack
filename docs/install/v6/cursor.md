# Cursor Package Reference (v6 native packages)

Cursor installs `ycc` as four native plugins from the `ycc` marketplace in this
repository (`yandy-r/ystack`, root `.cursor-plugin/marketplace.json`). This page
is the package reference: IDs, payloads, marketplace shape, evidence. The
install how-to is [Cursor Install](../cursor.md).

## Install

From the Cursor agent CLI:

```bash
agent plugin marketplace add https://github.com/yandy-r/ystack
```

or, in the Cursor IDE, open `/plugins` and use Marketplace. Either route lists
`ycc`, `ycc-mcp`, `ycc-hooks`, and `ycc-rules`; pick the packages in `/plugins`
(the CLI has no non-interactive `plugin install`: `marketplace add` prints
`Tip: use /plugins in interactive mode`).

| Package     | Native ID       | Payload                                                                            | Notes                                                             |
| ----------- | --------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| `ycc`       | `ycc@ycc`       | `skills/`, `agents/`, `commands/` (thin files per user-invocable skill), `shared`  | Generated under `packages/cursor/ycc/`                            |
| `ycc-rules` | `ycc-rules@ycc` | Manifest + `rules/` from the existing Cursor rules transform (Cursor-only package) | Generated under `packages/cursor/ycc-rules/`                      |
| `ycc-mcp`   | `ycc-mcp@ycc`   | Manifest + literal `mcp.json`; `${VAR}` placeholders declared under `variables`    | Generated under `packages/cursor/ycc-mcp/`; no secret literals    |
| `ycc-hooks` | `ycc-hooks@ycc` | `hooks/hooks.json` + `herdr-session-start.sh`; `sessionStart` only                 | Generated under `packages/cursor/ycc-hooks/`; no `WorktreeCreate` |

Every generated manifest carries `minClientVersions.cursor: 3.24.12`. That is
the **tested floor** from the spike (Cursor IDE 3.24.12, agent CLI
2026.10.14-941492e); no older minimum is established or claimed.

`ycc-hooks@ycc` registers `sessionStart` only; there is no Cursor
`WorktreeCreate` hook in any package. See
[Hooks: sessionStart only](#hooks-sessionstart-only).

## Marketplace shape

The root `.cursor-plugin/marketplace.json` has one entry per package, each with
a relative `source` pointing at a generated package root under
`packages/cursor/`. The spike established:

- **Marketplace registration: Go** at user scope
  (`agent plugin marketplace add <github-url>`), without installing the Cursor
  GitHub App.
- **Pinning: Go** for the marketplace ref — `--git-ref <tag|sha>` stores the
  full commit SHA; a missing ref fails closed.
- **One entry per directory.** The server-side `update` collapses two entries
  pointing at the same relative directory, so the catalog never repeats a
  source.
- Relative `source` entries merge the directory's `.cursor-plugin/plugin.json`.

## Installing from a checkout

From a checkout, `install.sh` registers the same marketplace and prints the
`/plugins` step; it never copies package content into `~/.cursor/`:

```bash
./install.sh install --target cursor
./install.sh sync --target cursor --intent base,rules,mcp,hooks
./install.sh sync --target cursor --intent settings --global
```

`base` runs `agent plugin marketplace add https://github.com/yandy-r/ystack`
(skipped when already registered; local mode registers the same URL because
Cursor rejects filesystem marketplaces), prints the `/plugins` hint naming the
packages the requested intents need, and retires the proven installer-owned
copies v6.0–v6.2 wrote (see
[Automatic Legacy Cleanup](../README.md#automatic-legacy-cleanup)). The
`settings` step merges `packages/cursor/installer-fallback/config/cli-config.json`
into `~/.cursor/cli-config.json` only with `--global`. `install --package` maps
every package to `base` (the hint names it) plus `settings`. Neither route
activates a native account plugin or consults plugin caches as proof of
activation.

## Runtime evidence

What is proven (agent CLI 2026.10.14-941492e): the user-file carriers the
v6.0–v6.2 installer wrote were exercised in a fixture lab (isolated `HOME` and
`XDG_CONFIG_HOME`). A `~/.cursor/commands/<name>.md` wrapper referencing the
absolute installed `~/.cursor/skills/<name>/SKILL.md` returned the fixture's
exact marker; the canonical `~/.cursor/hooks/herdr-session-start.sh`,
registered in the user `~/.cursor/hooks.json`, sent `pane.report_agent_session`
with an `agent_session_id` equal to the runtime result's `session_id`; a
foreign `sessionStart` recorder fired and a foreign command file survived.
Separately, `agent --plugin-dir <dir>` loads a local plugin's `sessionStart`
hook in that one process without an account install, and the generated
`ycc-hooks` package loaded this way sent a session identity report to a
disposable socket. The v6.0.0 maintainer verification (tracked in YAN-1141)
additionally covered the interactive Cursor marketplace installation of the
four packages, through both the agent CLI and the Cursor IDE.

## Hooks: sessionStart only

Cursor `hooks.json` runs `sessionStart` (payload `hook_event_name:
"sessionStart"`). `WorktreeCreate` does not exist in the CLI bundle, and the
Claude-style `SessionStart` spelling is not a Cursor hook event — a hooks file
naming unknown events silenced the whole file in the spike. `ycc-hooks@ycc`
ships `sessionStart` only. `WorktreeCreate` is unavailable — not implemented
anywhere for Cursor. The settings-only `cli-config.json` registers no hooks.

## Duplicates and legacy cleanup

`~/.cursor/skills/<name>` file copies and plugin skills
(`~/.cursor/plugins/.../skills/<name>`) do **not** share a dedupe key — both
stay, and the runtime will not collapse them. The installer's `base` step
therefore retires the copies v6.0–v6.2 wrote, in this order:

1. recorded installer-owned command wrappers in `~/.cursor/commands/`, the
   `sessionStart` registration in `~/.cursor/hooks.json`, and its script,
   through their ownership-checked removers (every decision is preflighted
   first; an edited, unproven, malformed, or symlinked carrier stops the
   Cursor cleanup before skills, agents, or rules change, so no active wrapper
   ever references a deleted skill);
2. entries under `~/.cursor/{skills,agents,rules}` only when byte-identical to
   the canonical packaged source or the staged installer projection, or when
   they are exactly owned symlinks (the projection covers installer-specific
   skill paths, `init`, and `_shared` helpers; shared helpers stay while any
   skills remain);
3. the managed servers recorded as ycc-written in `~/.cursor/mcp.json`, and
   `~/.cursor/CLAUDE.md` / `AGENTS.md` links to this checkout.

Recorded names alone never authorize deletion. Edited, differing, or unknown
entries and foreign links stay and are reported. Project
`<project>/.cursor/mcp.json` files are not touched. The cleanup preserves user
data, is safe to repeat, and does **not** install the Cursor plugins or verify
a native installed plugin at runtime: select the packages in `/plugins` as
described under [Install](#install).

## Secrets

`ycc-mcp@ycc` declares `${VAR}` placeholders under manifest `variables`; the
generator rejects credential-shaped literals. No secret values appear in any
package or this document.

## Evidence

- `docs/internal/spikes/cursor-plugin.md` (YAN-1124: IDE 3.24.12, agent 2026.10.14-941492e)
- `docs/internal/cursor-native-packages.md` (YAN-1132 generator + gates)
- `docs/internal/adr/0001-package-model-and-versioning.md` (package matrix)
- `scripts/lib/install/targets/cursor.sh` (intent mapping; marketplace registration and `/plugins` hint)
- `scripts/install_migrate.py` (`Migration.cursor`, `retire_cursor_carriers`: the proven legacy cleanup)
- `packages/cursor/installer-fallback/config/cli-config.json` (settings only; no registered hooks)
