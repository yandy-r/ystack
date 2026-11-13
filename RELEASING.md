# Branching and releases

These rules decide where every change to ystack (the `ycc` bundle) goes and how
versions ship. They apply to humans and agents alike, on every task, without being
restated in prompts.

The core idea: **a change's target release is decided before work starts, and the target
decides the base branch.** A release is a tag on a branch — never a set of commits picked
from somewhere else after the fact.

## Current state

The block below is read by tools; the table is generated from it. Change both with
`release-state-update.sh` (or `/ycc:release-model`), never by hand.

<!-- ycc-release-state
model: trunk-only
trunk: main
support: latest-minor
backport_label: backport:{X.Y}
tracker: none
-->

<!-- ycc-release-state:table:begin -->

Model: **trunk-only**. Support window: latest-minor.

| Role  | Branch | Notes                        |
| ----- | ------ | ---------------------------- |
| Trunk | `main` | Every release is tagged here |

<!-- ycc-release-state:table:end -->

## Rules

1. **Know the target before you branch.** Every issue carries a target release (see
   [Planning](#planning)). No target: a bug in a shipped version is a patch; everything else
   goes to the next release.
2. **Branch off `main` and PR back into it.** Topic branches are short-lived (days, not
   weeks) and named `<type>/<issue-id>-<slug>`. If one falls behind, rebase it.
3. **Never "sync" one long-lived branch into another.** No `sync main into …` PRs.
4. **Every release comes from `main`.** Fixes ship in the next release; there are no
   maintenance branches and no backports. When an older version needs patches, upgrade the
   model with `/ycc:release-model --upgrade` instead of branching ad hoc.
5. **No new long-lived branches.** Large work lands on `main` in small PRs. See
   [Unfinished work](#unfinished-work).
6. **`main` is always releasable.** CI green, and nothing half-built reachable by users.
7. **A maintainer approves each release once** ("ship x.y.z to prod?"), following
   [Releasing](#releasing). After that approval, agents may tag, publish and cut the release.

## Where does my change go?

Every change targets the next release and goes into `main`. Bugs and security fixes
may prompt an earlier release; they never create a branch of their own.

## Unfinished work

Big features merge incrementally instead of living on a side branch. Anything a user could
reach before it is finished stays hidden: behind a setting or environment variable that
defaults to off, or simply not wired into navigation or routes until the last PR. When a
change cannot be hidden (a rename, a data-directory move), prepare everything behind the
scenes first and make the switch in one final PR shortly before the release.

List the project's feature switches here as they are added, with their default and the
release that flips them.

### v6.0.0 package-model gates

The v6.0.0 package model is recorded in
[ADR 0001](docs/internal/adr/0001-package-model-and-versioning.md). v6.0.0 flipped the
listing gates below: the native packages are listed in every marketplace, and the gates
that remain open are marked. They change nothing about the release procedure below.

| Gate                                            | State                                                                                                                                                                                                       | Flips when                                                                                                                                                                                                                             |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Native package catalogs (Claude, Codex, Cursor) | Flipped in v6.0.0. Claude lists `ycc`, `ycc-mcp`, `ycc-hooks` and `ycc-all`; the Codex `ycc` catalog lists `ycc` and `ycc-mcp`; the Cursor marketplace lists `ycc`, `ycc-mcp`, `ycc-hooks` and `ycc-rules`. | Done: package validators, lockstep preflight, migration and dedupe tests, clean-machine fork installs, `ycc-all` dependency installation, and Cursor interactive installation passed in the v6.0.0 maintainer verification (YAN-1141). |
| `listed` flag in `ycc/settings/packages.json`   | Generator input, not a runtime field. Catalog emission follows it; every included native package is `listed: true`.                                                                                         | Done in v6.0.0. Set a new package's flag only after the same proof gates pass for it.                                                                                                                                                  |
| Claude `ycc-hooks`                              | Listed; requires Claude Code 2.1.300 or later. `install.sh install`/`sync --intent hooks` installs it natively and retires the old installer-merged hook (user-owned hooks kept).                           | Done in v6.0.0; installer route native-only since v6.3.0.                                                                                                                                                                              |
| Codex `ycc-hooks`                               | Excluded. Hooks stay out of the Codex bundle.                                                                                                                                                               | YAN-1149 verifies hook trust and dispatch, or a later spike supersedes the YAN-1123 no-go.                                                                                                                                             |
| opencode `@yandy-r/ycc-opencode` npm package    | Experimental; activation is always opt-in. `.github/workflows/release.yml` publishes it with provenance on a maintainer-pushed `v*` tag.                                                                    | Stays experimental and opt-in; the `install.sh` file copy remains the primary opencode path.                                                                                                                                           |
| Repo rename to `ystack`                         | Done. GitHub and Forgejo renamed (from `claude-plugins`, then `agentic-code-plugins`); references flipped on `main`. Old GitHub names redirect.                                                             | Complete; no further flip.                                                                                                                                                                                                             |
| Install guides (`docs/install/*`)               | One set of native-only install guides; `docs/install/v6/` is the package reference. The `migrate` subcommand was removed in v6.3.0 (install/sync retire legacy state automatically).                        | Done in v6.3.0.                                                                                                                                                                                                                        |
| Claude `ycc-agents` split                       | Deferred to **v7.0.0** as a breaking change. The breaking v7.0.0 migration uses distinct manifest names and qualified `ycc-agents:` references.                                                             | Production reference validation and live dispatch tests pass, then v7.0.0 ships.                                                                                                                                                       |

Versioning stays as in [Releasing](#releasing): one maintainer-pushed `v<semver>` tag,
lockstep versions across workflow packages, and no per-plugin tags. CI publishes the
experimental, opt-in `@yandy-r/ycc-opencode` npm package with provenance on that tag.

Spike evidence for each gate: YAN-1121 namespace, YAN-1122 hooks, YAN-1123 Codex
marketplace, YAN-1124 Cursor, and YAN-1125 opencode. The dossiers live under
`docs/internal/spikes/`; each is linked from the ADR.

## Releasing

Tags follow `vX.Y.Z` and are cut on `main`. Hand-edited version files:
`ycc/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (always the same
version). Generated package manifests are not edited by hand. `./scripts/sync.sh`
refreshes them, and preflight checks that they match. Changelog: none; each release
has notes in `docs/releases/<version>.md`.
`/ycc:bundle-release` prepares a release; nothing publishes automatically.

### Every release — from `main`

1. On an up-to-date `main`, run `/ycc:bundle-release <version>`. It bumps the source
   version fields, runs `./scripts/sync.sh` (including `packages/claude/` and
   `packages/cursor/`), runs `./scripts/validate.sh`, and drafts
   `docs/releases/<version>.md`. It never commits.
2. Review the notes, then commit `chore(release): vX.Y.Z` with the version bump, the
   regenerated bundles, `docs/inventory.json` and the release notes.
3. Tag `vX.Y.Z` on that commit and push `main` with the tag.
4. Publish the GitHub release from `docs/releases/<version>.md`.

`/ycc:bundle-release` prints the exact commands for steps 2–4. Use `/ycc:releaser` only
for other projects.

## Planning

Targets are decided in the PR description: say which release a change is for.
