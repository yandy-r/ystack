---
name: plan-workflow
description: Use when validating existing research docs before planning, running a
  research-to-plan workflow, or producing shared.md and parallel-plan.md. Researches
  and validates plans with checkpoints.
argument-hint: '[--team] [--research-only] [--plan-only] [--no-checkpoint] [--optimized]
  [--dry-run] [--no-worktree] [--visual] [--store=local|linear] [feature-name]'
---

# Unified Planning Workflow

One command to research, analyze, and plan feature implementation. Default dispatch is standalone parallel sub-agents via `task`; `--team` (Claude Code only) runs stages as teammates under the implicit session team with `todo`, `SendMessage` coordination, and coordinated shutdown. Combines `shared-context` + `parallel-plan` with checkpoints.

Flow: Research → Checkpoint → Analysis → Plan Generation → Validation → optional `--visual`.

## Dispatch lifecycle (applies to every agent-spawning step below)

Read `skill://ycc-shared/references/standalone-dispatch.md` for standalone dispatch.
Read `skill://ycc-shared/references/agent-team-dispatch.md` only when `--team` is present. Never mix the two lifecycles in one run.

## Critical gates (read first)

1. **Mutual exclusion — abort before any write**: if both `--research-only` and `--plan-only` are present, print and **STOP** (no directory creation, no file writes):

   ```
   Error: --research-only and --plan-only are mutually exclusive
   Usage: /plan-workflow [--team] [--research-only | --plan-only] [--no-checkpoint] [--optimized] [--dry-run] [--no-worktree] [--visual] [--store=local|linear] [feature-name]
   ```

2. **Feature name required**: kebab-case (lowercase, hyphens), no other special characters. If missing or invalid, abort with the matching error block from `references/checkpoint-messages.md` ("Error Messages": Missing Feature Name / Invalid Feature Name).
3. **Team opt-in env gate**: `--team` without `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` aborts with: `--team requires CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1. Omit --team for standalone dispatch, or set CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 in your Claude Code settings if you intentionally want agent-team dispatch.` Cursor, Codex and OMP bundles ship without team tools — never pass `--team` there.
4. **Dry-run writes nothing**: handled before the prereq gate, overwrite prompt, any `mkdir`, write, dispatch, or rendering. Never prompts for input. It prints the preview and then **STOP**s.
   With `--team`, that dry-run additionally makes no `todo`/`task`/`SendMessage` calls.
5. **`--plan-only` prerequisite gate (before any `mkdir` or write)**: `scripts/check-prerequisites.sh` must exit 0. On failure, print its output plus `run /skill:shared-context <feature> or /skill:plan-workflow <feature> --research-only first`, then **STOP**. Never fall back to running research inline under `--plan-only`.
6. **`--optimized --plan-only` restriction**: the five unified analysis files must already exist (prior `--optimized` full run); there is no Phase 5 to regenerate them. If any is missing, **STOP** with: `--optimized --plan-only needs a prior --optimized full run. Run /skill:plan-workflow <feature> --optimized first.` Enforced at Step 4B, re-checked by the Phase 7 PRE-CHECK.
7. **Pre-generation gate (Step 22, cannot be skipped)**: `scripts/persist-or-fail.sh` must exit 0 before plan generation. On `MISSING_FILES`/`ACTION_REQUIRED`, re-dispatch the failing agent to write the missing file(s) and re-run until exit 0. The orchestrator must never write agent output files itself from captured summaries — that bypasses the contract (root cause of the May 2026 reproducer with 3 of 5 unified files missing).
8. **Validator flags**: `validate-research-artifacts.sh` (Step 11), `validate-analysis-artifacts.sh` (Step 21), and `persist-or-fail.sh` (Step 22) must be invoked with `--optimized` whenever `--optimized` was passed; without it they look for the standard file sets and fail wrongly.
9. **Validation-fail fix loop**: message the failing teammate (team mode) or re-dispatch the failing sub-agent via `task` (standalone). Wait, re-validate until pass. Never synthesize the missing file.
10. **Teammate cleanup**: in team mode, always send shutdown requests to every active teammate before skill completion (including the research-only stop and checkpoint-stop paths).
11. **Terminal STOP points**: dry-run preview (Step 4A), missing prereq (Step 4B), research-only stop (Step 15A), checkpoint "Stop here" (Step 16), `--optimized --plan-only` missing artifacts. At each, stop all writes and dispatch.

