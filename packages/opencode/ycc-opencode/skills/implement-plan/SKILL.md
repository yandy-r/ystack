---
name: implement-plan
description: Executes parallel-plan.md with dependency-aware implementor batches.
  Use when implementing a planned feature, running parallel-plan tasks, or resuming
  a batched implementation.
---

# Parallel Plan Executor

> **OpenCode V2 compatibility:** `--team` is unsupported. If it is supplied, abort before setup or dispatch and ask the caller to rerun without it. This target uses native standalone `subagent` calls only.

Execute a parallel implementation plan by deploying implementor agents in dependency-resolved batches. This is Step 3 of the planning workflow, transforming the plan into working code. **Operational context:** require parallel-plan.md from parallel-plan. Worktree isolation is on by default: create or reuse one feature worktree on a feature branch; `--no-worktree` uses only the current-checkout feature branch, and `--worktree` is a legacy no-op. Standalone sub-agents are the default dispatch mode.


## Hard Gates

- `--worktree` and `--no-worktree` together → abort (exact message in Arguments).
- `--dry-run` → print the plan only; never dispatch agents or manage team state. STOP HERE. In linear mode it also makes no Linear or local writes (no `--ensure`, no cache write); see `references/linear-sync.md`.
- Always run the branch-prep helper before any dispatch — narrative-only branch instructions are how agents end up committing to `main`.
- Never pass `isolation: "worktree"` per agent — all agents in all batches share the one feature worktree (or the prepared checkout under `--no-worktree`).
- Standalone task failure: record it and continue only independent tasks. Team failure: no auto-retry or skipping; ask the user before advancing.

**Questions:** class `failure-recovery` (team batch failure); headless (no question tool or chat turn): stop, keep the feature worktree, and print the failing batch plus the resume command. See `{{package-root}}/shared/references/question-policy.md`.

## Workflow Integration

Final step of the planning workflow; requires `parallel-plan.md` from the parallel-plan skill.

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ shared-context  │ ──▶ │  parallel-plan  │ ──▶ │  implement-plan │
│  (Step 1)       │     │  (Step 2)       │     │  (this skill)   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
     Creates:                Creates:               Executes:
     shared.md              parallel-plan.md      parallel-plan.md
```

In local mode, if parallel-plan.md doesn't exist, run `/ycc:parallel-plan [feature-name]` first. In linear mode, use Phase 0 Lookup before concluding that a plan is missing.

## Arguments

**Target**: `$ARGUMENTS`

Parse flags first, then resolve the remaining feature name, plan path, or Linear reference using `references/plan-inputs.md`:

- `--worktree` — (legacy — now default; safe to omit) Accepted as a silent no-op. Worktree isolation is on by default; this flag matches the new default and has no additional effect.
- `--no-worktree` — Force worktree mode **OFF** regardless of plan annotations. Create/use `feat/<feature-name>` in the current checkout and run tasks there. No feature worktree is created.
- `--store=local|linear` — Artifact-store override; strip and retain as `STORE_FLAG` (empty when absent), forwarding it to every resolver call.
- `<feature-name | plan-path | Linear-reference>` — Existing feature name, cached plan path, or issue key/URL, Project URL/slug, or Document URL/id; see artifact-store.md **Implementation skills > Inputs**.

Strip the flags from `$ARGUMENTS` and set ``, `DRY_RUN=true|false`, `WORKTREE_MODE=true|false`, and `WORKTREE_FLAG_PRESENT=true|false`. Retain the remaining input; derive the feature slug during Phase 0.

**Validation**:

- `--worktree` and `--no-worktree` together → abort with: `--worktree and --no-worktree are mutually exclusive. Use --no-worktree to opt out of the default.`

If no input remains after stripping flags, abort with this usage line followed by the Examples in `references/plan-inputs.md`:

Usage: /ycc:implement-plan [--dry-run] [--worktree] [--no-worktree] <feature-name>


## Dispatch Lifecycle

Read `{{package-root}}/shared/references/standalone-dispatch.md` for standalone dispatch and common preparation (§§8–9).

## Phase 0: Prerequisites Check

### Step 1: Validate Prerequisites

First read `{{package-root}}/shared/references/artifact-store.md` **Implementation skills**, **Sync**, **Lookup**, and **Helper API**. Apply **Inputs** before resolution (it decides whether the input selects `--store=linear`, including the local-plan-wins and `--store=local` conflict rules). Resolve and print the store (default `local`), retaining the printed mode and absolute paths across tool calls:

```bash
bash "{{package-root}}/shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --shell
```

In linear mode, follow **Resolve and hydrate** (Lookup → Load `parallel-plan` and available `shared`) before prerequisites or branch preparation; retain absolute `PLAN_PATH` and `SHARED_PATH`. Follow `references/linear-sync.md` throughout this run. Local feature-name input keeps the existing prerequisite call:

```bash
{{package-root}}/skills/implement-plan/scripts/check-prerequisites.sh ${STORE_FLAG} [feature-name]
```

For linear mode, call the helper with `${STORE_FLAG} --plan="${PLAN_PATH}" <resolved-slug>`; `PLAN_PATH` must be the absolute hydrated cache path. An explicit local plan path uses `${STORE_FLAG} --plan="${PLAN_PATH}" <feature-name>` without changing its store; with no store flag, the local feature-name call above is unchanged.

If the script exits with error: display the error message and **STOP HERE** — do not proceed. In local mode, instruct the user to run `/ycc:parallel-plan` first; in linear mode, preserve Lookup's diagnostics rather than claiming no plan without querying Linear.

### Step 2: Read Planning Documents

1. Local: `docs/plans/[feature-name]/parallel-plan.md` (or explicit plan path); linear: absolute `PLAN_PATH` — the implementation plan
2. Local: companion `shared.md`; linear: hydrated `SHARED_PATH` when available — architecture context

Also read files listed in the "Critically Relevant Files" section of parallel-plan.md.

## Phase 1: Parse Plan & Build Dependency Graph

### Step 3: Extract Tasks

For local inputs, set absolute `PLAN_PATH` and companion `SHARED_PATH` from the resolved plan directory (refresh both after worktree relocation); linear mode keeps the absolute cache paths. Run when building the execution graph (Phase 1 task extraction):

```bash
{{package-root}}/skills/implement-plan/scripts/parse-dependencies.sh "${PLAN_PATH}"
```

The script emits optional header lines (`WT_PARENT_PATH=<path>`, `WT_FEATURE_SLUG=<slug>` — present only when the plan has a `## Worktree Setup` section) followed by per-task rows (`TASK_ID|TASK_TITLE|DEPENDENCIES`). Row fields and the monorepo `.plans-config` behavior are documented in `references/plan-inputs.md`.
Parse task specifications from the body, not identity frontmatter.

