---
description: Creates GitHub PRs from already-committed branches without commit orchestration.
  Use when opening a PR for current commits, drafting a template-based PR, or linking
  PRP artifacts in a PR.
argument-hint: '[base-branch] [--draft] [--ci] [--ci-max-pushes=N] [--ci-max-same-failure=N]
  [--ci-timeout-min=N] [--ci-yes]'
---

Load the `plugin:ycc:prp-pr` skill (`read_skill`) and follow its instructions with these arguments:

$ARGUMENTS
