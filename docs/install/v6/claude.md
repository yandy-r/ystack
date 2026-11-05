# Claude Package Reference (v6 native packages)

Claude Code installs `ycc` as native plugins from the `ycc` marketplace in this
repository (`yandy-r/ystack`). This page is the package reference: IDs, config
shape, tested versions, evidence. The install how-to, including the pieces
plugins cannot carry (rules, instructions, settings, statusline), is
[Claude Install](../claude.md).

## Install

```bash
claude plugin marketplace add yandy-r/ystack

# Everything: ycc + ycc-mcp + ycc-hooks through the ycc-all dependencies
claude plugin install ycc-all@ycc

# Or pick the parts
claude plugin install ycc@ycc
claude plugin install ycc-mcp@ycc
claude plugin install ycc-hooks@ycc
```

`ycc-hooks@ycc` needs Claude Code **2.1.300** or later. Run `/reload-plugins` or
start a new session after installing.

From a checkout, `install.sh` runs the same CLI: `base` installs `ycc@ycc`
(`claude plugin marketplace add <checkout> --scope user`, then
`claude plugin install ycc@ycc --scope user`), and the `mcp` and `hooks` steps
install `ycc-mcp@ycc` and `ycc-hooks@ycc` at project scope (default) or user
scope (`--global`). See [Claude Install](../claude.md).

## v6 Native Package Model

`ycc/settings/packages.json` is the package truth (loaded through
`scripts/package_model.py`); ADR 0001
([package model and versioning](../../internal/adr/0001-package-model-and-versioning.md))
is the decision record. Package IDs use the component name with `ycc` as the
marketplace:

| ID              | Package                          | Status                                                                                                   |
| --------------- | -------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `ycc@ycc`       | 49 skills, 55 agents, `_shared`  | Listed; skills and agents stay in `ycc` for all of v6.                                                   |
| `ycc-mcp@ycc`   | Native MCP-only plugin           | Listed.                                                                                                  |
| `ycc-hooks@ycc` | Native `hooks/hooks.json` plugin | Listed; requires Claude Code **2.1.300**.                                                                |
| `ycc-all@ycc`   | Meta plugin (no components)      | Listed; depends on `ycc`, `ycc-mcp`, and `ycc-hooks`.                                                    |
| `ycc-agents`    | Agents-only plugin               | **Deferred to v7.0.0** — qualified `ycc-agents:` references are a breaking namespace change (see below). |

Each package has its own distinct manifest `name`. No package reuses the `ycc`
manifest name: the namespace spike found that a shared name silently splits
runtime resolution between skills (first-installed wins) and agents
(last-installed wins).

Generated payloads live under `packages/claude/` (`ycc-mcp`, `ycc-hooks`,
`ycc-all`); see
[Claude native add-on packages](../../internal/claude-native-packages.md).

The `ycc-hooks` package relocates only the `WorktreeCreate` registration
committed in `ycc/settings/settings.json`. Its `hooks/hooks.json` does **not**
register `SessionStart` or activate herdr;
`scripts/generate_claude_packages.py` rejects other registered hook events.

## Config Shape

Claude Code writes the following to `~/.claude/settings.json` after the
installs above (you can also enable them there directly):

```json
{
  "enabledPlugins": {
    "ycc@ycc": true,
    "ycc-mcp@ycc": true,
    "ycc-hooks@ycc": true
  },
  "extraKnownMarketplaces": {
    "ycc": {
      "source": { "source": "github", "repo": "yandy-r/ystack", "ref": "main" },
      "autoUpdate": true
    }
  }
}
```

Installing only the meta plugin expands the same set through the manifest
dependency list:

```json
{ "enabledPlugins": { "ycc-all@ycc": true } }
```

The generated `ycc-all` manifest declares bare-name dependencies `ycc`,
`ycc-mcp`, `ycc-hooks` (no version ranges). Bare names resolve only inside one
relative-path marketplace, so every `ycc-all` dependency must stay in the same
`ycc` catalog.

## Tested Baselines And Version Boundaries

Spike test versions are data points, not claimed minimums:

- **Namespace / cross-plugin dispatch (YAN-1121):** Claude Code **2.1.143**
  (candidate floor) and **2.1.300** (latest at test time). Distinct manifest
  names with qualified `ycc-agents:` references: Go on both; shared manifest
  name: No-Go on both.
- **Plugin-hook fixtures (YAN-1122):** a recording `SessionStart` fixture
  fires from a plugin on both 2.1.143 and 2.1.300; the `WorktreeCreate`
  fixture fires **only on 2.1.300** (silently absent on 2.1.143). Hence the
  documented 2.1.300 minimum for `ycc-hooks@ycc`, which registers only
  `WorktreeCreate`. No version between the two pins was tested, and the
  fixture's `SessionStart` probe did not execute the real herdr script.