## Arguments

Parse flags first, then the feature name (first non-flag argument, required; artifact feature slug).

- **--team**: (Claude Code only) teammates under the implicit session team with `todo`. Default: standalone parallel sub-agents via `task`.
- **--research-only**: stop after research (creates shared.md only).
- **--plan-only**: skip research, use existing shared.md. Skips Phases 1–4, NOT Phase 5 (Analysis).
- **--no-checkpoint**: no pause between research and planning.
- **--optimized**: 7-agent unified deployment (default: 10-agent standard).
- **--dry-run**: show execution plan without running. With `--team`, also prints team name and teammate roster.
- **--worktree**: legacy no-op (worktree annotations are the default; safe to omit).
- **--no-worktree**: opt out of worktree annotations in the generated `parallel-plan.md`. No effect with `--research-only` (no plan file). Honored with `--plan-only`.
- **--store=local|linear**: optional artifact-store override. Forward it to every artifact-store helper call. Local is the default; linear is opt-in.
- **--visual**: render the finished plan as an Agent-Native visual artifact (MDX) via `/skill:visual-plan`; local files by default, hosted link requires `--share`.

If no feature name is provided, abort with the full usage instructions from `references/checkpoint-messages.md` — read when the feature name is missing ("Usage Instructions" section).

**Questions:** class `checkpoint` (Step 16 research review): headless (no question tool or chat turn), continue to planning and report the skipped checkpoint in the summary. Class `confirm-destructive` (Step 4C overwrite choice): headless, overwrite nothing; stop with `rerun with --no-checkpoint` to regenerate. See `skill://ycc-shared/references/question-policy.md`.

## Visual mode

See `skill://ycc-shared/references/visual-mode.md` for the canonical `--visual` contract. It is a terminal decorator, orthogonal to `--optimized` and `--no-worktree`; run it once at the end. With `VISUAL_MODE=true` and no `--dry-run`, invoke `/skill:visual-plan ${STORE_FLAG} <absolute-plan-path>` with the actual written `${parallel_plan_file}` and the retained store override. Dry runs print `visual generation would run` without invoking it. `--research-only` produces no plan and skips visualization.

## Phase 0: Initialize

### Step 1: Parse Arguments

Set `AGENT_TEAM_MODE=true` if `--team`; set each of `RESEARCH_ONLY` / `PLAN_ONLY` / `NO_CHECKPOINT` / `OPTIMIZED` / `DRY_RUN` from its flag. `VISUAL_MODE` and `WORKTREE_MODE`:

```bash
# Default ON; pass --no-worktree to opt out. --worktree accepted as legacy no-op.
WORKTREE_MODE=true
case " $ARGUMENTS " in
  *" --no-worktree "*) WORKTREE_MODE=false ;;
esac
ARGUMENTS="${ARGUMENTS//--no-worktree/}"
ARGUMENTS="${ARGUMENTS//--worktree/}"  # legacy no-op

VISUAL_MODE=false
case " $ARGUMENTS " in
  *" --visual "*) VISUAL_MODE=true ;;
esac
ARGUMENTS="${ARGUMENTS//--visual/}"
```

Apply critical gates 1–3. **feature-name** = first non-flag argument.

Parse and strip `--store=local|linear` before selecting the feature name. Set `STORE_FLAG` to the exact override when supplied, otherwise empty; reject invalid/conflicting overrides. Append it to every resolver invocation and visual-plan call below.

### Step 2: Resolve Artifact Paths

1. Print the mode and read `ARTIFACT_STORE=` from stdout; resolve paths without writes:

   ```bash
   bash "skill://ycc-shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --shell
   feature_dir="$(bash "skill://ycc-shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --kind=feature-dir --slug="[feature-name]")"
   research_dir="$(bash "skill://ycc-shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --kind=research-dir --slug="[feature-name]")"
   shared_file="$(bash "skill://ycc-shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --kind=shared --slug="[feature-name]")"
   parallel_plan_file="$(bash "skill://ycc-shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --kind=parallel-plan --slug="[feature-name]")"
   ```

2. For a non-dry linear run only, apply the **Linear call gate** in `skill://ycc-shared/references/artifact-store.md` before any write or pull.
3. Before Lookup/Load in that linear run, ensure the cache and gitignore rule:

   ```bash
   feature_dir="$(bash "skill://ycc-shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --ensure --kind=feature-dir --slug="[feature-name]")"
   ```

