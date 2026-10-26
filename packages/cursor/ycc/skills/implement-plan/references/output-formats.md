# Parallel Plan Output Formats

## Contents

- Dry-run formats
- Completion summary
- Goal pairing

## Dry-run formats

If `--dry-run` is present:

**Default dry-run (no `--team`)** — display the batch roster only:

```markdown
# Dry Run: Implementation Plan for [feature-name]

## Execution Batches

### Batch 1 (Independent Tasks)

- Task 1.1: [Title]
- Task 1.3: [Title]
- Task 2.2: [Title]

### Batch 2 (After Batch 1)

- Task 1.2: [Title] (depends on 1.1)
- Task 2.1: [Title] (depends on 1.1, 1.2)

### Batch 3 (After Batch 2)

- Task 2.3: [Title] (depends on 2.1, 2.2)
- Task 3.1: [Title] (depends on 2.1)

## Summary

- Total Tasks: [count]
- Total Batches: [count]
- Max Parallelism: [largest batch size]

## Next Steps

Remove --dry-run flag to execute the plan.
```

### Agent-Team Dry-Run

With `--team --dry-run`, also print the team name and per-batch teammate roster:

```
Team name:    impl-<sanitized-feature-name>
Total tasks:  <N>  (across <M> batches, max parallel width <X>)
Dependencies: <K edges>  (from the parsed Depends on annotations)

Batch 1: <comma-separated task IDs>
Batch 2: <comma-separated task IDs>  (depends on Batch 1)
...
Batch M: <comma-separated task IDs>  (depends on Batch M-1)

Per-batch teammate roster:
  Batch 1:
    - <task-id-1>  subagent_type=implementor  task=<short>
    - <task-id-2>  subagent_type=implementor  task=<short>
  ...
```

Do **not** call `task registration`, `Agent`, or `SendMessage` in dry-run mode. **STOP HERE**.

## Completion summary

Provide completion summary:

```markdown
# Implementation Complete

## Feature

[feature-name]

## Execution Mode

[Standalone sub-agents | Agent team (team: impl-<name>)]

## Execution Summary

- **Total Tasks**: [count]
- **Completed**: [count]
- **Failed**: [count]
- **Batches Executed**: [count]

## Files Changed

### Created

- /path/to/new/file.ext
- /path/to/another/file.ext

### Modified

- /path/to/existing/file.ext
- /path/to/another/existing/file.ext

## Task Results

### Batch 1

- [x] Task 1.1: [Title] - Success
- [x] Task 1.3: [Title] - Success

### Batch 2

- [x] Task 1.2: [Title] - Success
- [x] Task 2.1: [Title] - Success

## Issues Encountered

[List any problems or warnings]

## Linear ← include this section only when ARTIFACT_STORE=linear

- **Issues moved**: [parent/task keys and resulting state types, or none]
- **Skipped on resume**: [completed task ids/keys; canceled task ids/keys]
- **Untracked tasks**: [ids without mapped issues; suggest re-saving with /parallel-plan]
- **Project**: [URL; completed, or left open with reason]
- **Plan**: [Document URL]
- **Report**: [absolute report cache path; Project status update URL, or pending]

### Linear sync pending

[Each unapplied transition/report write, or None; preserve the same list in the report with pending: true while unapplied]

## Worktree Status ← include this section only when WORKTREE_ACTIVE=true

[Output of list-worktrees.sh]

> The parent worktree at `<repo-root>/.cursor/worktrees/[repo]-[feature]/` survives for inspection
> and PR creation. When you are done, run:
>
> git worktree remove <repo-root>/.cursor/worktrees/[repo]-[feature]/
> git branch -d feat/[feature]

## Next Steps

1. Review the changes in your editor
2. Run tests to verify functionality
3. Commit the changes when satisfied
4. **Optional**: Generate implementation report:

/code-report [feature-name]

## Goal Signals (machine-readable — printed verbatim for /goal)

ALL_BATCHES_DONE: PASS
FILES_CHANGED_NONEMPTY: PASS
LINT_PASS: PASS
```

Print every signal verbatim as the last lines of the completion summary. Use `PASS` only
when the matching criterion in `## Success Criteria` is met; otherwise `FAIL` (for example
`FILES_CHANGED_NONEMPTY: FAIL` when the "Files Changed" section enumerated no files).

In linear mode, Step 9 already writes kind `report` and Saves a Project status update per `references/linear-sync.md`. Include its URL (or pending failure), issue transitions, skipped tasks and Project completion reason above; do not claim a remote write succeeded without its response. Keep the Goal Signals unchanged and last.

## Goal pairing

Pair this skill with the `/goal` session directive to loop the batch executor to completion
without re-prompting between batches or after the lint pass. Supply an explicit done
condition that references the Phase 4 Step 10 Goal Signals block rather than file paths.

Recommended condition template:

```
/goal Execute the parallel plan at docs/plans/<feature>/parallel-plan.md using the
implement-plan workflow, continuing through every batch and the Phase 4 lint pass
without returning control to me. Done when the transcript shows the Phase 4
"# Implementation Complete" output followed by all three Goal Signals printed verbatim —
ALL_BATCHES_DONE: PASS, FILES_CHANGED_NONEMPTY: PASS, LINT_PASS: PASS. If any signal prints
FAIL, keep fixing and re-running until all three are PASS. Stop after 25 turns if not
achieved.
```

The transcript-output contract and shared caveats (worktree cwd, interactive failure
prompts, platform availability) live in the shared reference — read it before relying on a
`/goal` loop:

```
${CURSOR_PLUGIN_ROOT}/skills/_shared/references/goal-pairing.md
```
