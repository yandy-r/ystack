# Planning Tracks and Implementation Handoff

## Contents

- Integration with ycc
- Executing a Parallel Plan
- Comparison with other ycc planning tracks
- Which `--parallel` should I use?
- When to use `--team`
- When to use `--enhanced`
- When to use `--no-worktree`

## Integration with ycc

After planning, depending on what the user approves:

- Use `/skill:prp-implement` if they want rigorous per-task validation loops (requires a PRP-format plan file — consider running `/skill:prp-plan` first if you want that workflow)
- Use `/skill:implement-plan` if the work was structured via `/skill:parallel-plan`
- Use `/skill:code-review` to review completed implementation
- Use `/skill:git-workflow --commit` or `/skill:prp-commit` to commit

### Executing a Parallel Plan

If the plan was produced with `--parallel` (has a `Batches` section and `Depends on` annotations), after the user confirms you have two options for parallel execution:

**Option 1 — In-conversation parallel execution (lightweight)**

Before dispatching any `implementor` agents, prepare the feature branch so agents do not commit on `main`:

- **`WORKTREE_MODE=true` (default)** — the plan already names the parent worktree at `<repo-root>/.omp/worktrees/<repo>-<feature>/` (branch `feat/<feature>`). Run `setup-worktree.sh parent <repo> <feature>` once, then dispatch agents with `Working directory: <parent path>`.
- **`WORKTREE_MODE=false` (`--no-worktree`)** — derive `FEATURE_SLUG` from the user's request using the team-name sanitization (lowercase, non-`[a-z0-9-]` → `-`, collapse runs, truncate to 20 chars, fallback `untitled`), then run `prepare-feature-branch.sh`; it is idempotent on `feat/${FEATURE_SLUG}`, exits 1 on unrelated dirty tree, exits 2 on a different feature branch (`--allow-existing-feature-branch` after confirmation) or, when RELEASING.md exists, on `release/*` (`--allow-release-branch` only for a release-only fix). See `skill://ycc-shared/references/branch-prep.md`. Do not skip this step.

Then run standalone-dispatch sections 9–10: batches sequentially, one implementor per step in a single message; run type-check and unit tests between batches; on failure stop and ask the user.

This keeps everything in the current conversation — no file artifact needed.

For unattended loop-to-completion of a parallel plan, hand off to `/skill:implement-plan` and pair it with the `/goal` session directive — see that skill's `## /goal pairing` section for the recommended done condition (`ALL_BATCHES_DONE`, `FILES_CHANGED_NONEMPTY`, `LINT_PASS`) and the transcript-output contract.

**Option 2 — Save to file and hand off (rigorous)**

Resolve kind `prp-plan` for the feature slug through `skill://ycc-shared/scripts/resolve-artifact-store.sh` using the skill's three steps: print `--shell` and read `ARTIFACT_STORE`, apply the Linear call gate in linear mode, then `--ensure --kind=prp-plan --slug=<slug>`. Forward `${STORE_FLAG}` on every call. Prepare missing document/task identity via Lookup/Load before writing as required by artifact-store.md **Planning skills**, then Save (including task sub-issues). Write the resolved absolute `$OUT`, adapting to the PRP template when needed. Local mode keeps `docs/prps/plans/<slug>.plan.md` under the current checkout's git toplevel and retains move semantics; print `/skill:prp-implement --parallel {resolved absolute OUT path}` only in local mode. In linear mode print `/skill:prp-implement --parallel --store=linear {resolved cached plan path or Linear Document URL}` instead. Never move the linear cache.

Use Option 1 for small features and quick iterations. Use Option 2 when the user wants an implementation report, per-task validation logs, and the plan archived for audit.

## Comparison with other ycc planning tracks