Then use Lookup/Load to populate missing cached inputs before state detection. For each document that will be written (research, shared, plan), if document identity is missing (or the plan has no task identity), follow **Planning skills** Lookup steps 3–6 and Load any hit before dispatch or writing; preserve identity and resolve Conflict on replacement. Local mode keeps `PLANS_DIR/<feature>/`; linear mode uses `.ycc/artifacts/<feature>/` with research in `research/`. Dry runs only resolve paths, never ensure or Load. Retain the printed mode and absolute paths across tool calls. See "Monorepo Support" below.

### Step 3: Run State Detection

```bash
skill://plan-workflow/scripts/check-state.sh "[feature-name]" ${STORE_FLAG}
```

Set `STORE_FLAG=--store=local` or `--store=linear` only when that override was supplied; otherwise leave it empty so config/default resolution applies. Forward the same override to `check-prerequisites.sh` and to every path-taking validator below. Validators receive the resolved absolute artifact paths already shown.

Reports whether `${feature_dir}/` exists, `shared.md`, `parallel-plan.md`, and any research files.

### Step 4: Determine Execution Mode

| State                | --plan-only | --research-only | Action                                                                                              |
| -------------------- | ----------- | --------------- | --------------------------------------------------------------------------------------------------- |
| No shared.md         | No          | No              | Full workflow from Phase 1                                                                          |
| No shared.md         | No          | Yes             | Full workflow from Phase 1, stop at Step 15A (research-only stop)                                   |
| No shared.md         | Yes         | No              | Fail fast in Step 4B — never fall back to research                                                  |
| Has shared.md        | Yes         | No              | Skip to Phase 5 (Analysis)                                                                          |
| Has shared.md        | No          | Yes             | Regenerate only if overwrite chosen in Step 4C, then stop at Step 15A; else STOP and reuse existing |
| Has shared.md        | No          | No              | Full workflow from Phase 1 (shared.md regenerates only if overwrite chosen in Step 4C)              |
| Has parallel-plan.md | Any         | Any             | Warn about overwrite (Step 4C)                                                                      |

"Planning" = Phase 8 (Plan Generation); "Analysis" = Phase 5.

### Step 4A: Dry-Run Preview (when `--dry-run`, before anything else)

Read `references/checkpoint-messages.md` — read when previewing a dry run. Display its "Dry Run Output" section with values substituted (`{{FEATURE_NAME}}`, `{{FEATURE_DIR}}`, `{{RESEARCH_DIR}}`, dispatch mode, execution mode), then **STOP** (gate 4). If `--plan-only` is also set and `check-state.sh` shows no `shared.md`, state in the preview that a real run would fail fast at Step 4B unless a linear Lookup populates the cache from an existing shared document, and **STOP**.

### Step 4B: Plan-Only Prerequisite Gate (when `--plan-only`, before any write)

Run `scripts/check-prerequisites.sh "[feature-name]" ${STORE_FLAG}` per gate 5. Then, for `--optimized --plan-only`, verify the five unified files exist before any write or dispatch (gate 6): `analysis-architecture.md`, `analysis-patterns.md`, `analysis-integration.md`, `analysis-docs.md`, `analysis-tasks.md`.

### Step 4C: Overwrite Choice (when shared.md or parallel-plan.md exists)

- **Interactive (checkpoint enabled)**: surface the matching warning from `references/checkpoint-messages.md` ("Existing State Warnings") and let the user choose regenerate vs reuse/stop.
- **Non-interactive (`--no-checkpoint`)**: default is **regenerate (overwrite)** so pipelines stay non-blocking; passing the flag is the explicit opt-in. State the choice when proceeding (e.g. "shared.md exists — regenerating (non-interactive default)").
- **Headless (no question tool or chat turn), checkpoint enabled**: do not overwrite. Print the existing paths and `rerun with --no-checkpoint` to regenerate, then **STOP** without writes or dispatch.
- **Research-only reuse**: report the existing `shared.md` path, state that no files were changed, print `/skill:parallel-plan <feature>` as the next step, and **STOP** without dispatching agents.

### Step 5: Create Directories

Only when `--dry-run` is not set: in linear mode apply the Linear call gate from artifact-store.md before `--ensure`, then run:

