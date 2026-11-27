---
description: Audits stale Git resources and cleans them with approval. Use when pruning
  branches, removing abandoned worktrees, or closing stale PRs and issues.
argument-hint: '[--dry-run|--apply] [--branches] [--worktrees] [--remotes] [--stashes]
  [--tags] [--prs] [--issues] [--stale-days=N] [--host=github|gitlab|auto] [--protect=<pattern>]
  [--report-only]'
---

Load the `plugin:ycc:git-cleanup` skill (`read_skill`) and follow its instructions with these arguments:

$ARGUMENTS