| Track                  | When to use                                                                                                                                                                                                                                                               |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/skill:plan` (this one) | Quick conversational plan via `planner` agent. No artifact file. Add `--parallel` to shape the output for parallel execution (no research fan-out). Add `--enhanced` to widen to 5 personas (security + UX), dispatched as standalone parallel sub-agents by default. |
| `/skill:prp-plan`        | Artifact-producing plan with codebase pattern extraction. Single-pass. Add `--parallel` for 3-researcher fan-out + batched plan. Add `--enhanced` for the full 7-researcher fan-out.                                                                                      |
| `/skill:prp-prd`         | Interactive PRD first, then prp-plan. Problem-first hypothesis workflow.                                                                                                                                                                                                  |
| `/skill:plan-workflow`   | Heavyweight parallel-agent planning. Multi-task features. Artifact output.                                                                                                                                                                                                |
| `/skill:parallel-plan`   | Lower-level component of `/skill:plan-workflow` for dependency-aware plans.                                                                                                                                                                                                 |

### Which `--parallel` should I use?

- **`/skill:plan --parallel`** — You want a quick parallel-capable plan without creating an artifact file. Planner does its own research. Best for small/medium features.
- **`/skill:prp-plan --parallel`** — You want research fan-out (3 parallel researchers covering 8 categories) plus a full artifact file with patterns to mirror and validation commands. Best for medium/large features where you want a rigorous, auditable plan.
- **`/skill:plan-workflow`** — You want heavyweight team orchestration with shared context and multi-phase validation. Best for very large features spanning many tasks.

### When to use `--team`

`--team` is a **Claude Code-only** execution mode. Cursor, Codex and OMP bundles ship
without team tools (`SendMessage`, etc.), so invoking `--team`
there has no effect — use `--parallel` instead.

- **`/skill:plan --team`** — The task is complex enough that you want architect, risk, and testing perspectives but not heavy enough for an artifact file. Outputs a merged multi-perspective plan in the conversation.
- **`/skill:plan --parallel --team`** — Same as above, but the merged plan is also formatted for parallel implementation (Batches section, `Depends on` annotations).
- **`/skill:prp-plan --team`** — Team-coordinated research with shared `todo` for medium/large features that will produce an artifact file.
- **`/skill:prp-implement --team`** — Team-coordinated execution with shared `todo` across all batches. Best for implementation runs where you want coordinated inter-batch shutdown and a single shared task graph.

### When to use `--enhanced`

`--enhanced` widens the roster from 3 to **5** personas, adding `security-reviewer` and `ux-reviewer`. By default (no `--team`) it dispatches via **Path C** — 5 standalone parallel sub-agents — which works in every bundle (Claude Code, Cursor, Codex). Combine with `--team` (Claude Code only) for team-coordinated dispatch via **Path B enhanced**. Reach for `--enhanced` when the change has plausible security exposure (new endpoint, new input source, authn/authz touch, secret handling) or user-facing surface (new UI / CLI flag / API response shape / error path). Skip it for purely internal refactors where no new threat surface or user touchpoint is introduced.

- **`/skill:plan --enhanced <request>`** — Fans out 5 standalone parallel sub-agents (Path C). Works in every bundle. Best for medium-complexity features where a 3-persona plan would miss security or UX considerations and you don't need the team coordination overhead.
- **`/skill:plan --enhanced --team <request>`** — Same 5-persona roster but dispatched as a Claude Code agent team with shared `todo` and coordinated shutdown. Use when you want team observability across the 5 perspectives.
- **`/skill:plan --enhanced --parallel <request>`** — 5-persona plan formatted for parallel execution (Batches section, `Depends on` annotations).
- **`/skill:plan --enhanced --dry-run <request>`** — Print the 5-persona roster without spawning anyone. Useful to confirm the team shape before paying the dispatch cost.
- **`/skill:prp-plan --enhanced <request>`** — The heavier sibling: 7 researchers, artifact-producing. Use when you want the enhanced perspectives _and_ a saved plan file, not just an in-conversation plan.

### When to use `--no-worktree`

Worktree annotations are emitted by default. Pass `--no-worktree` to suppress the `## Worktree Setup` section and all per-task `**Worktree**:` annotations when you do not intend to use git worktree isolation:

- **`/skill:plan --parallel <request>`** — Parallel-capable plan with full worktree annotations (default). Hand off to `/skill:prp-implement` for isolated execution.
- **`/skill:plan --no-worktree --parallel <request>`** — Parallel-capable plan without worktree annotations. Use when worktree isolation is not desired.
- **`/skill:plan --parallel --team <request>`** — Multi-perspective plan formatted for both parallel execution and worktree isolation (default).
- **`/skill:plan --no-worktree --parallel --team <request>`** — Multi-perspective plan with parallel execution but no worktree annotations.
