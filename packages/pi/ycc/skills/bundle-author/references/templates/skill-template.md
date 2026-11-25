---
name: '{{NAME}}'
description: '{{DESCRIPTION}}'
{{INVOCATION_OPT_OUT}}argument-hint: '[--dry-run]'
allowed-tools:
  - Read
  - Grep
  - Glob
  - Write
---

# {{NAME}}

{{DESCRIPTION}}

## Arguments

- `$ARGUMENTS`: User-provided arguments.

## Phase 1: Setup

TODO: describe initial validation and context gathering.

## Phase 2: Execution

TODO: describe the main work this skill performs.

## Phase 3: Output

TODO: describe what the skill emits to the user.

## Notes

- Add references under `references/` for static content.
- Add bash helpers under `scripts/` invoked as `${CLAUDE_PLUGIN_ROOT}/skills/{{NAME}}/scripts/<name>.sh`.
- Regenerate bundles with `./scripts/sync.sh` after adding this skill.
