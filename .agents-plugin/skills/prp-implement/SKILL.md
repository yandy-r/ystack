---
name: prp-implement
description: Executes PRP plan files with validation loops, reports, and archiving.
  Use when implementing a .plan.md file, executing a PRP plan, or running parallel
  PRP tasks.
allowed-tools:
- Read
- Grep
- Glob
- Write
- Edit
- Agent
- AskUserQuestion
- TaskCreate
- TaskGet
- TaskList
- TaskUpdate
- SendMessage
- Bash(ls:*)
- Bash(cat:*)
- Bash(test:*)
- Bash(mkdir:*)
- Bash(mv:*)
- Bash(git:*)
- Bash(npm:*)
- Bash(pnpm:*)
- Bash(yarn:*)
- Bash(bun:*)
- Bash(uv:*)
- Bash(python:*)
- Bash(python3:*)
- Bash(pytest:*)
- Bash(cargo:*)
- Bash(go:*)
- Bash(make:*)
- Bash(curl:*)
- Bash(~/.agents/ycc-shared/scripts/*.sh:*)
---

# PRP Implement

Execute a plan file step-by-step with continuous validation. Every change is verified immediately; never accumulate broken state. Detect the package manager, prepare the Git branch, execute tasks, validate static/unit/build/integration/edge cases, write `docs/prps/reports/`, and archive the plan (linear mode: see Phase 5). Detect parallel-capable plans and prompt for execution mode unless a flag selects it.

> Adapted from PRPs-agentic-eng by Wirasm. Part of the PRP workflow series.

## Gates

- If validation fails, fix it before moving on. Never accumulate broken state.
- Reject mutually exclusive flags and invalid team/dry-run combinations in Phase 0.
- `--team` requires a parallel-capable plan; never silently fall back.
- Prepare the feature branch before any agent dispatch. All execution and later artifacts use the single execution tree, not per-agent isolation.
- Dry-run prints the roster and exits without team/task/agent tools.
- Parallel validation failure stops the pipeline before the next batch. No auto-retry, no skipping a failed batch; preserve completed work and let the user decide.

**Questions:** class `choose-path` (execution mode for a parallel-capable plan): headless (no question tool or chat turn), run sequential (Path A); class `failure-recovery` (batch validation): stop, preserve completed work, and print the failing batch plus the resume command. See `~/.agents/ycc-shared/references/question-policy.md`.

## Phase 0 — DETECT

### Flag Parsing

Extract flags from `$ARGUMENTS` before treating the remainder as a plan path:

| Flag                    | Effect                                                                                                                                                                 |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--parallel`            | Force standalone parallel execution when the plan has `Batches`; skip the prompt. Otherwise warn and fall back to sequential. Works in Claude Code, Cursor, Codex.     |
| `--team`                | Claude Code only: force agent-team parallel execution with shared task-graph observability. Abort if no `Batches`.                                                     |
| `--worktree`            | Silent legacy no-op; isolation is on by default.                                                                                                                       |
| `--no-worktree`         | Force worktree mode off regardless of annotations; use the prepared current checkout.                                                                                  |
| `--dry-run`             | Only with `--team`: print team name, full task graph with dependencies, and per-batch roster, then exit without teammates.                                             |
| `--store=local\|linear` | Artifact store override; strip it, retain as `STORE_FLAG` (empty when absent), and forward it to every resolver call. See artifact-store.md **Implementation skills**. |

Set `PARALLEL_FLAG=true|false`, `AGENT_TEAM_FLAG=true|false`, `WORKTREE_MODE=true|false`, `DRY_RUN=true|false`. The remaining text is the plan input: a plan path, a cached linear plan path, or a Linear reference. `~/.agents/ycc-shared/references/artifact-store.md` **Implementation skills > Inputs** defines issue keys, references, linear plan paths and which of them select linear mode (an existing local plan path wins). If the input is a Linear reference or linear plan path and `STORE_FLAG` is empty, set `STORE_FLAG=--store=linear` before the first resolver call and forward it to every later call, per that contract.

Validation (abort with these exact messages):

- Both `--parallel` and `--team`: `--parallel and --team are mutually exclusive. Pick one.`
- `--team` without `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`: `--team requires CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1. Use --parallel instead, or set CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 in your Claude Code settings if you intentionally want agent-team dispatch.`
- `DRY_RUN=true` and `AGENT_TEAM_FLAG=false`: `--dry-run requires --team.`
- Both `--worktree` and `--no-worktree`: `--worktree and --no-worktree are mutually exclusive. Use --no-worktree to opt out of the default.`
- `--store=local` with a Linear reference or linear plan path: `A Linear plan reference requires linear mode; drop --store=local.`

`--no-worktree` combines freely with `--parallel` and `--team`. Cursor/Codex bundles lack team tools: reject `--team` with guidance to use `--parallel`.

### Package Manager and Validation Scripts

Read `references/detection.md` now for the lockfile/package-manager/runner table. Inspect `package.json` (or equivalent) and record available type-check, lint, test, build commands.

## Dispatch Contract

Read `~/.agents/ycc-shared/references/standalone-dispatch.md` for standalone dispatch and common preparation (§§8–9).
Read `~/.agents/ycc-shared/references/agent-team-dispatch.md` §8.2 only when `--team` is passed.

## Phase 1 — LOAD

Local mode: read the stripped plan path (`PLAN_PATH`) exactly as before; extract Summary, Patterns to Mirror, Files to Change, Step-by-Step Tasks, Validation Commands, Acceptance Criteria. Missing or invalid plan:

```
Error: Plan file not found or invalid.
Run /prp-plan <feature-description> to create a plan first.
```

Linear mode: follow artifact-store.md **Implementation skills > Resolve and hydrate** for kind `prp-plan` before branch preparation (`resolve-artifact-store.sh ${STORE_FLAG} --shell`, reading `ARTIFACT_STORE=`; Linear call gate; Lookup; Load); set `PLAN_PATH` to the absolute cache path and read its `tasks` map (rebuilt in memory when missing). If `DRY_RUN=true`, do not use `--ensure`, write the cache, or run Load's push/Conflict steps: reuse an existing cache file read-only, or fetch the body into a `mktemp` file outside the repository and use that as `PLAN_PATH`. A missing plan follows Lookup step 7 (ask, listing what was tried) — never report "not found" without querying Linear. Parse the selected file as above.
Read `references/detection.md` (Parallel-Capable Detection and Execution Mode Decision) now. A `## Batches` section makes the plan parallel-capable: parse its ordering and task `BATCH:` fields. Select sequential or parallel standalone execution; record `EXECUTION_MODE=sequential|parallel`.
With `--team`, select Path C and record `EXECUTION_MODE=agent_team`.

Apply the common worktree precedence/deduction in standalone-dispatch.md §8.1. Scan the plan's worktree annotations:

```bash
# grep -c prints the count itself; exit 1 only means zero matches, so
# exit codes 0 and 1 both leave exactly one integer on stdout. A status
# above 1 (unreadable/missing file) is a real error and makes the line fail.
grep -c "^## Worktree Setup" "$PLAN_PATH"; [ $? -le 1 ]
grep -c "^\- \*\*Worktree\*\*:" "$PLAN_PATH"; [ $? -le 1 ]
```

Local mode: with a parent annotation, use its path before whitespace/comment and slug segment after `<repo>-`. Otherwise derive `WT_FEATURE_SLUG` from plan basename: strip `.plan.md`, lowercase, replace `[^a-z0-9-]` with `-`, collapse runs, truncate to 40 chars. In linear mode derive `WT_FEATURE_SLUG` from the cache slug, never from the cache basename (`prp-plan.md`), using artifact-store.md **Resolve and hydrate** step 4: lowercase, replace `[^a-z0-9-]` with `-`, collapse runs, trim `-`, truncate to 40 characters, and fall back to `untitled` if empty. Keep the raw cache slug for every resolver `--slug=` call. `WORKTREE_ACTIVE` follows common mode selection; sequential tasks use the parent execution tree too.

**CHECKPOINT**: Plan loaded. All sections identified. Tasks extracted. Parallel capability detected. Execution mode chosen.

## Phase 2 — PREPARE

In linear mode with `DRY_RUN=true`, skip this entire phase: no branch preparation, worktree setup, artifact relocation, or remote sync. Continue to Phase 3's dry-run roster output with the read-only or temporary `PLAN_PATH` from Phase 1.

Follow standalone-dispatch.md §8.2 for Git-state inspection, required branch preparation, and one-time parent worktree setup. Local mode keeps the one-way plan relocation; linear mode skips `move-plan-to-worktree.sh` — the plan is not moved into the worktree and worktree tasks read the absolute cache `$PLAN_PATH`. In linear mode the cache is gitignored and the only expected dirty path is a `.gitignore` whose sole change adds the `.ycc/artifacts/` rule, which branch preparation accepts. Input plan is the stripped `$ARGUMENTS`; optional companion artifacts ride as extra move arguments (local only). Retain `$PLAN_PATH` as the canonical path for validation, prompts, report, and archive/completion. All subsequent git operations and writes run in `$WT_PARENT_PATH` when active; `--no-worktree` uses the prepared current checkout.

Sync remote after preparation in the execution tree:

```bash
git pull --rebase origin $(git branch --show-current) 2>/dev/null || true
```

**CHECKPOINT**: On correct branch. Working tree ready. Remote synced. Parent worktree created (if `WORKTREE_ACTIVE=true`).

## Phase 3 — EXECUTE

Branch on `EXECUTION_MODE` chosen in Phase 1. In linear mode, read `references/linear-sync.md` now and apply it (orchestrator only; `implementor` subagents never call Linear).

### Path A — Sequential Execution

Process each task from Step-by-Step Tasks in order:

1. Read the MIRROR reference source before writing code; understand the convention.
2. Implement following the pattern exactly, applying GOTCHA warnings and specified IMPORTS.
3. After every file change run the Phase 0 type-check. Fix errors before the next file.
4. Print `[done] Task N: [task name] — complete`.

### Parallel Batch Execution

For standalone parallel execution, use common batching from standalone-dispatch.md §9; the plan's `Batches` table and task `BATCH: BN` fields select tasks. Read `references/agent-task-prompt.md` once before dispatch for the full ACTION/IMPLEMENT/MIRROR/IMPORTS/GOTCHA/VALIDATE prompt and Patterns to Mirror excerpt.
Dispatch one `Agent` call per task in one parallel message: `subagent_type="implementor"`, `description="<task title>"`, `prompt="<complete task spec and Patterns to Mirror excerpt>"`. Use the shared foreground result contract for the batch.
Every prompt includes `Working directory: ${WT_PARENT_PATH}` when `WORKTREE_ACTIVE=true`, otherwise `Working directory: ${REPO_ROOT}`. Apply standalone-dispatch §8.3 working-directory rules; no per-agent worktree isolation.
With `--team`, use agent-team-dispatch.md §8.2 instead, with the same prompt and working directory.

Path C adapter: context = plan basename stripped of `.plan.md` (linear mode: the cache slug); team prefix `prpi-`, sanitization per team §1 (20-char context, fallback `untitled`); description `PRP-implement team for: <plan basename>` (linear mode: the cache slug). Full spec supplies registered task descriptions. At C.2, if `DRY_RUN=true`, print `references/dry-run.md` and exit without any team/task/agent tools; otherwise continue the team adapter. Registration, spawn, monitoring, shutdown, and cleanup follow agent-team-dispatch.md §8.2 only.

#### Between-Batch Validation (Levels 1 + 2)

After every batch, run Phase 0 type-check (zero errors) and affected-area unit tests (green) in the execution tree. If either fails, stop the parallel pipeline; report batch and type errors/test failures; do not dispatch the next batch.

Use `AskUserQuestion`: _"Batch {BN} validation failed. Choose: (1) fix manually and resume from batch {BN+1}, (2) switch to sequential mode for remaining batches, (3) abort."_ Apply the choice. No auto-retry or skipped failure. Preserve completed work. Fix/resume in the same feature worktree, without child branches to merge or clean up. Switching modes continues sequential execution for remaining batches.
With `--team`, cleanup on switch/abort/resume follows agent-team-dispatch.md §8.2.

After validation, print `[done] Batch BN: K tasks — complete (type-check + tests pass)`.

After all batches, proceed to Phase 4's full five levels; between-batch checks do not replace build, integration, or edge cases.

### Handling Deviations

Record what changed and why; continue with the corrected approach. Collect parallel/team implementors' deviations verbatim in the final report.

**CHECKPOINT**: All tasks executed. Deviations logged.

## Phase 4 — VALIDATE

Read `references/validation-and-failures.md` now. Run every level in order; fix issues at each level before proceeding:

1. Static analysis: zero type errors; lint auto-fix, then manual fixes if needed.
2. Unit tests: test every new function per Testing Strategy, at least one each; cover specified edge cases. Fix implementation, not the test unless the test is wrong.
3. Build: zero errors.
4. Integration if applicable: start server, bounded readiness check, run tests, stop server, preserve test exit code (exact shell template in reference).
5. Edge cases: run the plan's Testing Strategy checklist.

**CHECKPOINT**: All 5 validation levels pass. Zero errors.

## Phase 5 — REPORT

Read `references/report-output.md` now for report template, PRD update, archive/completion commands, and worktree section.

Local mode (unchanged):

1. Create `docs/prps/reports/{plan-name}-report.md`, including assessment vs reality, task status, all validation levels, changed files, verbatim deviations, issues, tests, next steps.
2. If a PRD phase: change `in-progress` to `complete`, add report path.
3. Archive canonical `$PLAN_PATH` to its sibling `completed/` inside the execution tree (fallback to stripped `$ARGUMENTS` under `--no-worktree`).
4. If `WORKTREE_ACTIVE=true`, capture `list-worktrees.sh` output after archive; include full table and cleanup commands under `## Worktree Summary` in the report.

Linear mode: resolve the report with `bash "${HOME}/.agents/ycc-shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --ensure --kind=prp-report --slug=<slug>` (`<slug>` = cache parent directory name), write it there, and complete per `references/linear-sync.md` instead of the archive move.

**CHECKPOINT**: Report created. PRD updated. Plan archived (local) or Linear completion applied (linear). Worktree summary captured (if applicable).

## Phase 6 — OUTPUT

Print the user-output template from `references/report-output.md`, including mode, validation, deviations, artifacts, conditional PRD progress/worktree summary, and all seven Goal Signals verbatim. Use `PASS` only when the matching criterion below holds; otherwise `FAIL`.

## Handling Failures

Read `references/validation-and-failures.md` when any type-check, test, lint, build, or integration check fails. Fix the source/root cause and re-run until clean before proceeding. Parallel pipeline failures additionally use Phase 3's user choice gate.

## Success Criteria

- **TASKS_COMPLETE**: All tasks from the plan executed.
- **TYPES_PASS**: Zero type errors.
- **LINT_PASS**: Zero lint errors.
- **TESTS_PASS**: All tests green, new tests written.
- **BUILD_PASS**: Build succeeds.
- **REPORT_CREATED**: Implementation report saved.
- **PLAN_ARCHIVED**: Local: plan moved to `docs/prps/plans/completed/`. Linear: parent tracking issue and every tracked task issue are `completed` (or `canceled`) and the Project status update was posted (see `references/linear-sync.md`).

## /goal pairing and Next Steps

Read `references/report-output.md` (Goal pairing) for the condition template; read `~/.agents/ycc-shared/references/goal-pairing.md` before relying on a `/goal` loop. Done conditions use printed signals, not file paths. Next: `/code-review`, `/prp-commit`, `/prp-pr`, or `/prp-plan <next-phase>`.

## References — read when

- `references/detection.md`: Phase 0 package manager/scripts and Phase 1 parallel detection/mode selection.
- `references/linear-sync.md`: linear-mode status sync, report Save, completion, and offline replay (Phase 3/5).
- `references/agent-task-prompt.md`: once before parallel implementor dispatch.
- `references/dry-run.md`: C.2 `--team --dry-run` output.
- `references/validation-and-failures.md`: Phase 4 validation and any failed check.
- `references/report-output.md`: Phase 5 report/PRD/archive, Phase 6 user output, or `/goal` condition.
