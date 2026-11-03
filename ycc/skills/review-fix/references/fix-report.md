# Fix Report

## Contents

- Report location
- Template
- Worktree summary

## Report location

Write the fix report to `$FIX_REPORT`, resolved in SKILL.md Phase 6 with kind `review-fixes-<REVIEW_ID>` from the active checkout root (`--ensure` creates its parent).

- **Local mode** — unchanged: `$(git rev-parse --show-toplevel)/docs/prps/reviews/fixes/`. When in a worktree this resolves to the worktree top-level; otherwise to the main repo. A review whose id the resolver rejects (renamed or legacy name) keeps this path without the resolver: `<source-name>-fixes.md`.
- **Linear mode** — `.ycc/artifacts/<slug>/reviews/<REVIEW_ID>-fixes.md` (gitignored), saved per `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/artifact-store.md` > Review and report skills > Review fixes as Document `<slug> · <REVIEW_ID>-fixes`, parented like the review Document (none → local only).

Derive the report filename from the source review:

| Source                                                   | Report (local mode)                                      |
| -------------------------------------------------------- | -------------------------------------------------------- |
| `docs/prps/reviews/pr-42-review.md`                      | `docs/prps/reviews/fixes/pr-42-fixes.md`                 |
| `docs/prps/reviews/local-20260408-143022-review.md`      | `docs/prps/reviews/fixes/local-20260408-143022-fixes.md` |
| `.ycc/artifacts/<slug>/reviews/pr-42-review.md` (linear) | `.ycc/artifacts/<slug>/reviews/pr-42-fixes.md`           |

Local mode only: after writing the fix report, stage and commit it to the PR branch alongside the fix commits. Linear mode never commits it (gitignored, `REPORT_COMMITTED: n/a`) and never stages a `.gitignore` change made by `--ensure`. Stage fix commits by explicit path (`git add -- <fixed files>`), never `git add -A`.

```bash
FIX_REPORT_REL="docs/prps/reviews/fixes/<name>-fixes.md"
git add "$FIX_REPORT_REL"
git commit -m "docs(review): add fix report for PR #${PR_NUMBER}"
git push
```

## Template

```markdown
# Fix Report: <source-name>

**Source**: <source review path>
**Applied**: <ISO date>
**Severity threshold**: <CRITICAL|HIGH|MEDIUM|LOW>
**Mode**: Sequential | Parallel sub-agents (N batches, max width W) | Agent team (N batches, max width W)

## Summary

- **Total findings in source**: N
- **Already processed before this run**:
  - Fixed: A
  - Failed: B
- **Eligible this run**: M
- **Applied this run**:
  - Fixed: X
  - Failed: Y
- **Skipped this run**:
  - Below severity threshold: C
  - No suggested fix: D
  - Missing file: E

## Fixes Applied

| ID   | Severity | File             | Line | Status | Notes                                                               |
| ---- | -------- | ---------------- | ---- | ------ | ------------------------------------------------------------------- |
| F001 | CRITICAL | src/auth.ts      | 42   | Fixed  |                                                                     |
| F002 | HIGH     | src/api.ts       | 17   | Fixed  |                                                                     |
| F003 | HIGH     | src/db/query.ts  | 8    | Failed | Type error after edit; suggested fix referenced non-existent method |
| F005 | HIGH     | src/utils/fmt.ts | 112  | Fixed  | Same-file group with F004                                           |
| F004 | HIGH     | src/utils/fmt.ts | 78   | Fixed  | Processed in descending line order                                  |

## Files Changed

- `src/auth.ts` (Fixed F001)
- `src/api.ts` (Fixed F002)
- `src/utils/fmt.ts` (Fixed F004, F005)

## Failed Fixes

### F003 — `src/db/query.ts:8`

**Severity**: HIGH
**Category**: Security
**Description**: Unescaped input in raw SQL query
**Suggested fix (from review)**: Use `db.query('... WHERE id = $1', [userId])`
**Blocker**: `Property 'query' does not exist on type 'Connection'`. The connection type in this codebase exposes `execute`, not `query`.
**Recommendation**: Update the review's Suggested fix to use `db.execute(...)` and re-run `/ycc:review-fix`.

## Validation Results

| Check      | Result                |
| ---------- | --------------------- |
| Type check | Pass / Fail / Skipped |
| Tests      | Pass / Fail / Skipped |

## Next Steps

- Re-run `/ycc:code-review <same target>` to verify the remaining open findings and confirm fixes resolved the issues
- Address failed fixes manually using the Blocker + Recommendation notes above
- Commit the fixed files by name when satisfied (`/ycc:prp-commit <fixed files>`); leave any artifact-store `.gitignore` rule out of the commit
```

## Worktree summary (only when `WORKTREE_ACTIVE=true`)

At the end of REPORT, append to the fix report:

```markdown
## Worktree Summary

<output of list-worktrees.sh>

### Next steps

- Review the parent worktree: `git -C <PARENT_PATH> log --oneline -10`
- Push to update the PR: `git -C <PARENT_PATH> push origin HEAD`
- Clean up when done: `git worktree remove <PARENT_PATH>`
```

Populate the `<output of list-worktrees.sh>` block by running:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/list-worktrees.sh" \
  "${REPO}" "${SLUG}"
```

---
