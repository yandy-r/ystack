# ycc v6 Native Package Install Guides

Starting with v6.0.0, `ycc` ships as native packages in the Claude, Codex, and
Cursor marketplaces. v6.1.0 adds the OMP (oh-my-pi) catalog. These pages are
the per-runtime guides for installing those packages and for moving an existing
`install.sh` file-copy install onto them. The repository is `yandy-r/ystack` (renamed from `claude-plugins`, then
`agentic-code-plugins`; old GitHub names redirect). The `install.sh`
commands in [`docs/install/`](../README.md) keep working as the fallback and
remain the only route for pieces plugins cannot carry (rules, instructions,
settings, custom agents, statusline).

| Runtime  | Guide                      | Native install                                                |
| -------- | -------------------------- | ------------------------------------------------------------- |
| Claude   | [claude.md](claude.md)     | `claude plugin install ycc-all@ycc` (or the parts)            |
| Codex    | [codex.md](codex.md)       | `codex plugin add ycc@ycc` and `codex plugin add ycc-mcp@ycc` |
| Cursor   | [cursor.md](cursor.md)     | `agent plugin marketplace add`, then `/plugins`               |
| opencode | [opencode.md](opencode.md) | experimental, opt-in npm package; file copy stays primary     |
| agents   | [agents.md](agents.md)     | none — file copy only                                         |
| OMP      | [omp.md](../omp.md)        | `omp plugin install ycc@ycc ycc-mcp@ycc ycc-rules@ycc`        |

## Quick install

```bash
# Claude Code (hooks need Claude Code >= 2.1.300)
claude plugin marketplace add yandy-r/ystack
claude plugin install ycc-all@ycc          # ycc + ycc-mcp + ycc-hooks via dependencies

# Codex
codex plugin marketplace add https://github.com/yandy-r/ystack.git
codex plugin add ycc@ycc
codex plugin add ycc-mcp@ycc

# Cursor
agent plugin marketplace add https://github.com/yandy-r/ystack
# then pick the packages in /plugins (also available in the Cursor IDE's Marketplace)

# OMP (oh-my-pi >= 18.12.2)
omp plugin marketplace add https://github.com/yandy-r/ystack.git
omp plugin install ycc@ycc ycc-mcp@ycc ycc-rules@ycc
```

## Native vs fallback by runtime

The package truth is `ycc/settings/packages.json`; the summary below matches
that model. Native package IDs are `<package>@ycc`. `ycc-rules@ycc` is
listed for Cursor and OMP (see [`../omp.md`](../omp.md)). `installer-fallback` is an internal modeling key for
installer-only artifacts — it is not an installable package ID.

| Runtime  | Native packages (listed)                                                                                                                                      | Stays on `install.sh`                                                                                                                           | Not installable                                                                                                                    |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Claude   | `ycc@ycc`, `ycc-mcp@ycc`, `ycc-hooks@ycc`, `ycc-all@ycc` (meta; depends on the other three)                                                                   | Rules, `CLAUDE.md` instructions, settings, and statusline — no Claude `ycc-rules` exists                                                        | Claude `ycc-agents` (agents-only package) deferred to v7.0.0; qualified references would be a breaking namespace change            |
| Codex    | `ycc@ycc` (skills + shared), `ycc-mcp@ycc`, both from the `ycc` catalog (replaces the legacy `local-ycc-plugins` catalog)                                     | Custom agents in `~/.codex/agents`, `AGENTS.md` instructions, `config.toml` settings (Codex plugins cannot carry these)                         | Codex `ycc-hooks` excluded: no-go until verified (YAN-1149); hooks stay out of the Codex bundle                                    |
| Cursor   | `ycc@ycc` (skills, agents, commands, shared), `ycc-rules@ycc`, `ycc-mcp@ycc`, `ycc-hooks@ycc` (`sessionStart` only)                                           | Optional settings and MCP merges; `WorktreeCreate` is not implemented for Cursor (the fallback `cli-config.json` registers no hooks)            | —                                                                                                                                  |
| opencode | `@yandy-r/ycc-opencode` (generated npm V2 plugin registering skills, agents, namespaced commands, shared helpers, MCP, instructions; experimental and opt-in) | `install.sh --target opencode`: file copy of skills, agents, commands, shared, `opencode.json` settings, `AGENTS.md` instructions — **primary** | — (the npm package is opt-in; registry publication is separate from generation and the publish workflow)                           |
| agents   | none — file copy only                                                                                                                                         | `install.sh --target agents`: skills + `ycc-shared` into `~/.agents/`                                                                           | The `npx skills` path cannot replace the file copy (spike: shared helpers not delivered; bare-repo discovery finds the wrong tree) |
| OMP      | `ycc@ycc` (skills, agents, commands, shared), `ycc-mcp@ycc`, `ycc-rules@ycc`, from `.omp-plugin/marketplace.json` (`omp >= 18.12.2`)                          | Opt-in `--settings` and `--rules` (`AGENTS.md`). `--mode local` (default) exports this checkout; `--mode repo` registers the GitHub catalog     | `ycc-hooks` and `ycc-all` excluded: herdr ships OMP reporting, and OMP does not read plugin dependencies                           |

