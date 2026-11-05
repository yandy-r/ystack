# Codex Package Reference (v6 native packages)

Codex installs `ycc` as two native plugins from the `ycc` marketplace in this
repository (`yandy-r/ystack`). This page is the package reference: IDs, catalog
shape, tested versions, evidence. Custom agents, `AGENTS.md`, and `config.toml`
settings come from `install.sh` because Codex plugins cannot carry them; the
install how-to is [Codex Install](../codex.md).

## Install

Codex 0.160 or later:

```bash
codex plugin marketplace add https://github.com/yandy-r/ystack.git
codex plugin add ycc@ycc
codex plugin add ycc-mcp@ycc
```

Add `--ref <sha>` to `marketplace add` to pin a commit. Restart Codex after
installing. The `ycc` catalog replaced the pre-v6 `local-ycc-plugins` catalog.

From a checkout, `./install.sh install --target codex` does the same thing
(`codex plugin marketplace add <checkout>`, then `codex plugin add ycc@ycc`
and `codex plugin add ycc-mcp@ycc`) and also syncs the custom agents into
`~/.codex/agents/`. `--mode repo` registers the Git marketplace
`https://github.com/yandy-r/ystack.git` at `main` instead of the checkout.
The Codex CLI 0.160 or later is required; the installer never writes plugin
snapshots itself. Rerun the base step to refresh the snapshots after
regenerating the bundle.

## v6 Native Package Model

`ycc/settings/packages.json` is the package truth (loaded through
`scripts/package_model.py`); the decision record is
[ADR 0001](../../internal/adr/0001-package-model-and-versioning.md). Codex
packages:

| ID            | Payload                                  | Status                                                                                                 |
| ------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `ycc@ycc`     | Skills + `shared/` (skills-only; no MCP) | Listed in the repo-root `.agents/plugins/marketplace.json` (local source `./.codex-plugin/ycc`).       |
| `ycc-mcp@ycc` | MCP-only (`mcpServers: ./.mcp.json`)     | Listed; native MCP uses Codex `env_vars`; installed on the pinned baselines below.                     |
| `ycc-hooks`   | Hooks (excluded)                         | **Excluded.** No-Go until hook trust and dispatch are verified (YAN-1149 gate); not an installable ID. |
| `ycc-agents`  | — (not a Codex package)                  | Claude-only and deferred to v7 anyway; not an installable ID.                                          |

