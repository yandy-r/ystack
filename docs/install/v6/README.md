# ycc Native Package Reference

Starting with v6.0.0, `ycc` ships as native packages in the Claude, Codex, and
Cursor marketplaces; v6.1.0 adds the OMP (oh-my-pi) catalog. These pages are
the **package reference**: package IDs, payloads, catalog shape, tested
versions, and evidence. Install instructions live in one place, the
[install guides](../README.md); each runtime page there is the canonical
how-to. The repository is `yandy-r/ystack` (renamed from `claude-plugins`, then
`agentic-code-plugins`; old GitHub names redirect).

Since v6.3.0, `install.sh` installs the native packages itself on Claude, Codex,
Cursor, OMP and opencode (through each runtime's plugin CLI, or opencode's
`plugins` entry), and retires older installer copies automatically (see
[Automatic Legacy Cleanup](../README.md#automatic-legacy-cleanup)).

| Runtime  | Package reference          | Install guide                      | Native install                                                |
| -------- | -------------------------- | ---------------------------------- | ------------------------------------------------------------- |
| Claude   | [claude.md](claude.md)     | [`../claude.md`](../claude.md)     | `claude plugin install ycc-all@ycc` (or the parts)            |
| Codex    | [codex.md](codex.md)       | [`../codex.md`](../codex.md)       | `codex plugin add ycc@ycc` and `codex plugin add ycc-mcp@ycc` |
| Cursor   | [cursor.md](cursor.md)     | [`../cursor.md`](../cursor.md)     | `agent plugin marketplace add`, then `/plugins`               |
| OMP      | [`../omp.md`](../omp.md)   | [`../omp.md`](../omp.md)           | `omp plugin install ycc@ycc ycc-mcp@ycc ycc-rules@ycc`        |
| opencode | [opencode.md](opencode.md) | [`../opencode.md`](../opencode.md) | `"plugins": ["@yandy-r/ycc-opencode@X.Y.Z"]` in opencode.json |
| agents   | [agents.md](agents.md)     | [`../agents.md`](../agents.md)     | none — file copy only                                         |

## Packages by runtime

The package truth is `ycc/settings/packages.json`; the summary below matches
that model. Native package IDs are `<package>@ycc`. `ycc-rules@ycc` is listed
for Cursor and OMP. `installer-fallback` is an internal modeling key for
installer-only artifacts — it is not an installable package ID.

| Runtime  | Native packages (listed)                                                                                                                  | Delivered by `install.sh`                                                                                                                                                                 | Not installable                                                                                                                    |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Claude   | `ycc@ycc`, `ycc-mcp@ycc`, `ycc-hooks@ycc`, `ycc-all@ycc` (meta; depends on the other three)                                               | The native installs, plus rules (`CLAUDE.md`), settings, statusline and mods — no Claude `ycc-rules` exists                                                                               | Claude `ycc-agents` (agents-only package) deferred to v7.0.0; qualified references would be a breaking namespace change            |
| Codex    | `ycc@ycc` (skills + shared), `ycc-mcp@ycc`, both from the `ycc` catalog                                                                   | The native installs, plus custom agents in `~/.codex/agents`, `AGENTS.md` instructions and `config.toml` settings (Codex plugins cannot carry these)                                      | Codex `ycc-hooks` excluded: no-go until verified (YAN-1149); hooks stay out of the Codex bundle                                    |
| Cursor   | `ycc@ycc` (skills, agents, commands, shared), `ycc-rules@ycc`, `ycc-mcp@ycc`, `ycc-hooks@ycc` (`sessionStart` only)                       | Marketplace registration and the `/plugins` hint, plus `cli-config.json` settings (`--global` only); `WorktreeCreate` is not implemented for Cursor                                       | —                                                                                                                                  |
| opencode | `@yandy-r/ycc-opencode` (npm V2 plugin registering skills, agents, `/ycc:<skill>` commands, shared helpers, MCP, the guard, instructions) | The `plugins` entry (local: a `file://` checkout path; repo: the pinned release), plus `opencode.json` settings, `AGENTS.md` and the opt-in catalog                                       | —                                                                                                                                  |
| agents   | none — file copy only                                                                                                                     | `install.sh --target agents`: skills + `ycc-shared` into `~/.agents/`                                                                                                                     | The `npx skills` path cannot replace the file copy (spike: shared helpers not delivered; bare-repo discovery finds the wrong tree) |
| OMP      | `ycc@ycc` (skills, agents, commands, shared), `ycc-mcp@ycc`, `ycc-rules@ycc`, from `.omp-plugin/marketplace.json` (`omp >= 18.12.2`)      | The native installs (`--mode local` exports this checkout; `--mode repo` registers the GitHub catalog), plus opt-in `--settings --global` (user `config.yml`) and `--rules` (`AGENTS.md`) | `ycc-hooks` and `ycc-all` excluded: herdr ships OMP reporting, and OMP does not read plugin dependencies                           |

### Duplicates

Runtimes do not dedupe a native plugin against a file copy of the same
content. That is why `install.sh` retires the older Claude, Codex, Cursor, OMP
and opencode installer copies once the native package is in place, removing
only entries it can prove it wrote. On opencode a same-ID file copy would even
override the package's definition, so the cleanup runs right after the
`plugins` entry lands. See [opencode.md](opencode.md#legacy-cleanup).

## `install.sh --package`

`install.sh install --package <ids> --target <targets>` installs package
closures from the package model through the target's native route and never
edits a catalog. Claude: `ycc` → `ycc@ycc`, `ycc-mcp` → `ycc-mcp@ycc`,
`ycc-hooks` → `ycc-hooks@ycc`, `ycc-all` → all three (user scope). Codex: `ycc`
→ `ycc@ycc` + `ycc-mcp@ycc`, `ycc-mcp` → `ycc-mcp@ycc`, plus the custom agents.
Cursor: every package → the marketplace registration and a `/plugins` hint
naming it. OMP: `ycc`, `ycc-mcp`, `ycc-rules` → one `omp plugin install` each.
opencode: `@yandy-r/ycc-opencode` → the `plugins` entry (`base`). Claude and
Codex also add their settings and rules fallback (Cursor: settings); OMP and
opencode settings and `AGENTS.md` stay opt-in through `--settings` and
`--rules`. See [Step Flags And Packages](../README.md#step-flags-and-packages).

## Evidence

Version claims below are data points from spike harnesses, not minimum
supported versions, except where explicitly established (Claude hooks need
Claude Code 2.1.300+; Cursor manifests declare the tested floor 3.24.12;
the generated opencode npm manifest declares `engines.opencode: >=2.0.30`).

- Package model: `docs/internal/adr/0001-package-model-and-versioning.md`
- Spikes: `docs/internal/spikes/{claude-namespace,claude-hooks,codex-marketplace,cursor-plugin,opencode-config-hook,npx-skills,codex-public-fork-install,omp-runtime-contract}.md`
- OMP decision and live evidence: `docs/internal/adr/0002-omp-runtime-contract.md`, `docs/internal/omp-acceptance.md`
- Native package layouts: `docs/internal/{claude-native-packages,cursor-native-packages}.md`
- opencode npm implementation: `scripts/generate_opencode_package.py`,
  `packages/opencode/ycc-opencode/{package.json,index.js,registration.json}`,
  `.github/workflows/release.yml`, and `scripts/opencode_npm_release.py`
