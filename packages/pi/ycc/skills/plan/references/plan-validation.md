# Plan Validation

## Contents

- Check 1: Structure completeness
- Check 2: File path spot-check
- Check 3: Parallel mode integrity (`PARALLEL_MODE=true` only)
- Check 4: Multi-agent merge integrity (Path B and Path C)

After the `planner` agent returns its plan, perform these quick checks before presenting it to the user. Use only the tools already available to this skill.

### Check 1: Structure completeness

Scan the agent's response for these sections. If any **required** section is missing, re-dispatch the planner with a note to include the missing section(s).

**Required** (re-dispatch if missing):

- `## Overview` or `## Summary`
- `## Implementation Steps` or `## Step-by-Step Tasks`
- `## Testing Strategy`
- `**WAITING FOR CONFIRMATION**`

**Expected** (append a note to the plan if missing, but do NOT re-dispatch):

- `## Architecture Changes` or `## Requirements`
- `## Risks` or `## Risks & Mitigations`
- `## Success Criteria`

### Check 2: File path spot-check

Extract up to 10 file paths from the plan (backtick-quoted paths or paths after `File:` annotations). For each, use Glob or `Bash: test -f "<path>"` to check existence.

- If **all paths exist**: clean pass, append nothing.
- If **>30% of checked paths are missing**: append a validation note before relaying:

  > **Validation Note**: {N} of {M} file paths in this plan could not be found in the current codebase. This may indicate renamed files, planned new files, or stale references. Review the paths in the Implementation Steps before confirming.

- If **a few paths are missing** (≤30%): append a lighter note listing only the missing paths.

### Check 3: Parallel mode integrity (`PARALLEL_MODE=true` only)

If the plan was requested with `--parallel`, verify:

- A `## Batches` section exists in the response
- At least one `Depends on` annotation exists
- Step IDs use hierarchical format (N.N)

If any are missing, re-dispatch the planner with a directive to add the missing parallel annotations.
With `--team`, re-dispatch the `architect` only after prior teammates have shut down.

### Check 4: Multi-agent merge integrity (Path B and Path C)

After a Path B or Path C merge — that is, whenever multiple sub-agents contributed to the plan — verify the unified plan reflects every spawned perspective:

- `architect` slice: `## Implementation Steps` (or equivalent) is present and non-empty
- `risk-analyst` slice: a `## Risks` / `## Risks & Mitigations` section OR per-step risk callouts are present
- `test-strategist` slice: `## Testing Strategy` is present and non-empty
- When `ENHANCED_MODE=true`, also verify:
  - `security-reviewer` slice: `## Security Considerations` is present **OR** the merged plan documents that no significant security risks were found (e.g., a one-line note in `## Risks` such as "Security-reviewer: no significant risks identified"). Per-step `> **Security**:` callouts also satisfy this check.
  - `ux-reviewer` slice: `## UX Impact` is present **OR** the merged plan documents "Internal change — no user-facing UX impact". Both forms count as covered.

If the merge dropped a slice (e.g., because a teammate errored), append a visible note:

> **Validation Note**: The {role} perspective could not be included in this plan (teammate error). Review the plan for gaps in {area} before confirming.
