# opencode v6 Install Guide

The experimental, opt-in npm package `@yandy-r/ycc-opencode` is generated under
`packages/opencode/ycc-opencode`, and its tag-triggered publishing workflow is
implemented. A generated package and a workflow are not proof of npm
publication; registry availability is not established here. The package is
opt-in and **never the default install**: unlike Claude, Codex, and Cursor,
opencode has no native-package listing in v6, and the `install.sh` file copy
stays the primary path. `install.sh migrate` rejects the `opencode` target and
`install.sh --package` does not accept the npm package.

## Primary path (v6): file copy

```bash
./install.sh install --target opencode
./install.sh sync --target opencode --intent base,settings,mcp,plugins,rules
```

This rsyncs `.opencode-plugin/{skills,agents,commands}/` into
`~/.config/opencode/`, merges managed keys from `.opencode-plugin/opencode.json`
into `~/.config/opencode/opencode.json`, merges MCP servers (project scope by
default; `--global` for user config), and symlinks `.opencode-plugin/AGENTS.md`
to `~/.config/opencode/AGENTS.md`. The file copy is **primary and unchanged** in
v6; it is not a transitional route to be retired.

Current-state steps that keep working unchanged:

- The generated config is **V2-only** (`opencode.ai/v2/docs`). V1 shapes
  (`plugin` singular, `provider`/`agent` top-level, server names directly under
  `mcp`) are rejected by the repo validator.
