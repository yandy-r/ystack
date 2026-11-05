# opencode Package Reference

`@yandy-r/ycc-opencode` is how ycc installs into opencode. It is one
OpenCode V2 npm plugin, generated under `packages/opencode/ycc-opencode` and
released lockstep with the product version. `install.sh install --target
opencode` writes its `plugins` entry; the install how-to is
[opencode Install](../opencode.md). This page records the package contract,
the publication workflow and the evidence behind them.

## Install routes

| Route                                                                    | `plugins` entry                                                               |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| `./install.sh install --target opencode` (local)                         | `file:///<checkout>/packages/opencode/ycc-opencode` (rebuilt from the source) |
| `./install.sh install --target opencode --mode repo`                     | `@yandy-r/ycc-opencode@<version>`, the checkout's product version             |
| `./install.sh install --target opencode --package @yandy-r/ycc-opencode` | Same as local mode; plans only the `base` step                                |
| By hand                                                                  | `@yandy-r/ycc-opencode@X.Y.Z` in your own `opencode.json`                     |

The installer writes the entry into `~/.config/opencode/opencode.json` and
replaces any older ycc-opencode item in place (another version, `@latest`, the
bare name, an `npm:` alias, another `file://` checkout), keeping an object
item's `options`. It records the hash of the item it wrote, so `remove --intent
base` takes back only that item or the exact entry this checkout would write.

Pin an exact version when you add the entry by hand. Right after a release the
npm registry can briefly serve stale `latest` metadata, and the package's early
`0.0.0-*` placeholder versions are not loadable plugins; opencode resolving the
bare name in that window fails with `Plugin entrypoint not found`.

## What stays on the installer

The package carries skills, agents, commands, shared helpers, MCP servers, the
sensitive-file guard and instructions. `install.sh` still delivers the rest,
which the package model lists as the opencode `installer-fallback` row
(`settings`, `instructions`):

- **Settings** (`--settings`, or `--intent settings`): managed keys from
  `.opencode-plugin/opencode.json` (`$schema`, `model`, `agents` model pins,
  `providers`, `experimental.subagent_depth`, and the goal plugin in `plugins`)
  merged into `<project>/opencode.json` by default or
  `~/.config/opencode/opencode.json` with `--global`. Bundle `plugins` items are
  global-only. Provider and variant settings are user configuration, never
  package content.
- **Rules** (`--rules`): a symlink from `~/.config/opencode/AGENTS.md` to
  `.opencode-plugin/AGENTS.md`. The package's context hook skips the same text
  when the request already carries it, so the rules never load twice.
- **Third-party catalog** (`--plugins <name>`): the opt-in pinned plugins in
  `ycc/settings/opencode-plugins.json`, such as `oh-my-opencode-slim`. See
  [Third-party plugins](../opencode.md#third-party-plugins).

`install --package @yandy-r/ycc-opencode` never implies settings or rules; add
`--settings` and `--rules` explicitly.

## Package contract

`scripts/generate-opencode-package.sh` generates the package from the included
npm row in `ycc/settings/packages.json`. `scripts/sync.sh --only opencode`
regenerates it, and the `opencode` validator group in `scripts/validate.sh`
runs the generator in `--check` mode to catch committed drift.

- **V2 plugin.** The default export is `{ id: "yandy-r.ycc-opencode", setup }`.
  `setup()` registers skills, agents (with model pins from
  `ycc/settings/models.json`), one `/ycc:<skill>` command per public skill, the
  MCP servers from `mcp-configs/mcp.json`, the sensitive-file guard, and a
  permission floor for the restricted specialists. It delivers `AGENTS.md`
  through `session.hook("context", ...)`.
- **Relocatable.** Every asset lives inside the package. At setup the skill
  Markdown, scripts and shared helpers render into a temporary tree whose
  absolute root replaces `{{package-root}}`, so shell snippets run from any
  working directory.
- **Namespaced commands.** Commands are always `ycc:<skill>`, so they never
  shadow a host built-in such as `/init` or your own bare `/<skill>` commands.
  Skills and agents keep their source IDs.
- **Engine floor: opencode `>=2.0.30`.** The registration spike used v2.0.29;
  the package smoke targets v2.0.30. These are distinct evidence points, not a
  claim that every later version has been tested.

### Coexistence with local config

OpenCode applies config skills, agents and commands (`~/.config/opencode`, a
project's `.opencode/`) after user plugins. A same-ID file therefore replaces
the package definition (agents field-blend over it), and a config MCP server
with the same name wins. That is why `install.sh` retires the file copies older
releases wrote (see below). A copy you edited stays and keeps shadowing the
package until you remove it.

## Legacy cleanup

Before YAN-1973, `install.sh --target opencode` copied
`.opencode-plugin/{skills,agents,commands,shared,ycc-sensitive-guard}` into
`~/.config/opencode/`, merged `mcp.servers` into `opencode.json`, and merged a
`./ycc-sensitive-guard` `plugins` item. The `base` step now retires that state
automatically, after it writes the package entry (and only once
`opencode.json` loads the package), and `remove --intent base` runs the same
cleanup:

- A unit entry goes only when it is byte-identical to the current
  `.opencode-plugin/` copy or to any version committed in this checkout's
  history. Edited and foreign entries are kept and reported.
- `shared/` stays while a retained skill may need it; the guard directory stays
  while `opencode.json` still loads `./ycc-sensitive-guard`.
- The `mcp.servers` entries and the `./ycc-sensitive-guard` item go only with
  merge-state ownership proof, and only when unedited.
- Symlinked config or unit directories are skipped. A refusal warns and never
  fails the run.

See [Legacy Cleanup](../opencode.md#legacy-cleanup) for the full table.

## Publication

`.github/workflows/release.yml` publishes the package. It runs only on
product-tag pushes, never branches, PRs, or manual runs.

- Its guard (`scripts/opencode_npm_release.py`) requires an exact `vX.Y.Z` tag,
  matching tag, checkout and event commits, ancestry on freshly fetched
  `origin/main`, and canonical, generated and lockstep version agreement.
- It validates and packs the package, then publishes the packed artifact with
  provenance and public access through npm trusted publishing (OIDC, no token),
  in the `release` environment.
- It then waits until npm serves the new version as `latest`, so a green job
  means the registry resolves the release.

The workflow existing is not evidence that a given version is on npm. Before
using `--mode repo` or a hand-written pin, confirm the version exists with
`npm view @yandy-r/ycc-opencode@<version> version`. Until it does, use the
default local mode.

## What the spike proved (opencode v2.0.29)

- **Go:** a V2 `{ id, setup }` plugin registered agents, commands, skills
  (inline content + `path` into a fixture directory), and MCP through the V2
  registration APIs; the context hook's pushed system part reached the outgoing
  model request.
- **No-Go:** V1-style `config(cfg)` plugins fail to load (`Plugin must export a
default definition with an id and an effect or setup function.`). The config
  `instructions` array is parsed but **not resolved** on v2.0.29: a local-file
  entry never reached the model; discovered `AGENTS.md` files did (positive
  control). That is why the installer links `~/.config/opencode/AGENTS.md` and
  the package uses the context hook. Superseded on v2.1.1: config
  `instructions` entries now resolve (YAN-1241). The bundle still omits the
  key; see [opencode install](../opencode.md#installed-surfaces).
- Skills from config (`skills: ["<dir>"]`, HTTP catalog) listed fine; plugin
  skill bodies arrive as user-role `<skill_content>` blocks with the skill's
  base directory advertised. The package renders its `{{package-root}}` tokens
  to an absolute temporary asset-tree root at setup, so shell snippets can reach
  shared helpers from any working directory.

## Evidence

- `docs/internal/spikes/opencode-config-hook.md` (YAN-1125, opencode v2.0.29)
- `docs/internal/adr/0001-package-model-and-versioning.md` (package matrix)
- `ycc/settings/packages.json` (`@yandy-r/ycc-opencode`: included, npm, not
  opt-in, not experimental; `installer-fallback` opencode: settings,
  instructions)
- `scripts/generate_opencode_package.py` (generator, engine floor, package paths)
- `scripts/opencode_package.py` (the `plugins` entry: local and repo specs,
  in-place replacement, ownership)
- `scripts/install_migrate.py` (`Migration.opencode`, the legacy cleanup)
- `packages/opencode/ycc-opencode/{package.json,index.js,registration.json,README.md}`
  (generated version, V2 registrations, command namespace, coexistence behavior)
- `.github/workflows/release.yml` and `scripts/opencode_npm_release.py`
  (publication workflow and release guards, not registry evidence)