### How Worktree Mode Is Decided

Use standalone-dispatch.md §8.1 for precedence and variables in both modes. Skill input: `WT_FEATURE_SLUG` is the parsed annotation slug if present, otherwise the resolved feature slug (the feature-name argument in local mode; no extra sanitization/cap). Always derive `WT_REPO_NAME` and `FEATURE_BRANCH`; `--no-worktree` sets `WORKTREE_ACTIVE=false` even when parser headers exist.

### Step 4: Build Dependency Graph

Build the independent-vs-dependent graph using standalone-dispatch.md §9; example in `references/plan-inputs.md` (Dependency graph). Keep the graph for standalone batch ordering.



## Phase 2: Create Task List

### Step 5: Register Tasks

Use `track the task` for each plan item with `subject="[Task ID] [Task Title]"` and
`description="<full specification and dependencies>"`. Capture the returned task IDs;
wire dependencies via `update the todo tracker` with `addBlockedBy` using those IDs. See
`references/plan-inputs.md` (Task list format).
In linear mode, reconcile mapped task issues before registration per `references/linear-sync.md`; completed/canceled tasks are skipped, not dispatched, and completed prerequisites count as satisfied.

### Step 6: Identify First Batch

All tasks with `Depends on [none]` form the first batch; mark them ready for execution.

## Phase 2.5: PREPARE — Branch / Worktree Setup

### Steps 6.5–6.7

Use standalone-dispatch.md §8.2 in both dispatch modes for Git inspection, required branch preparation and one-time parent setup. **Local mode:** expected dirty artifacts: `docs/plans/${WT_FEATURE_SLUG}/` only; unrelated dirty files stop and require user cleanup. Move `docs/plans/${WT_FEATURE_SLUG}/parallel-plan.md` with `docs/plans/${WT_FEATURE_SLUG}/shared.md` as companion; other research artifacts from the same feature directory may ride as extra arguments. Keep returned `$PLAN_PATH` canonical; later validation/reports use the execution tree. **Linear mode:** skip `move-plan-to-worktree.sh` and all artifact relocation; keep absolute cache paths from Phase 0 for worktree prompts and plan validation. The cache is gitignored; the only expected dirty path is a `.gitignore` whose sole change adds the `.ycc/artifacts/` rule, which branch preparation accepts. Branch-prep exit contract: `{{package-root}}/shared/references/branch-prep.md`.

## Phase 3: Execute in Batches

### Step 7: Dry Run Gate

If `--dry-run` is present, read `references/output-formats.md` (Dry-run formats), print the default batch roster, and do not dispatch any agents.
**STOP HERE** after either dry-run output.

After this gate, linear mode runs the start transitions and pending replay in `references/linear-sync.md` before dispatch.

### Step 8: Execute standalone batches

Execute the dependency-ready standalone batches described below.


### Path A — Standalone Sub-Agent Batches (default)

Read `{{package-root}}/shared/references/standalone-dispatch.md` before the
first batch. Dispatch every implementor through OpenCode V2's native foreground
tool call:

```text
subagent(agent="implementor", description="Implement [Task ID]: [Title]",
         prompt="<complete task prompt>", background=false)
```

