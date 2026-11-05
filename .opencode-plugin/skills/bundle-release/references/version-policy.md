# Bundle Version Policy

## Contents

- Version Surfaces
- Parity Rule
- No Stale Version Literals in Docs
- Semver Bump Rules
- Never-Edit List
- Pre-Bump Checklist

## Version Surfaces

The following files carry version information for the `ycc` bundle. Only hand-edited
files are modified directly; regenerated files are produced by running the listed
generator script.

| File                                                                                                                                                        | Kind        | Maintained by                                                                                                       |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------- |
| `ycc/.claude-plugin/plugin.json`                                                                                                                            | hand-edited | `bundle-release` `bump-version.sh`                                                                                  |
| `.claude-plugin/marketplace.json`                                                                                                                           | hand-edited | `bundle-release` `bump-version.sh`                                                                                  |
| `ycc/package.json`                                                                                                                                          | optional    | `bundle-release` `bump-version.sh` (only if it already has a `version` field)                                       |
| `ycc/settings/packages.json`                                                                                                                                | hand-edited | package model read directly by release discovery; validated, never bumped                                           |
| `packages/<package>` and `packages/<runtime>/<package>` manifests (`{.claude-plugin,.codex-plugin,.cursor-plugin,.omp-plugin}/plugin.json`, `package.json`) | regenerated | runtime package generators via `scripts/sync.sh`; included native manifests required, generated versions check-only |
| `.agents/plugins/marketplace.json`                                                                                                                          | regenerated | `scripts/generate-codex-plugin.sh`                                                                                  |
| `.codex-plugin/**`                                                                                                                                          | regenerated | `scripts/generate-codex-plugin.sh`                                                                                  |
| `.cursor-plugin/**`                                                                                                                                         | regenerated | `scripts/sync.sh --only cursor`                                                                                     |
| `.opencode-plugin/**`                                                                                                                                       | regenerated | `scripts/sync.sh --only opencode`                                                                                   |
| `.omp-plugin/marketplace.json` (catalog; present only while an OMP row is listed)                                                                           | regenerated | `scripts/sync.sh --only omp`                                                                                        |

Discovery rules are implemented in `bundle-release/scripts/release_versions.py`
(shared by `bump-version.sh` and `preflight.sh`):

- The canonical version is `ycc/.claude-plugin/plugin.json:"version"` (required).
- `ycc/settings/packages.json` is read directly by the source helper. A missing or
  malformed model fails discovery and aborts a bump before any writes.
- Every `included` native entry must have an existing manifest with a non-empty
  string version, regardless of `listed`: Claude `ycc` uses the canonical source;
  other Claude packages use `packages/claude/<key>/` with the same manifest suffix,
  Codex uses `.codex-plugin/<key>/.codex-plugin/plugin.json`, Cursor uses
  `packages/cursor/<key>/.cursor-plugin/plugin.json`, and OMP uses
  `packages/omp/<key>/.omp-plugin/plugin.json` plus `packages/omp/<key>/.opencode-plugin/plugin.json`
  and `packages/omp/<key>/package.json`. Generated manifests are check-only.
- Included opencode npm packages use `packages/opencode/<unscoped-key>/package.json`
  and are required to exist at the lockstep version (check-only). `release.yml`
  publishes the package to npm on the maintainer-pushed tag.
- `deferred` and `excluded` entries require no manifest and suppress their modeled
  paths from the bounded backstop. `file-copy` entries are skipped entirely.
- `ycc/mods/**` is excluded entirely — `ycc-mods` keeps its own version. Marketplace
  entries named `ycc-mods` or sourced from `./ycc/mods` are ignored wherever they appear.
- The root `package.json` (repo dev tooling), `node_modules`, git worktrees, docs and
  test fixtures are never scanned; discovery uses the package model plus a bounded
  allowlist of product paths for unmodeled manifests, not a repository-wide search.
- Versionless marketplace entries and unmodeled optional manifests are valid and
  never gain a `version` field; existing string versions participate unless suppressed
  above. `packages/<package>` and `packages/<runtime>/<package>` are both supported layouts.