```bash
feature_dir="$(bash "skill://ycc-shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --ensure --kind=feature-dir --slug="[feature-name]")"
research_dir="$(bash "skill://ycc-shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --kind=research-dir --slug="[feature-name]")"
mkdir -p "$feature_dir" "$research_dir"
```

Local `--ensure` creates only the resolved feature directory; the `mkdir` also prepares research. In linear mode `research_dir` is `${feature_dir}/research`; in local mode it equals `feature_dir`.

## Phase 1: Research Stage (unless --plan-only)

### Step 7: Team Setup (if `--team`)

Follow the lifecycle in `agent-team-dispatch.md`. Create the team for the entire workflow:

```
Use the implicit session team: requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. Display run label: `pw-[feature-name]`.
```

If the flag is absent, abort with guidance to use `--parallel`. Do NOT silently fall back to sub-agent mode.

### Step 8: Read Research Prompts

- Standard mode: read `skill://plan-workflow/references/research-agents.md` — read when spawning Phase 1 research agents in standard mode.
- Optimized mode: read `skill://plan-workflow/references/research-agents-optimized.md` — read when `--optimized` replaces the 4 researchers with 5 unified analysts.

Substitute `{{FEATURE_NAME}}` (feature directory name), `{{FEATURE_DIR}}` (`${feature_dir}`), and every `{{RESEARCH_<LENS>_FILE}}` or `{{ANALYSIS_<NAME>_FILE}}` with its absolute path from the executed resolver (`research-<lens>` or `analysis-<name>` kind), using the same store override as Step 2 and no `--ensure` (Step 5 already created their parent). Analysis artifacts remain local-only in linear mode.

### Step 9: Create Research Tasks (if `--team`)

Create 4 tasks in the shared task list: "Research architecture for [feature-name]", "Research patterns for [feature-name]", "Research integrations for [feature-name]", "Research documentation for [feature-name]". If `todo` fails for any task, shut down any spawned teammates and abort.

### Step 10: Spawn Research Agents (standard mode)

Read `references/research-agents.md`. **CRITICAL**: Deploy all 4 research agents in a **SINGLE message** with **MULTIPLE `task` tool calls**. Standalone dispatch. Each `task` call uses the `agent` and `model` from the inline table below; full prompts live in `references/research-agents.md`.

| Name                      | Subagent Type               | Output File                | Model  | Focus                                    |
| ------------------------- | --------------------------- | -------------------------- | ------ | ---------------------------------------- |
| `architecture-researcher` | `codebase-research-analyst` | `research-architecture.md` | sonnet | System structure, components, data flow  |
| `patterns-researcher`     | `codebase-research-analyst` | `research-patterns.md`     | sonnet | Existing patterns, conventions, examples |
| `integration-researcher`  | `codebase-research-analyst` | `research-integration.md`  | sonnet | APIs, databases, external systems        |
| `docs-researcher`         | `codebase-research-analyst` | `research-docs.md`         | sonnet | Relevant documentation files             |

Pass `model: "sonnet"` for all research agents; each writes its resolved `research-<lens>` path (under `${research_dir}`). In `--optimized`, spawn the 5 unified agents from `references/research-agents-optimized.md` instead (see "Optimized Mode" below). Standalone dispatch follows the shared contract.
With `--team`, spawn the teammates registered in Step 9 in one message and confirm all are `completed` via `todo` before Step 11; do not re-create tasks.

## Phase 2: Validate Research Artifacts

### Step 11: Validate Research Artifacts

- **Path A (standalone, default)**: rely on `task` return values; each sub-agent writes its `research-*.md` (or, in `--optimized`, `analysis-*.md`) artifact before returning.
- **Path B (team)**: check via `todo` that all 4 research tasks are `completed`.

```bash
# Standard mode (4-file research-*.md set):
skill://plan-workflow/scripts/validate-research-artifacts.sh "${feature_dir}" ${STORE_FLAG}

# Optimized mode (5-file unified analysis-*.md set):
skill://plan-workflow/scripts/validate-research-artifacts.sh "${feature_dir}" --optimized ${STORE_FLAG}
```

Append `--optimized` whenever the flag was passed (gate 8). On failure, apply the fix loop (gate 9). Do not proceed to shared.md synthesis until validation passes.

In linear mode, after validation and fixes, follow artifact-store.md section **Planning skills** to Save each standard `research-<lens>` document. Optimized `analysis-*` files stay local-only and are never pushed.