Omit `sessionID` for a new child. Issue independent calls in one parallel tool
batch, with one call per ready task. Explicit `background=false` is required
because the next dependency batch needs each report. Do not use a resumed child
as a result lookup; a call carrying `sessionID` performs more work.

Each prompt must include the task's exact file ownership, working directory,
implementation requirements, validation commands, and final `STATUS:` format.

**When `WORKTREE_ACTIVE=true`**, every task prompt (parallel and sequential) carries the lines below; when `WORKTREE_ACTIVE=false` (`--no-worktree`) use `Working directory: ${REPO_ROOT}` and `All parallel agents in this batch share the current feature branch; batching guarantees no two agents touch the same file.` Never pass `isolation: "worktree"`. Agents read the plan, shared context and "READ THESE BEFORE TASK" files first, implement only assigned files/instructions, lint and compile/parse modified files, then report files created/modified and issues.

```
Working directory: ${WT_PARENT_PATH}
All parallel agents in this batch share this path; batching guarantees no two agents touch the same file.
```

Implementor prompt template: `references/agent-task-prompt.md` — read once before the loop for the full task prompt.
For both paths, apply `references/linear-sync.md` before each batch and after its orchestrator validation; implementors never sync Linear or edit plan identity.

#### Process Batch Results (Path A)

After each foreground batch returns:

1. Validate every nonempty report and require its final `STATUS:` line.
2. Inspect the working tree and every declared artifact independently. A host
   `succeeded` or `completed` state does not verify the deliverables.
3. Run the focused checks required for the files owned by that task.
4. If a completion has no report, mark it incomplete, record the child
   `sessionID`, and inspect the working tree before retrying because edits may
   already exist. Preserve valid edits and make at most one retry.
5. Mark the task complete only after its report, on-disk work, and checks agree.
   Keep failed tasks visible and continue only independent work.
6. Print `[done] Batch BN: K tasks — complete` only after every accepted task in
   the batch passes those checks.

#### Repeat Until Complete (Path A)

Repeat from the ready-task selection until no tasks remain, then Phase 4.

## Phase 4: Final Verification & Summary

### Step 9: Verify Implementation

1. Run linting on all modified files and print the outcome to the transcript (zero errors, or the list of errors) — `LINT_PASS` is derived from this printed outcome; the `/goal` evaluator only reads transcript text.
2. Verify all "Files to Create" exist.
3. Sanity-check the modifications.

In linear mode, write kind `report` and Save its Project status update, then apply parent/Project completion via `references/linear-sync.md`; local mode retains its existing report behavior and makes no Linear calls.

### Step 10: Display Summary

When `WORKTREE_ACTIVE=true`, first capture: `bash {{package-root}}/shared/scripts/list-worktrees.sh "${WT_REPO_NAME}" "${WT_FEATURE_SLUG}"`.

Print the completion summary from `references/output-formats.md` (Completion summary), including the `## Worktree Status` section only when `WORKTREE_ACTIVE=true` and the Goal Signals block verbatim as the last lines. Use `PASS` only when the matching `## Success Criteria` criterion is met; otherwise `FAIL` (e.g. `FILES_CHANGED_NONEMPTY: FAIL` when the "Files Changed" section enumerated no files).

## Quality Standards



The implementation must: complete all tasks in the plan, respect dependency ordering, maximize parallel execution, and report failures clearly.

## Monorepo Support

Local-mode plans are read from the git repository root in `docs/plans/` by default; running from any subdirectory still reads from the root. A `.plans-config` at repo root (`plans_dir: docs/plans`) customizes the directory; with `scope: local` in a package-level `.plans-config`, plans are read from that package's local `docs/plans/`. Linear mode resolves under `.ycc/artifacts/<slug>/` in the invoking checkout and passes absolute cache paths to worktree agents. Structure example in `references/plan-inputs.md` (Monorepo Support).

## Success Criteria

- **ALL_BATCHES_DONE**: every batch printed `[done] Batch BN: K tasks — complete` and no batch was left unprocessed.
- **FILES_CHANGED_NONEMPTY**: the Step 10 "Files Changed" section enumerates at least one created or modified file.
- **LINT_PASS**: Step 9 linting printed zero errors across all modified files.

## /goal pairing

Pair with the `/goal` session directive to loop the batch executor to completion without re-prompting between batches. The condition template and the shared transcript-output caveats are in `references/output-formats.md` (Goal pairing); the cross-skill contract lives at `{{package-root}}/shared/references/goal-pairing.md` — read it before relying on a `/goal` loop.

## References

- `references/plan-inputs.md` — read when parsing tasks, building the dependency graph, registering tasks, showing usage, or resolving the monorepo plans directory.
- `references/agent-task-prompt.md` — read once before dispatching implementor agents.
- `references/output-formats.md` — read when printing `--dry-run` output or the Phase 4 completion summary, or writing a `/goal` condition.
- `references/linear-sync.md` — orchestrator-only Linear lifecycle hooks; canonical behavior lives in artifact-store.md.