### Duplicates and what migration removes

A native plugin and an `install.sh` file copy of the same content do not
dedupe, so move over with `install.sh migrate` instead of keeping both:

- **Claude:** a native plugin and installer-merged settings hooks both run;
  settings + plugin copies do not dedupe. Migration prunes only proven
  installer-owned hook commands when `ycc-hooks@ycc` is explicitly enabled,
  preserving user commands in the same event. It does not infer enablement
  from `ycc-all@ycc`. Managed MCP removal similarly requires explicit
  `ycc-mcp@ycc` enablement; only global config files and owned links are in
  scope.
- **Codex:** the legacy catalog ID is `ycc@local-ycc-plugins` (marketplace
  `local-ycc-plugins`, source `./.agents/plugins/ycc`); the current catalog is
  `ycc`, listing `ycc@ycc` and `ycc-mcp@ycc`. Apply registers the `ycc`
  marketplace, installs both packages, verifies they are installed and
  enabled, and only then retires proven installer-owned legacy entries.
  An untouched snapshot under `~/.codex/plugins/cache/local-ycc-plugins/ycc`
  is retired when its git tree matches a committed `.codex-plugin/ycc` in
  this checkout, including an older release. An edited snapshot stays.
  Migration never removes anything under `~/.codex/agents/`. A staged catalog
  can be selected with `--marketplace-source <dir>` (Codex only), subject to
  the same catalog and payload checks.
- **Cursor:** file copies and plugin skills do not share a dedupe key.
  Migration removes only byte-identical canonical copies or exactly owned
  symlinks across installed skills, agents, rules, and shared helpers. Edited
  and foreign entries remain with conflict reports; recorded names alone
  never authorize deletion. It prints the interactive `/add-plugin` step,
  not an automatic install or a claim of runtime verification.
- **opencode:** no migration is supported; the file copy stays primary. The
  generated npm alternative is opt-in; same-ID file-copy definitions can
  override package content, while namespaced package commands coexist with
  bare file-copy commands. See [opencode.md](opencode.md) before opting in.
- **agents:** no migration is supported; file copy only. See
  [agents.md](agents.md).

## Migration CLI

Preview first; `migrate` defaults to dry-run and writes no config, state,
build output, or CLI state. Only `--apply` makes changes:

```bash
./install.sh migrate --target claude
./install.sh migrate --target codex
./install.sh migrate --target cursor
./install.sh migrate --target claude --apply
./install.sh migrate --target codex --apply
./install.sh migrate --target cursor --apply
```

`--target all` resolves to exactly Claude, Codex, and Cursor; opencode and
agents are excluded from `all`, and naming either target explicitly is
rejected. OMP has its own `migrate --target omp` (see
[`../omp.md`](../omp.md#migrate-from-older-installs)); `all` prints a reminder
to run it separately. Migration preserves user edits/data and uncertain
entries, is safe to run repeatedly, and rejects `--force`. See each runtime
guide for details.
For Codex, apply checks installed/enabled CLI state before retiring legacy;
that metadata check is not runtime session, MCP execution, or hook-dispatch
verification.

## Installing from a checkout: `install.sh --package`

`install.sh install --package <ids> --target <targets>` expands the package
closure into existing installer steps. It is a file/config delivery route and
never edits a catalog. The one native piece is the `base` step it selects for
`ycc`: on Claude that registers the marketplace and installs `ycc@ycc`; on
Codex it registers the `ycc` marketplace and installs `ycc@ycc` plus
`ycc-mcp@ycc`; on OMP (see [`../omp.md`](../omp.md)) it exports
the OMP packages and installs `ycc@ycc` through `omp plugin`, and `ycc-mcp`
and `ycc-rules` install `ycc-mcp@ycc` and `ycc-rules@ycc` the same way.
Accepted ids are `ycc`, `ycc-mcp`, `ycc-hooks` (not Codex or OMP; on OMP
herdr ships its own integration), and `ycc-rules` (Cursor and OMP); OMP
accepts `ycc`, `ycc-mcp` and `ycc-rules`. OMP settings and `AGENTS.md` are
opt-in through `--settings` and `--rules`, not `--package`. `ycc-all` is not
accepted — install it through the Claude marketplace. `install --target all`
includes OMP when
`omp >= 18.12.2` is on `PATH`; otherwise it prints a skip line. See `./install.sh --help` for the full contract.

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