## Parity Rule

Every product version field must equal `ycc/.claude-plugin/plugin.json:"version"`:
`.claude-plugin/marketplace.json` `metadata.version` (when present) and every
non-excluded `plugins[]` entry's `version`, the required included native manifests,
and the optional versioned manifests above. Only source manifests and versioned
`ycc/package.json` are bumped directly; `packages/**` is generated check-only.
Generated marketplaces and package manifests (`.agents/plugins/marketplace.json`,
`.omp-plugin/marketplace.json`, `.cursor-plugin/**`, `.codex-plugin/**`, `packages/**`) are checked
for parity too, refreshed only by
`./scripts/sync.sh`. `bundle-release/scripts/preflight.sh` enforces all of this before
any release action proceeds. If generated surfaces are stale after a bump, run
`./scripts/sync.sh` — never hand-edit them. If hand-edited sources diverge, fix them
before continuing.

Bumped files are re-serialized through JSON (`indent=2`, UTF-8, trailing newline);
key order and unrelated fields are preserved, but a hand-edited file with custom
formatting is normalized on its next bump. Reviewers should expect only version
values (and at most that formatting normalization) to change.

## No Stale Version Literals in Docs

Hand-edited documentation files (`AGENTS.md`, `AGENTS.md`, `README.md`, `docs/README.md`)
MUST NOT carry example snippets that hard-code a specific semver in a `version` key — they
drift silently as the bundle progresses through releases, leaving behind confusing
references to long-past versions.

When showing an example that would normally include a version, use the placeholder form
instead:

```
# Directory tree
plugin.json      # name: "ycc", version bumped by bundle-release

# JSON example
"version": "<managed by bundle-release>"
```

`bundle-release/scripts/preflight.sh` enforces this: it scans the hand-edited files for
patterns matching `[Vv]ersion[:=]["]?<semver>` and fails if any semver does not equal the
current bundle version. Prose mentions (e.g., "the 2.0.0 breaking change") are not
matched because the pattern requires a `version` key preceding the semver — those are
allowed in historical context.

Generated bundles (`.cursor-plugin/`, `.codex-plugin/`, `.opencode-plugin/`, `.omp-plugin/`,
`packages/`) and
historical dirs (`docs/releases/`, `docs/plans/`, `docs/research/`, `docs/internal/`)
are excluded from the scan.

## Semver Bump Rules

Use standard semver (`MAJOR.MINOR.PATCH`). Apply the first rule that matches:

**Major** — any of the following:

- Rename of a skill, command, or agent (changes the namespaced identifier consumers use)
- Removal of a skill, command, or agent
- Change to the `name` field in `plugin.json`
- Restructure of how the bundle is loaded or distributed

**Minor** — any of the following:

- New skill, command, or agent added
- Additive frontmatter fields on existing surfaces (no removals or renames)
- New shared helpers added under `_shared/` that do not break existing callers

**Patch** — any of the following:

- Bug fix inside an existing skill, command, or agent
- Documentation-only change (SKILL.md prose, reference docs, templates)
- Template refinement or whitespace/linter-only fix

Tie-breaker: when a change could reasonably justify two bump levels, prefer the more
conservative (higher) bump. When in doubt, bump minor rather than patch, and major
rather than minor.

## Never-Edit List

The following paths are fully regenerated. Do not hand-edit them. Make the
corresponding source change and rerun `./scripts/sync.sh` (or the individual generator
scripts) to propagate:

- `packages/**`
- `.agents/plugins/marketplace.json`
- `.agents-plugin/**`
- `.cursor-plugin/**`
- `.codex-plugin/**`
- `.opencode-plugin/**`
- `.omp-plugin/**`
- `docs/inventory.json`

## Pre-Bump Checklist

1. Confirm the working tree is clean (`git status` shows no uncommitted changes).
2. Run `bundle-release/scripts/preflight.sh` and verify it exits green.
3. Decide the semver bump level using the rules above.
4. Draft release notes using `release-notes-template.md` before publishing the tag.

See also: release-checklist.md, release-notes-template.md, AGENTS.md (Testing Changes).
