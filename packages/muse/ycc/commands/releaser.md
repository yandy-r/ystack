---
description: Prepares external-project releases, notes, and release CI. Use when cutting
  an application release, planning platform artifacts, or auditing a GitHub Actions
  release workflow.
argument-hint: '[version] [--arch=list] [--os=list] [--ci-config[=generate|audit]]
  [--platform=name] [--skip-notes] [--dry-run] [--exclude-internal] [--publish[=create|edit|auto]]
  [--confirm] [--ci] [--ci-max-pushes=N] [--ci-max-same-failure=N] [--ci-timeout-min=N]
  [--ci-yes] [--ci-recut=destructive]'
---

Load the `plugin:ycc:releaser` skill (`read_skill`) and follow its instructions with these arguments:

$ARGUMENTS