### Step 12: Shut Down Research Teammates (if `--team`)

Send `SendMessage` `message={type: "shutdown_request"}` to each research teammate. Standalone sub-agents return on their own.

## Phase 3: Consolidate Research

### Step 13: Read Research Results

After validation passes, read the input set for the active mode:

- **Standard (4 files)**: `${research_dir}/research-architecture.md`, `research-patterns.md`, `research-integration.md`, `research-docs.md`.
- **Optimized (5 unified files; no `research-*.md` exist)**: `${feature_dir}/analysis-architecture.md`, `analysis-patterns.md`, `analysis-integration.md`, `analysis-docs.md`, `analysis-tasks.md`.

### Step 14: Generate shared.md

Read `skill://plan-workflow/references/shared-structure.md` — read when writing `shared.md`. Create `${shared_file}` following the template exactly.

### Step 15: Validate shared.md

```bash
skill://plan-workflow/scripts/validate-shared.sh "${shared_file}" ${STORE_FLAG}
```

Fix any errors before proceeding.

In linear mode, follow artifact-store.md section **Planning skills** to Save the validated `shared` document before continuing. When replacing an existing shared file, preserve its identity frontmatter and replace only the body as required by Save. Local mode writes the body without frontmatter and makes no Linear calls.

### Step 15A: Research-Only Stop (if `--research-only`)

Once `shared.md` exists and `validate-shared.sh` passed: skip Phases 4–9.5 entirely. Then:

1. Standalone research needs no teardown; proceed directly to the research-only summary.
   With `--team`, shut down remaining teammates via `SendMessage` (same cleanup as Step 33).
2. Print the research-only summary: use "Research Complete Summary" from `references/checkpoint-messages.md` — read when emitting the research-only summary (standard or optimized variant), listing the artifacts this run created (standard: `research-*.md` ×4 + `shared.md`; optimized: the five unified `analysis-*.md` + `shared.md`) plus dispatch mode.
3. Next step line: `/skill:parallel-plan <feature>` or `/skill:plan-workflow <feature> --plan-only`.
4. **STOP** — no further writes or dispatch.

## Phase 4: Checkpoint (unless --no-checkpoint or --research-only)

### Step 16: Pause for User Review

Use **`ask`**. Question: "Research complete for [feature-name]. Review the shared context before planning?" Options:

1. **Continue to planning** — proceed to Phase 5.
2. **Review shared.md first** — display `${shared_file}`, then re-prompt with the same question.
3. **Stop here** — display the research-phase completion summary and end the workflow. **STOP** — do not proceed to planning.
   With `--team`, shut down remaining teammates via `SendMessage` before this stop.

Format from `references/checkpoint-messages.md` — read when prompting at the checkpoint ("Checkpoint Question (Phase 2)").

## Phase 5: Analysis Stage (unless --research-only or --optimized)

This phase must run in standard mode, including under `--plan-only` (which skips Research, not Analysis): it produces the `analysis-*.md` files Phase 8 requires.

### Step 17: Create Team (if `--team` and --plan-only)

If running in `--plan-only` mode, verify `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is set before dispatching teammates.

### Step 18: Read Analysis Prompts

Read `skill://plan-workflow/references/planning-agents.md` — read when spawning Phase 5 analysis agents (standard mode). Substitute `{{FEATURE_NAME}}`, `{{FEATURE_DIR}}`, `{{RESEARCH_DIR}}` (`${research_dir}`), and the three `{{ANALYSIS_<NAME>_FILE}}` paths resolved without `--ensure` using kinds `analysis-context`, `analysis-code`, and `analysis-tasks` with the same store override.

### Step 19: Create Analysis Tasks (if `--team`)

Create 3 tasks: "Synthesize planning context for [feature-name]", "Analyze code patterns for [feature-name]", "Suggest task structure for [feature-name]".

### Step 20: Spawn Analysis Agents

**CRITICAL**: Deploy all 3 analysis agents in a **SINGLE message** with **MULTIPLE `task` tool calls**. Each `task` call uses the `agent` and `model` from the inline table below; full prompts live in `references/planning-agents.md`.

Team mode instead spawns 3 (standard) or 5 (optimized) teammates in one message with `name=`, per Step 19.

