---
description: Backports merged trunk PRs to maintenance branches. Use when backporting
  a fix, opening backport PRs, or auditing pending backports.
argument-hint: <PR#> [--to release/X.Y] | --pending [--resolve] [--ci] [--dry-run]
  | --audit [release/X.Y] [--since REF]
---

Load the `plugin:ycc:backport` skill (`read_skill`) and follow its instructions with these arguments:

$ARGUMENTS