The ID `ycc@local-ycc-plugins` is what pre-v6 `install.sh` wrote
(marketplace `local-ycc-plugins`, source `./.agents/plugins/ycc`). It is not a
separate package. A successful native install retires it automatically once
`ycc@ycc` and `ycc-mcp@ycc` are installed and enabled (see
[Legacy Cleanup](#legacy-cleanup)).

Each package keeps a distinct manifest `name`; payloads live under
`.codex-plugin/ycc` and `.codex-plugin/ycc-mcp`.

## Config Shape

After installation `~/.codex/config.toml` enables both packages (a checkout
install via `install.sh` also records `[marketplaces.ycc]` with
`source_type = "local"` and the checkout path):

```toml
[plugins."ycc@ycc"]
enabled = true

[plugins."ycc-mcp@ycc"]
enabled = true
```

A pre-v6 `install.sh` install holds the legacy entry instead:

```toml
[plugins."ycc@local-ycc-plugins"]
enabled = true
```

The **repository-root** `.agents/plugins/marketplace.json` describes the native
Git marketplace named `ycc`. Its `local` sources resolve from the repository
root, where the `.codex-plugin/` payload lives:

```json
{
  "name": "ycc",
  "plugins": [
    { "name": "ycc", "source": { "source": "local", "path": "./.codex-plugin/ycc" } },
    { "name": "ycc-mcp", "source": { "source": "local", "path": "./.codex-plugin/ycc-mcp" } }
  ]
}
```

A Git marketplace catalog at `.agents/plugins/marketplace.json` wins over
`.claude-plugin/marketplace.json`, which is why the repo-level Codex catalog
lives under `.agents/plugins/`.

This is **not** a replacement snippet for the user-level
`~/.agents/plugins/marketplace.json` that pre-v6 installs used: there the
marketplace root is `$HOME`, so `./.codex-plugin/ycc` would resolve to
`~/.codex-plugin/ycc`, not this repository.

## Tested Baselines And Version Boundaries

- **codex-cli 0.160.0 and 0.163.0 (public profile, production repo):**
  anonymous public GitHub HTTPS registration of `yandy-r/ystack` at a pinned
  `main` SHA and independent installs of `ycc@ycc` and `ycc-mcp@ycc`, from
  both full and sparse checkouts, in both install orders (v6.0.0 payload).
- **codex-cli 0.160.0 (exact, public spike fixture):** the same matrix
  against a 5.3.0-payload fixture repository.
- **codex-cli 0.161.0:** the same package split installed from a local
  file-transport fixture; sparse-checkout and hook-discovery matrix verified.
- No claim is made about runtimes not listed above. Authenticated/private,
  SSH, and `owner/repo` shorthand transports are untested. MCP evidence is
  metadata only (`mcp list`); no server execution, login, session, or hook
  dispatch was exercised.

## Native Vs Installer

- **Native (plugin) layer:** skills + `shared/` in `ycc@ycc`; MCP server
  connections in `ycc-mcp@ycc` (with `env_vars`, e.g. Xero's
  `XERO_CLIENT_ID`/`XERO_CLIENT_SECRET`, never secret literals).
- **Installer-only layer:** custom agent TOMLs, `AGENTS.md`, and
  `config.toml` settings are delivered by `install.sh` — Codex plugins cannot
  carry them. `installer-fallback` in `packages.json` is an internal modeling
  key, never an installable ID.

Sparse installs from a Git marketplace must include both
`.agents/plugins` (catalog) and `.codex-plugin/ycc` (payload) in
`--sparse` selections — catalog-only sparse checkouts fail `plugin add`
with `missing plugin.json`. Add `.codex-plugin/ycc-mcp` to install the MCP
package from a sparse checkout.

## Legacy Cleanup

Releases before v6.3.0 could leave the `ycc@local-ycc-plugins` install, its
`~/.codex/plugins/ycc` and `~/.agents/plugins/ycc` links, a snapshot under
`~/.codex/plugins/cache/local-ycc-plugins/ycc`, a `~/.agents/plugins/marketplace.json`
entry, standalone `~/.codex/skills` copies, and merged `[mcp_servers.*]` tables.
A successful `install.sh` base or mcp step retires them automatically, and so
does `remove --target codex --intent base`; see
[Automatic Legacy Cleanup](../README.md#automatic-legacy-cleanup).

The cleanup runs after `codex_install.py` has installed the native packages,
and it never installs or calls the Codex CLI itself. It is gated on this
checkout's catalog: if it is not an eligible native `ycc` catalog (name `ycc`,
both packages listed, payloads present and unmodified), the cleanup stops with
`Codex native gate failed: <reason>` and leaves the legacy files intact. The
native packages stay installed, and the installer warns
`legacy cleanup skipped` instead of failing the run. It never repurposes
`local-ycc-plugins`.

Each legacy carrier is retired only once its native replacement is proven:
the package is enabled in `~/.codex/config.toml` (`[plugins."<pkg>@ycc"]
enabled = true`) and Codex has written its snapshot under
`~/.codex/plugins/cache/ycc/<pkg>/`. With `ycc-mcp@ycc` in place, the merged
`[mcp_servers.*]` tables go. With `ycc@ycc` in place, the
`ycc@local-ycc-plugins` enablement, the links, recognized catalog entries and
the legacy cache go. So an mcp-only install retires only the MCP tables. On
`remove --intent base` the native packages are going too, so that proof is
skipped; the ownership checks below still apply. Standalone
`~/.codex/skills/` entries are retired when they exactly match the installer
output; shared helpers stay while any skills remain. A legacy cache snapshot
under `~/.codex/plugins/cache/local-ycc-plugins/ycc` is retired when it is
byte-identical to `.codex-plugin/ycc` or to the legacy combined bundle
rendered from the current source, or when its git tree equals a committed
`.codex-plugin/ycc` tree in this checkout's history. An edited snapshot stays.
A shallow clone that does not contain that commit keeps the snapshot and
prints `git fetch --unshallow`. If git history cannot be read, the snapshot
stays. All `~/.codex/agents/` content is preserved, along with user edits,
unrelated settings, and foreign entries. Uncertain ownership is reported and
retained. Symlinked configuration files are retained with a notice. Repeating
it is safe.

Installed/enabled metadata is not runtime session or MCP execution proof.
`install.sh install --package <ids> --target codex` accepts `ycc` and
`ycc-mcp` (`ycc-hooks` is rejected on Codex): `ycc` installs the same
`ycc@ycc` and `ycc-mcp@ycc` pair as above, and the custom agents are synced
in local mode.

## Hooks Excluded

The `ycc-hooks` package is **excluded** from Codex. On codex-cli 0.161.0,
`WorktreeCreate` is absent from Codex's `HookEventName` schema, and plugin
`SessionStart` hooks were observed only as `trustStatus: "untrusted"` with
the `plugin_hooks` feature flag removed and no trust grant or runtime
dispatch exercised. Hooks stay out of the Codex bundle until verified
(YAN-1149 gate).

## Duplicates

- **Plugin + legacy copies.** A stale `ycc@local-ycc-plugins` enablement or
  `~/.codex/skills` copies left beside `ycc@ycc` would double-list every ycc
  skill; the legacy cleanup retires the proven ones.
- **`agents` target.** Codex also reads `~/.agents/skills`, so installing the
  `agents` target alongside the plugin lists the ycc skills twice. Codex skills
  come from `ycc@ycc` only; drop the `agents` target if you use only Codex.
- **Custom agents.** The agents slice is ownership-tracked: it replaces an
  existing `~/.codex/agents/<name>.toml` only if the name is recorded in
  `~/.config/ycc/installed-units.json` or the file is byte-identical, unless
  `--force` is passed. `install.sh remove --target codex --only base` removes
  only the custom agents ycc recorded; your own agents and edited copies stay.

## Evidence Index

- [ADR 0001: package model and versioning](../../internal/adr/0001-package-model-and-versioning.md)
- [Codex marketplace spike (YAN-1123)](../../internal/spikes/codex-marketplace.md)
- [Codex public fork install spike (YAN-1163)](../../internal/spikes/codex-public-fork-install.md)
- Package truth: `ycc/settings/packages.json` (`scripts/package_model.py`)
- Install guide: [Codex Install](../codex.md); package index: [v6 README](README.md)
