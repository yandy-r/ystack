<!-- Template used by bundle-release/scripts/draft-notes.sh. Placeholders are replaced at generation time; do not remove or rename them. The PACKAGES_TABLE placeholder renders one row per package and runtime from ycc/settings/packages.json (columns Package | Runtime | Status | Mechanism | Listed | Version or target | Notes): included packages show the release version, deferred and excluded packages show their target, and experimental/opt-in markers come from the package model. -->

# Release {{VERSION}} — {{DATE}}

## Summary

TODO: 1–2 sentence release summary.

## Added

{{COMMITS_ADDED}}

## Changed

{{COMMITS_CHANGED}}

## Removed

{{COMMITS_REMOVED}}

## Fixed

{{COMMITS_FIXED}}

## Packages

{{PACKAGES_TABLE}}

File-copy packages (the installer fallback) have no native manifest and are not versioned here.

## Validation

- `./scripts/sync.sh` — OK
- `./scripts/validate.sh` — OK
- `python3 -m json.tool .claude-plugin/marketplace.json` — OK
- `python3 -m json.tool ycc/.claude-plugin/plugin.json` — OK

## Upgrade Notes

TODO: breaking changes, migration steps, or "no action required".

## Commit Log

{{COMMITS}}

---

Previous release: {{PREV_TAG}}
