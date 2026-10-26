---
name: shared-context
description: Creates verified shared.md research context through plan-workflow. Use
  when gathering codebase context, preparing shared context for parallel-plan, or
  researching without generating a plan.
---

## MANDATORY FORCED MODE - READ FIRST

This skill is a thin alias. It ALWAYS runs canonical `plan-workflow` with
`--research-only --no-checkpoint` (stop after `shared.md` + validation, print
summary, no interactive checkpoint), regardless of `$ARGUMENTS`.

**Flag policy (unambiguous):**

- Supported: the feature name, `--dry-run`.
- Redundant — silently ignored because already forced: `--research-only`, `--no-checkpoint`.
- Every other flag (including `--plan-only`, `--no-worktree`, `--worktree`, `--visual`, `--optimized`, and any unknown `-`/`--` token) → abort with the usage error below. Do not read the canonical skill or write anything.

## SCOPE LIMITATION - READ FIRST

**THIS SKILL ONLY CREATES RESEARCH CONTEXT FILES. IT NEVER PLANS OR IMPLEMENTS.**

- DO NOT run the parallel-plan skill
- DO NOT run the implement-plan skill
- DO NOT execute implementation tasks
- DO NOT modify application source files

**Outputs**:

- `${research_dir}/research-architecture.md`
- `${research_dir}/research-patterns.md`
- `${research_dir}/research-integration.md`
- `${research_dir}/research-docs.md`
- `${shared_file}`

Canonical `plan-workflow` resolves these paths with the artifact-store `research-<lens>` and `shared` kinds. Local mode keeps today's `docs/plans/<feature>/` paths; linear mode resolves under `.ycc/artifacts/<feature>/`, places research under `research/`, and saves the research and shared documents to Linear.

After creating the shared context files and displaying the summary, **STOP COMPLETELY**.

---

# Shared Context (alias)

> **OpenCode V2 compatibility:** `--team` is unsupported. If it is supplied, abort before setup or dispatch and ask the caller to rerun without it. This target uses native standalone `subagent` calls only.

## Arguments

**Target**: `$ARGUMENTS`

- **--dry-run**: Show orchestration plan without creating files. Writes nothing.
- **feature-name**: Required. Feature slug passed to canonical `plan-workflow` for artifact-store resolution (kebab-case).
- **--store=local|linear**: Optional artifact-store override, forwarded to canonical `plan-workflow`. Local is the default.

If any unsupported flag is present (see Flag policy above), abort with a usage error and STOP:

```
Usage: /ycc:shared-context [feature-name] [--dry-run]
This alias always runs plan-workflow --research-only --no-checkpoint.
Unsupported flag: <flag>
```

If no feature name provided, abort with the same usage plus examples:

```
/ycc:shared-context user-authentication
/ycc:shared-context payment-integration --dry-run
```

## Execution

Build the **effective `$ARGUMENTS`** for canonical `plan-workflow`:

```
<feature-name> --research-only --no-checkpoint [--dry-run]
```


1. Read `{{package-root}}/skills/plan-workflow/SKILL.md`.
2. Execute as orchestrator with the effective `$ARGUMENTS` above substituted for `$ARGUMENTS`, so the canonical parser itself sets `RESEARCH_ONLY=true` and `NO_CHECKPOINT=true` (those variables are explanatory only — never invocation syntax).
3. On completion print the research summary and STOP. Never plan or implement.

## Summary

```markdown
# Shared Context Created

## Location

${shared_file}

## Research Files

- ${research_dir}/research-architecture.md
- ${research_dir}/research-patterns.md
- ${research_dir}/research-integration.md
- ${research_dir}/research-docs.md

## Next Step (User Triggered)

/ycc:parallel-plan [feature-name]
```

**STOP**: Do not execute parallel-plan. Do not write any more files. Do not modify any code. This skill is complete.
