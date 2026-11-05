# ADR 0001: Package model, naming, and versioning

- **Status:** Accepted on authorized PR merge. The PR that adds this file is the
  owner's approval once merged; until then it is proposed.
- **Date:** 2026-10-15
- **Status update (2026-10-18):** the v6.0.0 listing flip has landed. Packages marked
  `listed: true` in `ycc/settings/packages.json` appear in the root Claude, Codex, and
  Cursor catalogs, and the maintainer release verification (YAN-1141) covered the Claude
  `ycc-all` dependency install, Codex clean installs, and interactive Cursor installation.
  The package matrix, Context, and Gates sections below are the original decision record
  and describe the pre-flip state in places; where they conflict with this note, this note
  and `RELEASING.md` win.
- **Target release:** v6.0.0
- **Tracking:** Linear YAN-1127; GitHub [#294](https://github.com/yandy-r/claude-plugins/issues/294)
- **Release gates and switches:** [RELEASING.md, Unfinished work](../../../RELEASING.md#unfinished-work)
- **Research inputs:** [recommendation](../../research/ystack/recommendation.md),
  [roadmap](../../research/ystack/roadmap.json)
- **Contribution rules:** [CONTRIBUTING.md](../../../CONTRIBUTING.md)

## Context

Today the repo ships one Claude marketplace entry, `ycc` at 5.3.0
([`.claude-plugin/marketplace.json`](../../../.claude-plugin/marketplace.json)), plus the
separately versioned `ycc-mods` marketplace. The Codex catalog
([`.agents/plugins/marketplace.json`](../../../.agents/plugins/marketplace.json)) still
uses the name `local-ycc-plugins` with path `./plugins/ycc`. Install is file copy through
`install.sh`. Users want per-component installs (for example, agents without the rest), and
each runtime differs in what it can package and depend on.

Five spikes tested the runtime questions on pinned versions. Each has a go/no-go verdict:

| Runtime  | Spike                                                     | Linear / GH                                                             | Tested versions                       | Verdict summary                                                                                                                  |
| -------- | --------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Claude   | [claude-namespace](../spikes/claude-namespace.md)         | YAN-1121                                                                | Claude Code 2.1.143, 2.1.300          | Shared manifest name **No-Go**; distinct names with qualified refs **Go**                                                        |
| Claude   | [claude-hooks](../spikes/claude-hooks.md)                 | YAN-1122 / [#288](https://github.com/yandy-r/claude-plugins/issues/288) | Claude Code 2.1.143, 2.1.300          | Plugin `WorktreeCreate` **Go on 2.1.300 only**; settings + plugin copies both run (no dedupe)                                    |
| Codex    | [codex-marketplace](../spikes/codex-marketplace.md)       | YAN-1123                                                                | codex-cli 0.161.0                     | `.agents` catalog wins; `local` sources need payload in sparse checkout; hooks **No-Go**                                         |
| Cursor   | [cursor-plugin](../spikes/cursor-plugin.md)               | YAN-1124 / [#292](https://github.com/yandy-r/claude-plugins/issues/292) | IDE 3.24.12, agent 2026.10.14-941492e | User-scope GitHub marketplace **Go**; `sessionStart` **Go**; `WorktreeCreate` **No-Go**; no non-interactive install              |
| opencode | [opencode-config-hook](../spikes/opencode-config-hook.md) | YAN-1125 / [#290](https://github.com/yandy-r/claude-plugins/issues/290) | opencode v2.0.29                      | V2 plugin registers agents, commands, skills, MCP, and a context hook **Go**; config `instructions` and V1 config hook **No-Go** |

The [npx skills spike](../spikes/npx-skills.md) found that `npx skills` installs one
selected skill directory and does not install `~/.agents/ycc-shared`. The cross-tool
`agents` target stays an `install.sh` file copy.

Test versions are data points, not minimum supported versions. The hook spike shows
2.1.143 failing and 2.1.300 passing. It does not establish any version between them, and
the Cursor and Codex spikes establish no minimum at all.

## Decision

### Names

| Item        | Decision                                                                                                                     | State                                                            |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Repository  | Renamed to `ystack` (from `claude-plugins`, briefly `agentic-code-plugins`). Old GitHub names redirect; never recreate them. | Done. GitHub and Forgejo renamed; references flipped on `main`.  |
| Marketplace | `ycc` for Claude, Codex, and Cursor. The Codex catalog renamed from `local-ycc-plugins` at the flip.                         | Current for Claude, Codex, and Cursor (Codex renamed in v6.0.0). |
| Namespace   | `ycc:` stays for skills and agents in v6.                                                                                    | Current.                                                         |
| Claude mods | `ycc-mods` unchanged (`status-bar@ycc-mods`).                                                                                | Current.                                                         |
| npm scope   | `@yandy-r/ycc-opencode` for the experimental opencode package.                                                               | `@yandy-r` owned; package not published.                         |
| "acc"       | Prose or branding only. Never an identifier.                                                                                 | Policy.                                                          |

Package ids use the component as the name and `ycc` as the marketplace: `ycc-mcp@ycc`,
`ycc-hooks@ycc`, `ycc-rules@ycc` (Cursor only), `ycc-all@ycc` (Claude meta), and
`ycc-agents@ycc` (Claude, v7). Each package keeps its own distinct manifest name. No
package reuses the `ycc` manifest name, because the namespace spike found that a shared
name silently splits resolution between skills and agents.

### Package matrix

"Spiked" means a dossier above tested the mechanism. "Unspiked" means the mechanism is
planned on documentation alone and must be tested before it is listed.

| Runtime  | Package / artifact                                                 | Mechanism                                                    | v6.0.0 status                                                                                                                                                                                                                                                | Evidence                                              |
| -------- | ------------------------------------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------- |
| Claude   | `ycc@ycc`                                                          | Native plugin: 49 skills, 55 agents, `_shared`               | Ships. Skills and agents stay in `ycc`.                                                                                                                                                                                                                      | claude-namespace (distinct names, qualified refs: Go) |
| Claude   | `ycc-mcp@ycc`                                                      | Native MCP-only plugin                                       | Planned in v6; unspiked.                                                                                                                                                                                                                                     | none                                                  |
| Claude   | `ycc-hooks@ycc`                                                    | Native plugin `hooks/hooks.json`                             | Ships, documented as needing Claude Code **2.1.300** or later. Native rollout waits for installer dedupe.                                                                                                                                                    | claude-hooks                                          |
| Claude   | `ycc-all@ycc`                                                      | Meta plugin with `dependencies`                              | Planned; blocked by the dependency test below.                                                                                                                                                                                                               | none                                                  |
| Claude   | `ycc-agents@ycc`                                                   | Native agents-only plugin                                    | **Deferred to v7.0.0**, with qualified `ycc-agents:` references.                                                                                                                                                                                             | claude-namespace (shared name No-Go)                  |
| Claude   | Rules, `CLAUDE.md`, settings                                       | `install.sh` only                                            | Stays on `install.sh`. No Claude `ycc-rules`.                                                                                                                                                                                                                | Plugin manifests have no rules component.             |
| Codex    | `ycc@ycc` (skills and `shared/`)                                   | Native plugin, relative `local` source                       | Current catalog is `local-ycc-plugins` with `./plugins/ycc`. Planned listing at the flip: `.agents/plugins/marketplace.json` with `{"source":"local","path":"./.codex-plugin/ycc"}`. Sparse installs must include `.agents/plugins` and `.codex-plugin/ycc`. | codex-marketplace                                     |
| Codex    | `ycc-mcp@ycc`                                                      | Native MCP                                                   | Listed in `.agents/plugins/marketplace.json` at v6.0.0. Native MCP uses Codex `env_vars`. YAN-1131 installed it on codex-cli 0.161.0 from a local Git fixture.                                                                                               | YAN-1131 fixture smoke                                |
| Codex    | `ycc-hooks@ycc`                                                    | Native hooks                                                 | **Excluded.** NO-GO until verified under YAN-1149.                                                                                                                                                                                                           | codex-marketplace                                     |
| Codex    | Agents (`*.toml`), `AGENTS.md`, config                             | `install.sh` only                                            | Stays on `install.sh`; Codex plugins cannot carry these.                                                                                                                                                                                                     | codex-marketplace (no plugin layer)                   |
| Cursor   | `ycc@ycc` (skills, agents, commands, `shared`)                     | Native plugin package under `packages/cursor/ycc/`           | Listed in the root `.cursor-plugin/marketplace.json` at v6.0.0 (interactive install verified, YAN-1141). File-copy installer remains available.                                                                                                              | cursor-plugin (registration only)                     |
| Cursor   | `ycc-rules@ycc`, `ycc-mcp@ycc`                                     | Native plugin packages under `packages/cursor/`              | Listed in the root `.cursor-plugin/marketplace.json` at v6.0.0. `ycc-mcp` declares `${VAR}` placeholders under manifest `variables`; secret literals are rejected by the generator.                                                                          | none                                                  |
| Cursor   | `ycc-hooks@ycc`                                                    | Native hooks package under `packages/cursor/ycc-hooks/`      | Listed at v6.0.0; `sessionStart` only, from `ycc/settings/cursor/{hooks.json,herdr-session-start.sh}`. No `WorktreeCreate` mapping; installer hooks intent remains a no-op.                                                                                  | cursor-plugin                                         |
| opencode | File copy (skills, agents, commands, `opencode.json`, `AGENTS.md`) | `install.sh`                                                 | **Primary and unchanged.**                                                                                                                                                                                                                                   | opencode-config-hook (fallback)                       |
| opencode | `@yandy-r/ycc-opencode`                                            | One npm plugin; V2 `setup` registers components              | Experimental, **opt-in**, outside every catalog. Published by `.github/workflows/release.yml` with provenance on a maintainer-pushed `vX.Y.Z` tag on `main`; `engines.opencode` floor `>=2.0.30` (spike ran on 2.0.29).                                      | opencode-config-hook                                  |
| agents   | Skills and `ycc-shared`                                            | File copy into `~/.agents/skills` and `~/.agents/ycc-shared` | `install.sh` only. The npx skills spike does not replace that install.                                                                                                                                                                                       | [npx-skills](../spikes/npx-skills.md)                 |

The opencode spike verified **GO** for the V2 `plugins` array, whose default-exported
`{ id, setup }` plugin registered agents, commands, skills, and MCP through the V2
registration APIs; its `session.hook("context", ...)` also delivered instructions to the
model request. It verified **NO-GO** for the V1 `config`-hook plugin shape. It also found
that a config `instructions` entry naming a local file did not reach the model. An HTTP or
glob `instructions` entry was not probed, so it is unverified rather than NO-GO. The
skills-from-config paths (a local directory and a loopback HTTP catalog) were GO. These
findings are pinned to opencode v2.0.29; other versions are unverified. The `plugins` array is the V2 configuration key, not a defect to rename.

### Dependencies

- Claude native packages may declare **bare-name** dependencies inside one relative-path
  marketplace (for example, `ycc-all` depends on `ycc`, `ycc-mcp`, and `ycc-hooks`). No
  version ranges and no per-plugin tags.
- The minimum Claude Code version for `dependencies` is **not verified**. No spike tested
  dependency installation (the namespace spike says so explicitly). Test dependency installation on
  2.1.143 as a candidate baseline and on the latest client before listing `ycc-all`, then
  establish and document the supported minimum from those results.
- Every other runtime ships self-contained packages. No runtime other than Claude has a
  dependency field. A closure expansion from `ycc/settings/packages.json` through
  `install.sh --package` is planned but not implemented.
- `scripts/build_package_graph.py` (YAN-1129, YAN-1162) builds the component graph and validates
  package closures, complete dispatch tokens (including casing and invalid suffixes), required
  catalog skills, and public-package duplicates in the `packages` validator group. Prose `mention`
  edges stay informational and out of closure.
  Any shared `_shared/` content and cross-skill script reach-ins stay inside `ycc`, so nothing is
  vendored in 6.0.

### Versioning

- **Lockstep.** All workflow packages share the product version. `status-bar` keeps its own
  version in `ycc-mods`, as today.
- **One tag.** A maintainer pushes one `vX.Y.Z` tag from `main`. Agents never tag, and there
  are no per-plugin tags in v6.
- **Release tooling today.** `bump-version.sh` updates only the source version fields:
  `ycc/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (`metadata.version` and
  each existing `plugins[].version`), and `ycc/package.json` when it already has a version. It
  does not edit generated bundles. `preflight.sh` checks version parity across every
  discovered versioned marketplace entry and package manifest, excluding `ycc/mods`. Discovery
  reads `ycc/settings/packages.json` directly: each included native entry must have an existing
  versioned manifest (check-only; Claude `ycc` is canonical), deferred and excluded entries are
  suppressed, and file-copy entries are skipped. An included opencode npm package must have
  `packages/opencode/<unscoped-key>/package.json` at the lockstep version; a missing manifest
  fails preflight and the bump without writes. A bounded scan still covers unmodeled manifests,
  and a missing or malformed model fails the bump without writes.
- **Codex pinning.** The Codex catalog uses a relative `local` source, not a version-pinned
  `git-subdir`, so no tag has to exist before the release PR merges.
- **npm publication.** `.github/workflows/release.yml` publishes the experimental, opt-in
  `@yandy-r/ycc-opencode` package with `npm publish --provenance --access public` on a
  maintainer-pushed product tag. It runs only on tag pushes (never branches, PRs, or manual
  runs) with `contents: read` and `id-token: write`. `scripts/opencode_npm_release.py` fails
  closed unless the tag is strict `vX.Y.Z`, the checked-out commit equals the tag and event
  SHA, that commit is an ancestor of freshly fetched `origin/main`, and the tag, canonical
  `ycc/.claude-plugin/plugin.json`, generated `package.json`, and every lockstep surface agree.
  The job then runs the scoped `opencode,packages` validators and the release-bundle
  regression, packs, and publishes the packed artifact. The `release` environment must have
  maintainer approval, and publishing authenticates with npm trusted publishing (OIDC): the
  job runs on a GitHub-hosted runner with Node 24 and a pinned `npm@11.21.1`
  (`--ignore-scripts`; npm trusted publishing requires Node >= 22.14.0 and npm >= 11.5.1 —
  see [npm trusted publishing docs](https://docs.npmjs.com/trusted-publishers)),
  publishes with `npm publish --provenance --access public`, and uses
  the workflow's `id-token: write` permission for registry authentication and provenance —
  no npm token is stored or mapped in the repository. Maintainer prerequisite: register this
  exact trusted publisher on npmjs.com for `@yandy-r/ycc-opencode` — repository owner
  `yandy-r`, repository `ystack`, workflow filename `release.yml`, GitHub
  environment `release` — allowing `npm publish`. The `@yandy-r` npm scope is already
  owned; no token setup is required. Also restrict `v*` tag creation. These package-specific
  trusted publisher settings have not been verified here, and no publish was attempted.
  Nothing is published until a maintainer pushes a tag; the package stays outside
  every catalog (`listed: false`) and activation stays opt-in. The package `engines.opencode` floor is `>=2.0.30`, the version
  its package smoke targets; the registration spike ran on 2.0.29. The `plugins` array is
  the V2 key; a plugin and the file copy installed together register components twice.

### Gates

The gates and feature switches are listed in
[RELEASING.md, Unfinished work](../../../RELEASING.md#unfinished-work). The main gates are:

- Unlisted native packages stayed out of production catalogs until the v6.0.0 listing flip, which
  has landed (see the status update above). The listing PR flipped only after the proof
  gates in RELEASING.md passed for every listed package.
- `listed: false` in `ycc/settings/packages.json` is generator input, not a runtime field. The
  Codex metadata generator consumes it. The checked-in catalog now lists the included
  Codex packages; `generate-codex-plugin.sh --native-output DIR` exports the complete split
  outside the checkout for verification.
- YAN-1132 generates all four included native Cursor packages regardless of `listed`.
  They live under `packages/cursor/` and are listed in the root marketplace after the flip.
  Interactive installation was verified in YAN-1141; file-copy install behavior is unchanged.
- Codex hooks stay excluded until verified (YAN-1149).
- The opencode npm package is published only by the tag-triggered workflow described under
  Versioning, and activation is always opt-in.

## Consequences

- **Existing Claude users.** Their `ycc@ycc` keys survive the rename because the GitHub
  redirect works. They receive new packages only after `/plugin marketplace update ycc`,
  because Claude turns auto-update off by default for third-party marketplaces.
- **Duplicate loading.** A native plugin and a file copy can both be installed. Installer
  dedupe was required before native hooks roll out; `install.sh migrate` now provides it. At decision time the `merge_managed_config.py`
  `hooks` policy is `map-entries`, which cannot remove only installer-owned command entries,
  so a shared hook array could not be cleaned safely.
- **Cursor.** YAN-1132 generates four native packages under `packages/cursor/`:
  `ycc`, `ycc-rules`, `ycc-mcp`, and `ycc-hooks`. `installer-fallback` adds the file-copy
  settings payload under `packages/cursor/installer-fallback/config/cli-config.json`.
  At the v6.0.0 flip all four are listed in the root `.cursor-plugin/marketplace.json`.
  Marketplace registration was verified in the CLI at user scope (spike) and interactive
  installation in the YAN-1141 maintainer verification. The file-copy installer remains available;
  `~/.cursor/skills` copies are not collapsed with plugin skills, so
  `install.sh migrate` must delete those copies itself.
- **Claude agents.** Splitting agents into `ycc-agents` in 6.x would need qualified
  `ycc-agents:` references, which is a breaking namespace change. It is therefore v7.0.0.
  Hidden prep (YAN-1142): `scripts/claude_agents_split.py` builds the split on demand from
  unchanged `ycc/` source and never commits it. The split has a skills-only `ycc` that
  depends on an agents-only `ycc-agents`, and agent references become
  `ycc-agents:<frontmatter-name>`. The `claude-native` validation target checks the built tree.
  `scripts/test-claude-agents-split.sh` is the opt-in live dispatch proof. Results are in
  the namespace spike's "Production prep" section.
- **opencode.** The npm package is optional and experimental. The file copy stays primary.
  On v2.0.29, the tested local-file config `instructions` entry did not reach the model.
  Plugin-delivered instructions can use the verified context hook. Discovered global and
  ancestor `AGENTS.md` files remain supported.

> **Update (2026-11-04, YAN-1962, v6.3.0):** the installer is native-only for Claude, Codex,
> Cursor and OMP. `install`/`sync` install the native packages through each runtime's plugin
> CLI (Claude `ycc@ycc`, `ycc-mcp@ycc`, `ycc-hooks@ycc`; Codex `ycc@ycc`, `ycc-mcp@ycc`;
> Cursor marketplace registration plus the interactive `/plugins` step), and the file-copy
> and managed-config routes those packages replace are removed. The `install.sh migrate`
> command is gone: the same proof-based dedupe now runs automatically after a successful
> native install and on `remove`, and never deletes user data. Installer-only artifacts
> (settings, rules, statusline, Codex custom agents) and the opencode and `agents` file
> copies are unchanged. The bullets above and the sections below record earlier states.

## Still absent

> **Update (2026-10-18):** this section records the pre-flip state. `install.sh migrate` now
> exists, the checked-in Codex catalog is named `ycc`, and `release.yml` publishes
> `@yandy-r/ycc-opencode` on maintainer-pushed product tags.

Original text (2026-10-15): `install.sh` had no `migrate` command. `--package` selected package
ids on `install`. `.github/workflows/release.yml` publishes `@yandy-r/ycc-opencode` only on a
maintainer-pushed product tag; no tag had been pushed and nothing had been published.
The checked-in Codex catalog was still named `local-ycc-plugins`.

### Snapshot from 2026-10-15

These items were absent before YAN-1128. YAN-1128 added the manifest, schema, loader,
and `packages` validator group. YAN-1129 added the package graph and closure validator.
Claude, Codex, and Cursor generators now read that manifest and kept new native packages
unlisted at the time. The paragraphs after the bullets record those landings.

- `ycc/settings/packages.json` and the package graph (`scripts/build_package_graph.py`).
- Per-runtime package generators and the `install.sh --package` and `migrate` commands.
- The `packages`, `claude-native`, `cursor-native`, and `codex-native` validator groups.
- The repo-rename dry-run script and the npm publishing workflow for `@yandy-r/ycc-opencode`
  (the workflow later landed as `.github/workflows/release.yml`; no tag has been pushed and
  nothing has been published).
- The Codex catalog rename and the Cursor native plugin layout.

YAN-1131 later implemented the Codex generator split and explicit external native export. It did
not rename the checked-in Codex catalog, list any package, or change installer migration.
Its harness (`scripts/test-codex-native-packages.sh`) installed `ycc@ycc` and `ycc-mcp@ycc`
on codex-cli 0.161.0 from full and sparse local Git fixtures and ran a cache-resolved bundled
helper. It did not exercise public GitHub transport or codex-cli 0.160.
YAN-1163 subsequently verified anonymous public GitHub HTTPS full and sparse installation
on exact codex-cli 0.160.0 with independently installed `ycc@ycc` and `ycc-mcp@ycc`,
cache-relative helper execution, and MCP metadata assertions. The fixture payload version
was 5.3.0, not the target v6.0.0. See the [public fork install evidence](../spikes/codex-public-fork-install.md)
for pinned fixture/binary provenance, replay commands, and boundaries. Production listing
(YAN-1140) and migration/dedupe (YAN-1139) remained closed; both have since landed in v6.0.0.
YAN-1217 then made the public profile certify the production repo itself: on codex-cli 0.160.0
and 0.163.0, `yandy-r/ystack` at a pinned `main` SHA installed both packages (v6.0.0 payload)
from full and sparse checkouts; the fixture proof now ignores installer-owned `.codex-plugin/`
entries, and `--codex-exact` keeps the exact-pin spike replay.

YAN-1132 later generated the hidden native Cursor packages under `packages/cursor/` from
`ycc/settings/packages.json`: `ycc` (skills, agents, shared, and thin command files derived
only from user-invocable skills), `ycc-rules`, `ycc-mcp` (placeholders declared as
manifest `variables`; no secret materialization), and `ycc-hooks` (`sessionStart` only,
from `ycc/settings/cursor/{hooks.json,herdr-session-start.sh}`; `WorktreeCreate` and other
Claude hook events are not re-encoded). Canonical
`ycc/settings/cursor/cli-config.json` is copied byte-identically into
`packages/cursor/installer-fallback/config/`. Every manifest carries
`minClientVersions.cursor: 3.24.12`, the tested floor from spike YAN-1124 (IDE 3.24.12 /
agent 2026.10.14); no older minimum is claimed. Manifests validate against the vendored
official `cursor/plugins` plugin schema pinned at commit
`f713f14203cd6420cec13cd7c55c32d598dbab68`, MIT-licensed (see `scripts/vendor/cursor/NOTICE`).
At the time of this snapshot all four native packages were unlisted (`listed: false` never gates
generation) and the generator wrote no root marketplace. The v6.0.0 listing flip changed that:
the generator now writes the root marketplace from the packages marked `listed: true`.

> **Update (2026-10-18):** the interactive Cursor installation gate was verified in the v6.0.0
> maintainer release verification (YAN-1141), covering the agent CLI and the Cursor IDE.

YAN-1137 later added offline native-policy fixtures to `claude-native`, `cursor-native`,
and `codex-native`, and manifest/tree/catalog parity to `packages`. These validator groups
do not list any package or prove installed-plugin runtime behavior.

The original M0 proposal to emit singular `plugin` and `agent` keys is obsolete. Opencode V1
support was dropped (YAN-1118 is canceled), so the V2-only target keeps the `plugins` array
([opencode spike](../spikes/opencode-config-hook.md)). That proposal is not pending
implementation and is not listed here.

This ADR changes no generated bundle, marketplace, or manifest.

## Evidence

- Spike dossiers: [claude-namespace](../spikes/claude-namespace.md), [claude-hooks](../spikes/claude-hooks.md),
  [codex-marketplace](../spikes/codex-marketplace.md), [cursor-plugin](../spikes/cursor-plugin.md),
  [opencode-config-hook](../spikes/opencode-config-hook.md), [npx-skills](../spikes/npx-skills.md).
- Decision inputs: [recommendation](../../research/ystack/recommendation.md)
  (owner decisions of 2026-10-14 in section 0) and [roadmap](../../research/ystack/roadmap.json).
- Release rules and switches: [RELEASING.md](../../../RELEASING.md).
