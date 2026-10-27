# PRP Report and Output Formats

## Contents

- Implementation report
- PRD update and archive
- Worktree Summary
- User output and Goal Signals
- Goal pairing
- Next Steps

## Implementation report

Local mode:

```bash
mkdir -p docs/prps/reports
```

Write report to `docs/prps/reports/{plan-name}-report.md`:

Linear mode: resolve the report path instead with `resolve-artifact-store.sh ${STORE_FLAG} --ensure --kind=prp-report --slug=<slug>` and write it there; Save and completion follow `references/linear-sync.md`. Content below is the same in both modes.

```markdown
# Implementation Report: [Feature Name]

## Summary

[What was implemented]

## Assessment vs Reality

| Metric        | Predicted (Plan) | Actual         |
| ------------- | ---------------- | -------------- |
| Complexity    | [from plan]      | [actual]       |
| Confidence    | [from plan]      | [actual]       |
| Files Changed | [from plan]      | [actual count] |

## Tasks Completed

| #   | Task        | Status          | Notes               |
| --- | ----------- | --------------- | ------------------- |
| 1   | [task name] | [done] Complete |                     |
| 2   | [task name] | [done] Complete | Deviated — [reason] |

## Validation Results

| Level           | Status      | Notes           |
| --------------- | ----------- | --------------- |
| Static Analysis | [done] Pass |                 |
| Unit Tests      | [done] Pass | N tests written |
| Build           | [done] Pass |                 |
| Integration     | [done] Pass | or N/A          |
| Edge Cases      | [done] Pass |                 |

## Files Changed

| File           | Action  | Lines   |
| -------------- | ------- | ------- |
| `path/to/file` | CREATED | +N      |
| `path/to/file` | UPDATED | +N / -M |

## Deviations from Plan

[List any deviations with WHAT and WHY, or "None"]

## Issues Encountered

[List any problems and how they were resolved, or "None"]

## Tests Written

| Test File      | Tests   | Coverage       |
| -------------- | ------- | -------------- |
| `path/to/test` | N tests | [area covered] |

## Next Steps

- [ ] Code review via `$code-review`
- [ ] Create PR via `$prp-pr`
```

## PRD update and archive

### Update PRD (if applicable)

If this implementation was for a PRD phase:

1. Update the phase status from `in-progress` to `complete`
2. Add report path as reference

### Archive Plan (local mode only)

Run inside `$WT_PARENT_PATH` (when `WORKTREE_ACTIVE=true`) so the archive lives next to the implementation report, not back in main. `$PLAN_PATH` is the relocated plan path set in Phase 2; if the run was `--no-worktree` it falls back to `$ARGUMENTS`.

```bash
PLAN_PATH="${PLAN_PATH:-$ARGUMENTS}"
mkdir -p "$(dirname -- "$PLAN_PATH")/completed"
mv "$PLAN_PATH" "$(dirname -- "$PLAN_PATH")/completed/"
```

Linear mode has no archive move: close the parent issue and apply the Project-completion rule per `references/linear-sync.md`.

### Worktree Summary (when `WORKTREE_ACTIVE=true`)

After archiving the plan, run:

```bash
bash ../../../shared/scripts/list-worktrees.sh \
  "${WT_REPO_NAME}" "${WT_FEATURE_SLUG}"
```

Include the full output (markdown table + cleanup commands) in the implementation report under a `## Worktree Summary` section. This shows the surviving parent worktree path, its branch, and the `git worktree remove` command for manual cleanup.

**CHECKPOINT**: Report created. PRD updated. Plan archived. Worktree summary captured (if applicable).

## User output and Goal Signals

Report to user (linear mode: print `[plan Document URL] → issues closed` instead of the archive path on the **Plan** line, and use the Linear Artifacts section):

```
## Implementation Complete

- **Plan**: [plan file path] → archived to completed/
- **Branch**: [current branch name]
- **Mode**: [Sequential | Parallel sub-agents (N batches, max width X) | Agent team (N batches, max width X)]
- **Status**: [done] All tasks complete

### Validation Summary

| Check       | Status               |
| ----------- | -------------------- |
| Type Check  | [done]               |
| Lint        | [done]               |
| Tests       | [done] (N written)   |
| Build       | [done]               |
| Integration | [done] or N/A        |

### Files Changed

- [N] files created, [M] files updated

### Deviations

[Summary or "None — implemented exactly as planned"]

### Artifacts

- Report: `docs/prps/reports/{name}-report.md`
- Archived Plan: `docs/prps/plans/completed/{name}.plan.md`

### Linear Artifacts ← include this section only when ARTIFACT_STORE=linear (omit the two Artifacts lines above)

- Report: [Linear Project / status update URL, or pending]
- Plan: [Linear plan Document URL] (not archived; parent issue completed)

### PRD Progress (if applicable)

| Phase   | Status         |
| ------- | -------------- |
| Phase 1 | [done] Complete |
| Phase 2 | [next]         |
| ...     | ...            |

### Worktree Summary (if worktree mode was active)

[Output of `list-worktrees.sh <repo> <feature>` — surviving parent worktree path, branch, and cleanup commands]

> Run `git worktree remove <repo-root>/.codex/worktrees/<repo>-<feature>/` after merging and pushing to clean up the parent worktree.

> Next step: Run `$prp-pr` to create a pull request, or `$code-review` to review changes first.

Print every signal verbatim. Use `PASS` only when the criterion in `## Success Criteria` is met; otherwise `FAIL`.

### Goal Signals (machine-readable — printed verbatim for /goal)

TASKS_COMPLETE: PASS
TYPES_PASS: PASS
LINT_PASS: PASS
TESTS_PASS: PASS
BUILD_PASS: PASS
REPORT_CREATED: PASS
PLAN_ARCHIVED: PASS
```

## Goal pairing

Pair this skill with the `/goal` session directive for autonomous plan execution across phase CHECKPOINTs. Supply an explicit done condition that references the Phase 6 Goal Signals block rather than file paths.

Recommended condition template:

```
/goal Implement the plan at docs/prps/plans/<name>.plan.md using the prp-implement
workflow, continuing through every phase CHECKPOINT without returning control to me.
Done when the transcript shows the Phase 6 "## Implementation Complete" output followed
by all seven Goal Signals printed verbatim — TASKS_COMPLETE: PASS, TYPES_PASS: PASS,
LINT_PASS: PASS, TESTS_PASS: PASS, BUILD_PASS: PASS, REPORT_CREATED: PASS,
PLAN_ARCHIVED: PASS. If any signal prints FAIL, keep fixing and re-running validation
until all seven are PASS. Stop after 25 turns if not achieved.
```

In linear mode, replace the plan path with the Linear reference or cached plan path; `PLAN_ARCHIVED` then means what SKILL.md Success Criteria says for linear mode.

The transcript-output contract and shared caveats (worktree cwd, interactive failure
prompts, platform availability) live in the shared reference — read it before relying on a
`/goal` loop:

```
../../../shared/references/goal-pairing.md
```

## Next Steps

- Run `$code-review` to review changes before committing
- Run `$prp-commit` to commit with a descriptive message
- Run `$prp-pr` to create a pull request
- Run `$prp-plan <next-phase>` if the PRD has more phases