- **Dependency installation:** the native-package smoke harness installed
  `ycc-all` and observed automatic installation of `ycc`, `ycc-mcp`, and
  `ycc-hooks` on Claude Code **2.1.301**, from a local directory-source
  marketplace, with no Claude session or MCP execution. The v6.0.0 maintainer
  verification (tracked in YAN-1141) additionally covered a published install
  on a clean host: `claude plugin install ycc-all@ycc` installed the three
  packages. Dependency support on the 2.1.143 candidate baseline and any lower
  dependency-capable version are **not established**. On those clients, install `ycc@ycc` and
  `ycc-mcp@ycc` individually; `ycc-hooks@ycc` needs Claude Code 2.1.300 or
  later.

## Native Vs Installer

- **Native (plugin) layer:** skills, agents, `_shared`, MCP connections, and
  (at ≥2.1.300) hooks ship as marketplace plugins with the IDs above.
  `install.sh` installs them through the Claude CLI.
- **Installer-only layer:** Claude **rules**, `CLAUDE.md` instructions,
  settings, and the statusline have no plugin-manifest component and are
  delivered by `install.sh`. There is no Claude `ycc-rules` package;
  `installer-fallback` in `packages.json` is an internal modeling key, never
  an installable ID.

## Legacy Cleanup

Releases before v6.3.0 merged the `WorktreeCreate` hook into
`~/.claude/settings.json` (with a `~/.claude/hooks` link), merged MCP servers
into `~/.claude.json`, and copied standalone skills and agents into
`~/.claude/`. A successful `install.sh` native install retires that state
automatically; see
[Automatic Legacy Cleanup](../README.md#automatic-legacy-cleanup).

Hook cleanup requires `ycc-hooks@ycc` to be explicitly enabled in
`~/.claude/settings.json`, and MCP cleanup requires `ycc-mcp@ycc` to be
explicitly enabled there. `ycc-all@ycc` enablement alone is not evidence that
either dependency is installed and enabled. Without that enablement the
cleanup prints `Claude hooks retained: ycc-hooks@ycc is not explicitly enabled`
and `Claude MCP retained: ycc-mcp@ycc is not explicitly enabled`, and leaves
those entries alone.

The cleanup prunes only proven installer-owned hook commands (legacy
managed-state or source-hash proof), preserving user commands even within the
same event group; this uses command-level pruning in
`scripts/merge_managed_config.py`, not whole-event removal. Managed global MCP
entries are removed only with ownership proof; project MCP files are not
touched. The `~/.claude/hooks` link goes only while it points at this
checkout and no remaining hook command uses it. Symlinked configuration files
are retained with a notice. Repeating the cleanup is safe. It is not a Claude
session, MCP execution, or hook-dispatch check.

## Duplicates And Coexistence

- **Hooks double-run.** A plugin hook and a settings-registered hook for the
  same event **both execute** — the spike's recording fixtures verified 1 + 1
  counts for `SessionStart` on both pinned versions and for `WorktreeCreate`
  on 2.1.300, including when the two copies run the literal same script. The
  runtime does no dedupe, so a leftover installer settings hook beside
  `ycc-hooks@ycc` would duplicate `WorktreeCreate` runs; installing
  `ycc-hooks@ycc` at user scope through `install.sh` retires it. The
  `SessionStart` double-run result concerns spike fixtures only: the actual
  package has no `SessionStart` registration and does not produce duplicate
  herdr reports.
- **Plugin + file copy.** A native plugin and an older standalone copy in
  `~/.claude/skills` list every skill twice (`ycc:<name>` and `<name>`);
  there is no dedupe key between them. The `install.sh` base step retires the
  copies ycc recorded.

## Deferred: `ycc-agents` Split (v7)

Splitting agents out of `ycc` requires qualified `ycc-agents:<agent>`
references in dispatches and `skills:` frontmatter — a breaking namespace
change. The spike proved the mechanics work on both pinned versions, but v6
keeps agents inside `ycc`. Nothing in this guide installs or references the
deferred `ycc-agents` package as an installable ID.

## Evidence Index

- [ADR 0001: package model and versioning](../../internal/adr/0001-package-model-and-versioning.md)
- [Claude namespace spike (YAN-1121)](../../internal/spikes/claude-namespace.md)
- [Claude hooks spike (YAN-1122)](../../internal/spikes/claude-hooks.md)
- [Claude native add-on packages (YAN-1130)](../../internal/claude-native-packages.md)
- Package truth: `ycc/settings/packages.json` (`scripts/package_model.py`)
- Install guide: [Claude Install](../claude.md); package index: [v6 README](README.md)