| Name                  | Subagent Type               | Output File           | Model  | Focus                  |
| --------------------- | --------------------------- | --------------------- | ------ | ---------------------- |
| `context-synthesizer` | `codebase-research-analyst` | `analysis-context.md` | sonnet | Condense planning docs |
| `code-analyzer`       | `codebase-research-analyst` | `analysis-code.md`    | sonnet | Extract code patterns  |
| `task-structurer`     | `codebase-research-analyst` | `analysis-tasks.md`   | sonnet | Suggest task breakdown |

Pass `model: "sonnet"`; each writes its resolved `analysis-<name>` path under `${feature_dir}`. Standalone dispatch follows the shared contract.
With `--team`, spawn the tasks registered in Step 19 in one message and confirm `completed` via `todo`.

## Phase 6: Validate and Persist Analysis Artifacts

### Step 21: First Validation Check

- **Path A (standalone, default)**: rely on `task` return values; each sub-agent writes its `analysis-*.md` artifact before returning.
- **Path B (team)**: `todo` shows all 3 (standard) or 5 (optimized) analysis tasks `completed`. Then:

```bash
# Standard mode (3-file set: analysis-context, analysis-code, analysis-tasks):
skill://plan-workflow/scripts/validate-analysis-artifacts.sh "${feature_dir}" ${STORE_FLAG}

# Optimized mode (5-file unified set):
skill://plan-workflow/scripts/validate-analysis-artifacts.sh "${feature_dir}" --optimized ${STORE_FLAG}
```

Pass → Step 22. Fail → fix loop (gate 9), re-validate.

### Step 22: Pre-Generation Gate (cannot be skipped)

```bash
# Standard mode:
skill://plan-workflow/scripts/persist-or-fail.sh "${feature_dir}" ${STORE_FLAG}

# Optimized mode:
skill://plan-workflow/scripts/persist-or-fail.sh "${feature_dir}" --optimized ${STORE_FLAG}
```

Exit 0 → Phase 7. Exit 1 → prints `MISSING_FILES` and `ACTION_REQUIRED`; re-dispatch the failing agent, re-run until exit 0 (gate 7). In optimized mode the `MISSING_FILES` set is the 5 unified files.

### Step 23: Shut Down Analysis Teammates (if `--team`)

Send shutdown requests to all analysis teammates.

## Phase 7: Read Analysis Results

**PRE-CHECK — branch on execution mode**:

- **Standard**: if `analysis-context.md`, `analysis-code.md`, or `analysis-tasks.md` is missing in `${feature_dir}/`, Phase 5 was skipped in error — go back and run Phase 5 now.
- **Optimized**: the five unified files must exist (produced by Phase 1 unified agents, gated by Step 22). If any is missing, **STOP** with the gate-6 message. Optimized mode has no Phase 5 to regenerate them.

### Step 24: Read Analysis Results

- **Standard (3 files)**: `${feature_dir}/analysis-context.md`, `analysis-code.md`, `analysis-tasks.md`.
- **Optimized (5 unified files)**: `${feature_dir}/analysis-architecture.md`, `analysis-patterns.md`, `analysis-integration.md`, `analysis-docs.md`, `analysis-tasks.md`.

## Phase 8: Plan Generation

### Step 25: Read Plan Template

Read `skill://plan-workflow/references/plan-structure.md` — read when generating `parallel-plan.md`.

### Step 26: Generate parallel-plan.md

Create `${parallel_plan_file}` following the template exactly. Required sections: Title & Overview (3-4 information-dense sentences); Critically Relevant Files and Documentation; Implementation Plan with Phases and Tasks; Advice section.

**Worktree annotations**: follow the "Worktree Annotations" section of `references/plan-structure.md` — read when annotating the plan (default `WORKTREE_MODE=true`; omit annotations and the prompt directive entirely when `--no-worktree` was passed). Team mode additionally cross-references `agent-team-dispatch.md` §7 for shared-worktree team dispatch: all parallel teammates operate against the same feature worktree path, not separate per-task paths.

### Step 27: Plan Structure Check (deferred)

Structural validation (`validate-workflow-plan.sh`) runs **once**, on the final artifact, in Step 31A — after validation-agent fixes. Do not run it against the pre-validation draft.

## Phase 9: Validation Stage

### Step 28: Read Validation Prompts

Read `skill://plan-workflow/references/validation-agents.md` — read when spawning Phase 9 validators (standard or optimized).

### Step 29: Create Validation Tasks (if `--team`)