- The goal plugin and the local sensitive-file guard are enabled through the
  live `plugins` array (this is current behavior, not the v6 npm package):

  ```json
  {
    "plugins": ["@prevalentware/opencode-goal-plugin", "./ycc-sensitive-guard"]
  }
  ```

  Install the goal plugin's TUI half with `opencode2 plugin add @prevalentware/opencode-goal-plugin`
  (idempotent; verify with `opencode2 plugin list`). `--settings` installs the
  server-side half and the guard. The guard is its own installed directory,
  `~/.config/opencode/ycc-sensitive-guard`, so `--skills-home agents` keeps it.
  It enforces a sensitive-file policy for restricted specialists, and the npm
  package ships and registers the same guard. See
  [Sensitive-file guard](../opencode.md#sensitive-file-guard).

## Experimental opt-in npm package (generated; publication separate)

`scripts/generate-opencode-package.sh` generates
`packages/opencode/ycc-opencode` from the included npm row in
`ycc/settings/packages.json`. The generated manifest version is lockstep with
`ycc/.claude-plugin/plugin.json` (6.0.0 at v6.0.0). Its
default-exported `{ id, setup }` V2 plugin registers skills, agents, MCP, and
one `/ycc:<skill>` command per public skill; shared helpers ship with the
skills. It delivers `AGENTS.md` instructions through
`session.hook("context", ...)`. Provider and variant settings remain user
configuration, not package content.

`scripts/sync.sh --only opencode` regenerates the package and the `opencode`
validator group in `scripts/validate.sh` runs the generator in `--check` mode
to catch committed drift.

Facts that bound every claim below:

- **Generated, with publishing implemented — not evidence of publication.**
  `.github/workflows/release.yml` runs only on product-tag pushes, never branches,
  PRs, or manual runs. Its guard requires an exact `vX.Y.Z` tag, matching tag,
  checkout and event commits, ancestry on freshly fetched `origin/main`, and
  canonical/generated/lockstep version agreement. It validates and packs the
  package, then publishes the packed artifact with provenance and public access.
  Maintainers must configure the `release` environment's publish-scoped
  `NPM_TOKEN`, approval, and restricted tag creation. That workflow does not
  establish that any tag has been pushed or that npm has a published version.
- **Opt-in and experimental** in the package model (`experimental: true`,
  `opt_in: true`); the file copy never falls back to it or vice versa.
- **Declared engine floor: opencode `>=2.0.30`.** The registration spike used
  v2.0.29; the package smoke targets v2.0.30. These are distinct evidence points,
  not a claim that every later version has been tested.

### Opt-in configuration (local checkout or after publication)

The V2 key is `plugins` (plural). A local checkout can use the generated package
directory — not its `index.js` file — with an absolute `file://` entry:

```json
{
  "plugins": ["file:///abs/path/to/ystack/packages/opencode/ycc-opencode"]
}
```

Only after confirming a version is published to npm, use the registry name in
your own `opencode.json`, pinned to that exact version (replace `X.Y.Z`):

```json
{
  "plugins": ["@yandy-r/ycc-opencode@X.Y.Z"]
}
```

Do not use the bare package name. Right after a release, the npm registry can
briefly serve stale `latest` metadata, and the package's early `0.0.0-*`
placeholder versions are not loadable plugins; opencode resolving the bare name
in that window fails with `Plugin entrypoint not found`. Wait for the release
workflow to go green, which confirms npm serves the new version as `latest`,
then bump the pin.

**Choose the npm route deliberately; do not assume file-copy dedupe.** Same-ID
file-copy skills override package skills, agents field-blend over package
agents, and config MCP servers win over package MCP servers. A stale file-copy
bundle can therefore mask package content. Package commands are namespaced
`/ycc:<skill>` and coexist with the bare file-copy `/<skill>` commands instead
of replacing them. The context hook skips instructions already present in the
request. For a package-only setup, remove only confirmed installer-owned
file-copy entries by hand; preserve user-owned definitions and configuration.
`install.sh --package` does not install the npm package; add it to your own
`opencode.json` as shown above.

**WARNING — name-based deletion hazard in the live installer.** Do NOT treat
`./install.sh remove --target opencode --intent base` (or `--only base`) as a
safe cleanup step: its bundle branch runs `remove_mirrored_entries`
(`scripts/lib/install/bundle.sh`), which deletes every same-named entry from
`~/.config/opencode/{skills,agents,commands,shared}` for each top-level entry
the bundle ships, regardless of ownership. Your own same-named skill, agent,
or command entry would be destroyed; it is name-based, not ownership-aware.

**Manual migration (the supported route):**

1. Inventory `~/.config/opencode/{skills,agents,commands,shared}` entries,
   checking each same-named entry's contents against the installed bundle
   (for example,
   `diff -r .opencode-plugin/skills/<name> ~/.config/opencode/skills/<name>`,
   plus the matching `agents/`, `commands/`, and `shared/` entries).
2. Back up `~/.config/opencode/{skills,agents,commands,shared}` (or at
   minimum the entries you are about to delete).
3. Remove only the entries you confirm are managed/generated copies; keep
   anything user-owned or user-edited. If you remove
   `~/.config/opencode/ycc-sensitive-guard`, remove its `./ycc-sensitive-guard`
   `plugins` entry too; the npm package registers the same guard.
4. Add the local-directory plugin entry above, or the registry name only after
   confirming publication. Keep any unrelated entries in your `plugins` array.

## What the spike proved (opencode v2.0.29)

- **Go:** a V2 `{ id, setup }` plugin registered agents, commands, skills
  (inline content + `path` into a fixture directory), and MCP through the V2
  registration APIs; the context hook's pushed system part reached the outgoing
  model request.
- **No-Go:** V1-style `config(cfg)` plugins fail to load (`Plugin must export a
default definition with an id and an effect or setup function.`). The config
  `instructions` array is parsed but **not resolved** on v2.0.29 — a local-file
  entry never reached the model; discovered `AGENTS.md` files did (positive
  control). That is why the file copy ships `~/.config/opencode/AGENTS.md` and
  the npm package uses the context hook instead.
  Superseded on v2.1.1: config `instructions` entries now resolve (YAN-1241).
  The bundle still omits the key; see [opencode install](../opencode.md).
- Skills from config (`skills: ["<dir>"]`, HTTP catalog) listed fine; plugin
  skill bodies arrive as user-role `<skill_content>` blocks with the skill's
  base directory advertised. The generated npm package additionally renders
  its `{{package-root}}` tokens to an absolute temporary asset-tree root at
  setup, so shell snippets can reach shared helpers from any working directory.

## Migration

`install.sh migrate` supports only `claude`, `codex`, and `cursor`; naming
`opencode` is rejected. Move to the npm package by hand with the manual
procedure above. For users staying on the file copy (the default and
recommended path), no migration is needed: re-running the sync commands above
keeps the bundle current.

## Evidence

- `docs/internal/spikes/opencode-config-hook.md` (YAN-1125, opencode v2.0.29)
- `docs/internal/adr/0001-package-model-and-versioning.md` (package matrix)
- `ycc/settings/packages.json` (`@yandy-r/ycc-opencode`: experimental, opt-in)
- `scripts/generate_opencode_package.py` (generator, engine floor, package paths)
- `packages/opencode/ycc-opencode/{package.json,index.js,registration.json,README.md}`
  (generated version, V2 registrations, command namespace, coexistence behavior)
- `.github/workflows/release.yml` and `scripts/opencode_npm_release.py`
  (implemented publication workflow and release guards, not registry evidence)
