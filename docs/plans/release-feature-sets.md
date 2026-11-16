# Release bumps by feature set

## Problem

`releaser` (Phase 2) and `bundle-release` (Phase 1) proposed a minor for any `feat:`
commit since the last tag, and a patch over `feat:` commits required a confirmation
override. One feature built across several `feat` commits therefore forced a minor
as soon as its first commit landed. The rule lived in skill prose (no script or test
pinned it) in five places: `releaser/references/release-preparation.md`,
`bundle-release/SKILL.md`, `bundle-release/references/version-policy.md` (plus its
"when in doubt, bump higher" tie-breaker), `bundle-release/references/release-checklist.md`,
and the `init` conventional-commits reference and `gitmessage.tmpl`.

## Options considered

| Option                       | Mechanism                                                                                                                                           | Cost                                                  |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| **A. Feature sets** (chosen) | Shared helper groups `feat` commits by `Feature-Set:` footer, else scope. The maintainer marks complete sets; only a complete set requires a minor. | One helper + tests; prose updates in the five places. |
| B. Advisory only             | `feat` becomes "minor-eligible"; patch over `feat` is a note, not a gate; tie-breaker prefers the lower bump.                                       | Prose only; no grouping, no deterministic floor.      |
| C. Tracked open sets         | `open_feature_sets` in the `RELEASING.md` state block via `release-state-update.sh`; closing a set makes the next release a minor.                  | State schema, template, audit and test churn.         |

Scope chosen: all three skills (`bundle-release`, `releaser`, `init` docs/template).

## Implementation

1. `ycc/skills/_shared/scripts/release-feature-sets.sh` + `release_feature_sets.py`
   (stdlib, `mypy --strict`): range = latest tag..HEAD (or `--from`/`--to`), merges
   skipped; `--complete <set,...>|all`; JSON or text; `required_bump` = major
   (breaking) > minor (a complete set) > patch > none. Unknown set names exit 1.
2. `releaser` Phase 2 and `bundle-release` Phase 1: run the helper, ask which sets
   are complete (multi-select), raise the mismatch concern only when the requested
   version is below `required_bump`. Headless runs treat every set as in progress.
3. `version-policy.md`: rules apply to feature sets; major is never downgraded;
   an unsure set is in progress.
4. `init` docs/template and `RELEASING.md`: `feat` = minor once its set is complete;
   document the `Feature-Set:` footer.
5. `scripts/test-release-feature-sets.sh` (auto-run by `validate.sh --only release`);
   helper added to `pyproject.toml` mypy files.

## Verification

- `scripts/test-release-feature-sets.sh`, full `./scripts/sync.sh` and `./scripts/validate.sh`.
- `mypy --strict` (pinned 2.4.0), `npm run lint:modified`, shellcheck.
- End to end: the helper run through each generated bundle's path against scenario repos.
