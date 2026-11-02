# Cursor Install Guide (v6 native packages)

Cursor installs `ycc` as four native plugins from the `ycc` marketplace in this
repository (`yandy-r/ystack`, root `.cursor-plugin/marketplace.json`). The
file-copy `install.sh` route in [Cursor Install](../cursor.md) remains
available as the fallback and for the pieces plugins do not carry.

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
`WorktreeCreate` hook in the plugin or the file-copy route. See
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

## Installing from a checkout (file copy)

From a checkout, `install.sh` delivers the same content as files and config:

```bash
./install.sh install --target cursor
./install.sh sync --target cursor --intent commands,rules,mcp
./install.sh sync --target cursor --intent settings --global
```

This generates and rsyncs `packages/cursor/ycc/{skills,agents}` and
`packages/cursor/ycc-rules/rules` into `~/.cursor/`. The `settings` step merges
`packages/cursor/installer-fallback/config/cli-config.json` into
`~/.cursor/cli-config.json` only with `--global`; without that flag it is
skipped and writes nothing. MCP servers merge into
`<project>/.cursor/mcp.json` (or `~/.cursor/mcp.json` with `--global`). User
commands install into `~/.cursor/commands/` as an explicit `commands` step or
package selection, and the optional `sessionStart` hook installs as an explicit
`hooks` step or `ycc-hooks` package selection (`ycc` selects
`base,commands,settings`; `ycc-hooks` selects `settings,hooks`; `ycc-mcp`
selects `settings,mcp`; `ycc-rules` selects `base` plus `settings`). `ycc` owns
the commands carrier; `ycc-hooks` owns the hooks carrier; the fallback hooks
component stays optional and is not inherited by other selections. Only
`plugins` is a no-op.

```bash
./install.sh install --target cursor --package ycc
./install.sh install --target cursor --package ycc-hooks
./install.sh sync --target cursor --intent hooks   # optional without package selection
```

See the [Cursor Install](../cursor.md) guide for individual steps and
ownership-aware command/hook removal. Neither route registers the marketplace,
activates a native account plugin, or consults plugin caches as proof of
activation.

## Runtime evidence

What is proven (agent CLI 2026.10.14-941492e): the user-file carriers were
exercised two ways. In a fixture lab (isolated `HOME` and `XDG_CONFIG_HOME`), a
`~/.cursor/commands/<name>.md` wrapper referencing the absolute installed
`~/.cursor/skills/<name>/SKILL.md` returned the fixture's exact marker; the
canonical `~/.cursor/hooks/herdr-session-start.sh`, registered in the user
`~/.cursor/hooks.json`, sent `pane.report_agent_session` with an
`agent_session_id` equal to the runtime result's `session_id`; a foreign
`sessionStart` recorder fired and a foreign command file survived. The opt-in
`scripts/cursor_live_smoke.py --keep` then re-proved the same behavior through
the real package installer routes (`--package ycc --skills-home native`,
`--package ycc-hooks`, `YCC_INSTALL_SKIP_BUILD=1`): the canonical `go-patterns`
wrapper expanded to the installed skill (heading `Go Development Patterns`),
own and foreign hooks both fired for the same session, `$ARGUMENTS` reached the
model, and no copied authentication is retained. Separately, `agent
--plugin-dir <dir>` loads a local plugin's `sessionStart` hook in that one
process without an account install, and the generated `ycc-hooks` package loaded
this way sent a session identity report to a disposable socket. The v6.0.0
maintainer verification (tracked in YAN-1141) additionally covered the interactive
Cursor marketplace installation of the four packages, through both the agent CLI
and the Cursor IDE.

## Hooks: sessionStart only

Cursor `hooks.json` runs `sessionStart` (payload `hook_event_name:
"sessionStart"`). `WorktreeCreate` does not exist in the CLI bundle, and the
Claude-style `SessionStart` spelling is not a Cursor hook event — a hooks file
naming unknown events silenced the whole file in the spike. `ycc-hooks@ycc` ships `sessionStart` only. `WorktreeCreate` is
unavailable — not implemented anywhere for Cursor: not in the native package
and not in the file-copy carrier. The optional fallback hooks component is
delivered only when explicitly selected; the settings-only `cli-config.json`
registers no hooks.

## Duplicates and migration

`~/.cursor/skills/<name>` file copies and plugin skills
(`~/.cursor/plugins/.../skills/<name>`) do **not** share a dedupe key — both
stay, and the runtime will not collapse them. Migration handles confirmed
installer copies explicitly:

```bash
./install.sh migrate --target cursor           # dry-run
./install.sh migrate --target cursor --apply
```

Dry-run writes no config, state, build output, or CLI state. Apply first
retires recorded installer-owned command wrappers and the `sessionStart` hook
carrier through their ownership-checked removers, then removes
entries under `~/.cursor/{skills,agents,rules}` only when byte-identical to
the canonical packaged source or staged installer projection, or when they
are exactly owned symlinks. The projection covers installer-specific skill
paths, `init`, and `_shared` helpers as actually installed; shared helpers
stay while any skills remain. Recorded names alone never authorize deletion.
Edited, differing, or unknown entries and foreign links stay and are
reported, even if earlier ownership state names them. Symlinked carrier config
files stop cleanup rather than being replaced. Migration preserves
user data, is safe to repeat, and rejects `--force`.

Migration prints the interactive `/add-plugin` step (`Cursor: open
/add-plugin and add the ycc marketplace, then select the native packages.`); it
does **not** install the Cursor plugins or verify a native installed plugin at
runtime. Add the marketplace and select the packages as described under
[Install](#install).

**WARNING — name-based deletion hazard in the live installer.** The bundle branch of `install.sh remove --target cursor` (`--intent base` or `--only base`) deletes by name: `remove_mirrored_entries` (`scripts/lib/install/bundle.sh`) removes every same-named entry from `~/.cursor/{skills,agents,rules}` for each top-level entry the generated bundle ships, regardless of ownership. Your own same-named skill, agent, or rule entry would be destroyed. Do NOT treat it as a safe migration step.

**How live `remove` behaves by intent (so the hazard is understood):**

- `./install.sh remove --target cursor --intent skills,agents` removes slice entries with an ownership check (entries the installer cannot recognize as its own are kept) but never touches `~/.cursor/rules/`.
- `./install.sh remove --target cursor --intent commands,hooks` removes only entries the installer recognizes as its own; unrelated user entries stay. Do not use the name-based bundle/base remove for migration.
- `./install.sh remove --target cursor --intent rules` only unlinks legacy `~/.cursor/{CLAUDE.md,AGENTS.md}` symlinks that point into this repo — never `~/.cursor/rules/`.
- Only the name-based `base` branch above touches the `~/.cursor/rules/` bundle generated by the base install.

**Migrating an existing file-copy install:** Preview with `migrate --target cursor`
and review every retained conflict. Back up `~/.cursor/{skills,agents,rules,commands,hooks}`
and `~/.cursor/hooks.json` before applying. Migration preflights both carriers,
then retracts proven installer-owned command wrappers, the `sessionStart`
registration, and its script before cleaning up file-copy skills. An edited,
unproven, malformed, or symlinked carrier that cannot be safely retracted stops
Cursor cleanup before skills, agents, or rules are removed. This avoids active
wrappers referencing deleted skills and duplicate installer/native hooks.

Resolve reported carrier conflicts manually after backing them up; preserve user
entries. Run `./install.sh remove --target cursor --intent commands,hooks` and
preview migration again before applying or activating native packages. Do not
substitute the name-based `remove --intent base` path. Once the preview is safe,
use `migrate --target cursor --apply` for the confirmed-copy cleanup, then follow
`/add-plugin` interactively to install the native packages.

## Secrets

`ycc-mcp@ycc` declares `${VAR}` placeholders under manifest `variables`; the
generator rejects credential-shaped literals. No secret values appear in any
package or this document.

## Evidence

- `docs/internal/spikes/cursor-plugin.md` (YAN-1124: IDE 3.24.12, agent 2026.10.14-941492e)
- `docs/internal/cursor-native-packages.md` (YAN-1132 generator + gates)
- `docs/internal/adr/0001-package-model-and-versioning.md` (package matrix)
- `scripts/lib/install/targets/cursor.sh` (intent mapping; `rules` removal unlinks legacy instruction symlinks, while only `base` removes generated rules)
- `scripts/lib/install/bundle.sh` (`remove_mirrored_entries`: name-based deletion without ownership checks)
- `scripts/install_slices.py` (standalone slice ownership/content checks)
- `packages/cursor/installer-fallback/config/cli-config.json` (settings only; no registered hooks)
- `scripts/cursor_live_smoke.py` (opt-in live user-carrier smoke; requires an authenticated `cursor-agent`, not part of CI)
