---
name: parallel-plan
description: Creates parallel-plan.md from existing shared.md through plan-workflow.
  Use when planning from shared context, organizing dependency batches, or validating
  parallel implementation tasks.
---

## MANDATORY FORCED MODE - READ FIRST

This skill is a thin alias. It ALWAYS runs canonical `plan-workflow` with
`--plan-only --no-checkpoint` (use existing `shared.md`, no interactive
checkpoint), regardless of `$ARGUMENTS`.

**Flag policy (unambiguous):**

- Supported: the feature name, `--dry-run`, `--no-worktree`, `--visual`.
- Silent no-op (legacy): `--worktree`.
- Redundant — silently ignored because already forced: `--plan-only`, `--no-checkpoint`.
- Every other flag (including `--research-only`, `--optimized`, and any unknown `-`/`--` token) → abort with the usage error below. Do not read the canonical skill or write anything.

## SCOPE LIMITATION - READ FIRST

**THIS SKILL ONLY CREATES PLANNING ARTIFACTS. IT NEVER IMPLEMENTS.**

- DO NOT execute any implementation tasks
- DO NOT modify application code
- DO NOT run the implement-plan skill
- DO NOT proceed beyond creating planning artifacts

**Outputs**:

- `${feature_dir}/analysis-context.md`
- `${feature_dir}/analysis-code.md`
- `${feature_dir}/analysis-tasks.md`
- `${parallel_plan_file}`

Canonical `plan-workflow` resolves these paths with the artifact-store `analysis-<name>` and `parallel-plan` kinds. Local mode keeps today's `docs/plans/<feature>/` paths; linear mode resolves under `.ycc/artifacts/<feature>/` and saves only the plan to Linear. Analysis remains local-only.

After creating planning artifacts and displaying the summary, **STOP COMPLETELY**.

---

# Parallel Plan (alias)

> **OpenCode V2 compatibility:** `--team` is unsupported. If it is supplied, abort before setup or dispatch and ask the caller to rerun without it. This target uses native standalone `subagent` calls only.

## Workflow Integration

```text
shared-context (step 1) -> parallel-plan (this skill) -> implement-plan (step 3)
```

This skill requires `${feature_dir}/shared.md` and ends after producing
analysis artifacts and `parallel-plan.md`. The user manually runs
`/implement-plan` when ready in local mode. Linear-mode plans are not yet consumable by implement-plan or prp-implement (YAN-1155); use `--store=local` for plans you will implement now.

**If shared.md doesn't exist**: canonical `plan-workflow/scripts/check-prerequisites.sh`
fails fast in plan-only mode. Stop and tell the user to run
`/shared-context [feature-name]` first. Do NOT fall back to research.

## Arguments

**Target**: `$ARGUMENTS`

- **--worktree**: Optional. (legacy — now default; safe to omit) Worktree annotations are emitted by default. Accepted as a silent no-op.
- **--no-worktree**: Optional. Opt out of worktree annotations. The plan will not contain a `## Worktree Setup` section.
- **--visual**: Optional. Render the finished plan as an Agent-Native visual artifact (MDX) via `visual-plan`; local-files by default, hosted link requires `--share`.
- **--dry-run**: Show what would be created without making changes. Writes nothing.
- **feature-name**: Required. Feature slug passed to canonical `plan-workflow` for artifact-store resolution.
- **--store=local|linear**: Optional artifact-store override, forwarded to canonical `plan-workflow`. Local is the default.

If any unsupported flag is present (see Flag policy above), abort with a usage error and STOP:

```
Usage: /parallel-plan [--no-worktree] [--visual] [feature-name] [--dry-run]
This alias always runs plan-workflow --plan-only --no-checkpoint.
Unsupported flag: <flag>
```

If no feature name provided, abort with the same usage plus examples:

```
/parallel-plan user-authentication
/parallel-plan payment-integration --dry-run
/parallel-plan --no-worktree user-authentication
/parallel-plan --visual user-authentication
```

## Execution

Build the **effective `$ARGUMENTS`** for canonical `plan-workflow`:

```
<feature-name> --plan-only --no-checkpoint [--dry-run] [--no-worktree] [--visual]
```

(optional flags only if the user passed them; `--worktree` maps to nothing —
it is a legacy no-op; user-supplied redundant `--plan-only` / `--no-checkpoint`
are dropped, not duplicated.)

1. Read `~/.config/opencode/skills/plan-workflow/SKILL.md`.
2. Execute as orchestrator with the effective `$ARGUMENTS` above substituted for `$ARGUMENTS`, so the canonical parser itself sets `PLAN_ONLY=true` and `NO_CHECKPOINT=true` (those variables are explanatory only — never invocation syntax).
3. On completion print the plan summary and STOP. Never implement.

## Summary

```markdown
# Parallel Plan Created

## Location

${parallel_plan_file}

## Analysis Files Generated

- ${feature_dir}/analysis-context.md
- ${feature_dir}/analysis-code.md
- ${feature_dir}/analysis-tasks.md

## Next Steps (FOR USER - NOT FOR THIS SKILL)

**THIS SKILL IS NOW COMPLETE. DO NOT PROCEED.**

Local mode only: /implement-plan [feature-name]

In linear mode replace that command with:
Linear-mode plans are not yet consumable by implement-plan or prp-implement (YAN-1155); use --store=local for plans you will implement now.
```

**STOP**: Do not execute implement-plan. Do not write any more files. Do not modify any code. This skill is complete.