Standard mode, 3 tasks: "Validate file paths in [feature-name] plan", "Validate dependency graph in [feature-name] plan", "Validate task completeness in [feature-name] plan". Optimized mode, 2 tasks: "Validate paths and dependencies in [feature-name] plan", "Validate task completeness in [feature-name] plan".

### Step 30: Spawn Validation Agents

**Standard mode** — 3 agents:

| Name / Teammate `name`   | Subagent Type               | Model  | Focus                                   |
| ------------------------ | --------------------------- | ------ | --------------------------------------- |
| `path-validator`         | `explore`                   | haiku  | Verify all referenced files exist       |
| `dependency-validator`   | `explore`                   | haiku  | Check for circular/invalid dependencies |
| `completeness-validator` | `codebase-research-analyst` | sonnet | Ensure tasks are actionable             |

**Optimized mode** — 2 agents:

| Name / Teammate `name`   | Subagent Type               | Model  | Focus                           |
| ------------------------ | --------------------------- | ------ | ------------------------------- |
| `path-dep-validator`     | `explore`                   | haiku  | Verify paths + dependency graph |
| `completeness-validator` | `codebase-research-analyst` | sonnet | Task quality + completeness     |

**CRITICAL**: Deploy all validation agents (3 in standard, 2 in optimized) in a **SINGLE message** with **MULTIPLE `task` tool calls**. Each `task` call uses the `agent` and `model` from the relevant table in `references/validation-agents.md`. Rely on each `task`'s return value for validator findings.

Team mode instead spawns the validators as teammates in one message with `name=` per Step 29.

### Step 31: Review and Fix Issues

- **Path A (standalone, default)**: review each `task` return value for validator findings.
- **Path B (team)**: `todo` + teammate messages.

Fix issues: correct invalid file paths, resolve circular dependencies, add missing details to incomplete tasks.

### Step 31A: Validate Final Plan Structure

After all fixes, run once on the final artifact (before visual/completion):

```bash
skill://plan-workflow/scripts/validate-workflow-plan.sh "${parallel_plan_file}" ${STORE_FLAG}
```

Fix any structural errors it reports (missing `### Phase` is an error); do not proceed until it exits 0.

In linear mode, follow artifact-store.md section **Planning skills** to Save the validated `parallel-plan` document and create/update task sub-issues with `blocks` relations mirroring dependency batches. Analysis files are not saved to Linear.

### Step 32: Shut Down Validation Teammates (if `--team`)

Send shutdown requests to all validation teammates.

## Phase 9.5: Visual Mode (if --visual)

Runs only after the plan is written (Phase 8) and validated (Phases 8–9). It never re-orders, re-runs, or substitutes for any earlier phase. See `skill://ycc-shared/references/visual-mode.md`.

### Step 32.5: Render Visual Artifact

- `--dry-run` set: print `visual generation would run` and **STOP** this phase (§2.1 short-circuit — no visual artifacts).
- `--research-only` used: no plan file was generated; skip this phase.
- Otherwise invoke `/skill:visual-plan` on the **actual written plan path** (feature-dir plan resolved in Phase 0, not a hardcoded `docs/prps/plans` path):

```
/skill:visual-plan ${STORE_FLAG} "${parallel_plan_file}"
```

`/skill:visual-plan` derives its `visual/` output directory from the supplied plan path and prints the resulting link (hosted URL, localhost preview, or `local files only`). Surface that link in the Phase 10 summary; do not re-derive the path yourself; do not edit the plan file.

## Phase 10: Summary

### Step 33: Clean Up Team (if `--team`)

confirm all teammates have shut down before completing (gate 10).

### Step 34: Display Completion Summary

Skipped when `RESEARCH_ONLY=true` or the user stopped at the checkpoint. Otherwise use the "Full Workflow Complete Summary" in `references/checkpoint-messages.md`. List only files actually created (`--plan-only`: omit Research Phase files). In linear mode replace its implementation command with: "Linear-mode plans are not yet consumable by /skill:implement-plan or /skill:prp-implement (YAN-1155); use --store=local for plans you will implement now."

## Optimized Mode

With `--optimized`, deploy 5 unified agents instead of separate research (4) + analysis (3), skipping Phase 5 entirely:

