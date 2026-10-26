# Planning Tracks and Implementation Handoff

## Contents

- Integration with ycc
- Executing a Parallel Plan
- Comparison with other ycc planning tracks
- Which `--parallel` should I use?
- When to use `--enhanced`
- When to use `--no-worktree`

## Integration with ycc

After planning, depending on what the user approves:

- Use `/prp-implement` if they want rigorous per-task validation loops (requires a PRP-format plan file — consider running `/prp-plan` first if you want that workflow)
- Use `/implement-plan` if the work was structured via `/parallel-plan`
- Use `/code-review` to review completed implementation
- Use `/git-workflow --commit` or `/prp-commit` to commit

### Executing a Parallel Plan

If the plan was produced with `--parallel` (has a `Batches` section and `Depends on` annotations), after the user confirms you have two options for parallel execution:

**Option 1 — In-conversation parallel execution (lightweight)**

Before dispatching any `implementor` agents, prepare the feature branch so agents do not commit on `main`:

- **`WORKTREE_MODE=true` (default)** — the plan already names the parent worktree at `<repo-root>/.opencode/worktrees/<repo>-<feature>/` (branch `feat/<feature>`). Run `setup-worktree.sh parent <repo> <feature>` once, then dispatch agents with `Working directory: <parent path>`.
- **`WORKTREE_MODE=false` (`--no-worktree`)** — derive `FEATURE_SLUG` from the user's request using the team-name sanitization (lowercase, non-`[a-z0-9-]` → `-`, collapse runs, truncate to 20 chars, fallback `untitled`), then run `prepare-feature-branch.sh`; it is idempotent on `feat/${FEATURE_SLUG}`, exits 1 on unrelated dirty tree, exits 2 on a different feature branch (`--allow-existing-feature-branch` after confirmation) or, when RELEASING.md exists, on `release/*` (`--allow-release-branch` only for a release-only fix). See `~/.config/opencode/shared/references/branch-prep.md`. Do not skip this step.

Then run standalone-dispatch sections 9–10: batches sequentially, one implementor per step in a single message; run type-check and unit tests between batches; on failure stop and ask the user.

This keeps everything in the current conversation — no file artifact needed.

For unattended loop-to-completion of a parallel plan, hand off to `/implement-plan` and pair it with the `/goal` session directive — see that skill's `## /goal pairing` section for the recommended done condition (`ALL_BATCHES_DONE`, `FILES_CHANGED_NONEMPTY`, `LINT_PASS`) and the transcript-output contract.

**Option 2 — Save to file and hand off (rigorous)**

Resolve kind `prp-plan` for the feature slug through `~/.config/opencode/shared/scripts/resolve-artifact-store.sh` using the skill's three steps: print `--shell` and read `ARTIFACT_STORE`, apply the Linear call gate in linear mode, then `--ensure --kind=prp-plan --slug=<slug>`. Forward `${STORE_FLAG}` on every call. Prepare missing document/task identity via Lookup/Load before writing as required by artifact-store.md **Planning skills**, then Save (including task sub-issues). Write the resolved absolute `$OUT`, adapting to the PRP template when needed. Local mode keeps `docs/prps/plans/<slug>.plan.md` under the current checkout's git toplevel and retains move semantics; print `/prp-implement --parallel {resolved absolute OUT path}` only in local mode. Linear-mode plans are not yet consumable by implement-plan or prp-implement (YAN-1155); print that caveat instead and recommend `--store=local` for plans to implement now. Never move the linear cache or claim implementation loads from Linear.

Use Option 1 for small features and quick iterations. Use Option 2 when the user wants an implementation report, per-task validation logs, and the plan archived for audit.

## Comparison with other ycc planning tracks

| Track                  | When to use                                                                                                                                                                                                                                                               |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/plan` (this one) | Quick conversational plan via `planner` agent. No artifact file. Add `--parallel` to shape the output for parallel execution (no research fan-out). Add `--enhanced` to widen to 5 personas (security + UX), dispatched as standalone parallel sub-agents by default. |
| `/prp-plan`        | Artifact-producing plan with codebase pattern extraction. Single-pass. Add `--parallel` for 3-researcher fan-out + batched plan. Add `--enhanced` for the full 7-researcher fan-out.                                                                                      |
| `/prp-prd`         | Interactive PRD first, then prp-plan. Problem-first hypothesis workflow.                                                                                                                                                                                                  |
| `/plan-workflow`   | Heavyweight parallel-agent planning. Multi-task features. Artifact output.                                                                                                                                                                                                |
| `/parallel-plan`   | Lower-level component of `/plan-workflow` for dependency-aware plans.                                                                                                                                                                                                 |

### Which `--parallel` should I use?

- **`/plan --parallel`** — You want a quick parallel-capable plan without creating an artifact file. Planner does its own research. Best for small/medium features.
- **`/prp-plan --parallel`** — You want research fan-out (3 parallel researchers covering 8 categories) plus a full artifact file with patterns to mirror and validation commands. Best for medium/large features where you want a rigorous, auditable plan.
- **`/plan-workflow`** — You want heavyweight team orchestration with shared context and multi-phase validation. Best for very large features spanning many tasks.

### When to use `--enhanced`


- **`/plan --enhanced <request>`** — Fans out 5 standalone parallel sub-agents (Path C). Works in every bundle. Best for medium-complexity features where a 3-persona plan would miss security or UX considerations and you don't need the team coordination overhead.
- **`/plan --enhanced --parallel <request>`** — 5-persona plan formatted for parallel execution (Batches section, `Depends on` annotations).
- **`/plan --enhanced --dry-run <request>`** — Print the 5-persona roster without spawning anyone. Useful to confirm the team shape before paying the dispatch cost.
- **`/prp-plan --enhanced <request>`** — The heavier sibling: 7 researchers, artifact-producing. Use when you want the enhanced perspectives _and_ a saved plan file, not just an in-conversation plan.

### When to use `--no-worktree`

Worktree annotations are emitted by default. Pass `--no-worktree` to suppress the `## Worktree Setup` section and all per-task `**Worktree**:` annotations when you do not intend to use git worktree isolation:

- **`/plan --parallel <request>`** — Parallel-capable plan with full worktree annotations (default). Hand off to `/prp-implement` for isolated execution.
- **`/plan --no-worktree --parallel <request>`** — Parallel-capable plan without worktree annotations. Use when worktree isolation is not desired.