| Unified Agent         | Combines                            | Output                     | Model  |
| --------------------- | ----------------------------------- | -------------------------- | ------ |
| `arch-analyst`        | Arch Research + Context Synthesizer | `analysis-architecture.md` | sonnet |
| `pattern-analyst`     | Pattern Research + Code Analyzer    | `analysis-patterns.md`     | sonnet |
| `integration-analyst` | Integration Research                | `analysis-integration.md`  | sonnet |
| `docs-analyst`        | Doc Research                        | `analysis-docs.md`         | sonnet |
| `task-planner`        | Task Structure Agent                | `analysis-tasks.md`        | sonnet |

All `model: "sonnet"`. Prompts: `references/research-agents-optimized.md`.

- **Path A (standalone, default)**: spawn all 5 unified agents in a single message with 5 `task` calls.
- **Path B (team)**: team mode instead registers 5 unified tasks up front and spawns 5 teammates in one message with `name=`. Validation uses 2 agents instead of 3 (Path + Dependency merged). Total: 7 agents instead of 10, 2 stages instead of 3. `--optimized --plan-only` reuses the five unified artifacts from a prior `--optimized` full run (gates 6 and Phase 7 PRE-CHECK).

## Quality Standards

- **shared.md**: clear information-dense overview (3-4 sentences); all file paths verified to exist; brief useful descriptions; patterns linked to example files; documentation marked with required reading topics.
- **parallel-plan.md**: information-dense overview (3-4 sentences); complete critically-relevant file list; tasks in logical phases; at least one independent task per phase; advice section; no circular dependencies; all file paths verified.
- **Each task**: clear descriptive title; explicit dependencies; "READ THESE BEFORE TASK" section; Files to Create list (if any); Files to Modify list; concise actionable instructions.

## Output Contract

Files use the paths resolved in Phase 0: research files under `${research_dir}/`, shared at `${shared_file}`, analysis and plan under `${feature_dir}/`, with the final plan at `${parallel_plan_file}`. Local mode (default) preserves the filenames below and their existing paths; linear mode resolves under `.ycc/artifacts/<feature>/`.

Before printing dry-run or completion templates, substitute `{{RESEARCH_DIR}}` with `${research_dir}` and `{{FEATURE_DIR}}` with `${feature_dir}`.

| File                       | Producer                | Required Before             |
| -------------------------- | ----------------------- | --------------------------- |
| `research-architecture.md` | architecture-researcher | shared.md synthesis         |
| `research-patterns.md`     | patterns-researcher     | shared.md synthesis         |
| `research-integration.md`  | integration-researcher  | shared.md synthesis         |
| `research-docs.md`         | docs-researcher         | shared.md synthesis         |
| `shared.md`                | Team lead (this skill)  | Analysis phase              |
| `analysis-context.md`      | context-synthesizer     | parallel-plan.md generation |
| `analysis-code.md`         | code-analyzer           | parallel-plan.md generation |
| `analysis-tasks.md`        | task-structurer         | parallel-plan.md generation |
| `parallel-plan.md`         | Team lead (this skill)  | Skill completion            |

Contract rules:

1. Each agent writes its own output file using the Write tool.
2. Team mode: each teammate shares key findings with relevant teammates via `SendMessage`. Standalone: inter-agent sharing is unavailable — each sub-agent works independently.
3. The orchestrator runs `validate-research-artifacts.sh` before generating shared.md (Step 11), `validate-analysis-artifacts.sh` after analysis agents complete (Step 21), and `persist-or-fail.sh` as the mandatory pre-generation gate (Step 22).
4. On validation failure, message the failing teammate (team) or re-dispatch the sub-agent (standalone) — gate 9.
5. No file may be skipped or deferred — `persist-or-fail.sh` must exit 0 before plan generation.
6. In team mode, all teammates have been shut down before skill completion.

## Monorepo Support

In local mode (default), plans resolve through `resolve-artifact-store.sh` to the same git repository root `docs/plans/` as before, regardless of the subdirectory the skill runs from. A `.plans-config` file customizes it — repo root (`plans_dir: docs/plans`) for centralized plans, or package-level (`plans_dir: docs/plans` + `scope: local`) for local plans. In linear mode the same root resolution selects the `.ycc/artifacts/` cache; `store: linear` opts in.

## Notes

- You are the planning orchestrator — coordinate all phases; choose dispatch mode from `$ARGUMENTS`; spawn each stage in parallel in a single message; pass the model parameters from the tables above; validate with scripts after agents complete; read condensed analysis, not raw files; multiple validation passes ensure quality.
- With `--team`, keep one team for the entire workflow.
