# Standalone Dispatch — OpenCode V2 `subagent` Contract

This is the generated OpenCode V2 contract for standalone child-agent work. It uses
the host's native vocabulary directly. OpenCode V2 does not expose Claude Code's
agent-team tools, and `--team` workflows must abort before dispatch.

## 1. Native call shape

A new child session uses all required fields and omits `sessionID`:

```text
subagent(agent="<agent>", description="<short title>",
         prompt="<complete task prompt>", background=false)
```

The fields mean:

- `agent`: the configured subagent ID.
- `description`: a short title for the child session.
- `prompt`: the complete task, context, ownership boundary, working directory, output
  contract, and artifact paths. A new child starts with fresh context.
- `background`: set it explicitly on every call. Never depend on a host or plugin
  default.

Only configured agents with `mode: subagent` or `mode: all` can be dispatched. The
default nesting depth is one, so a child normally cannot launch another child.

Independent calls may be issued in one parallel tool batch. Keep file ownership
disjoint when children share a working tree.

## 2. Foreground dispatch

Use foreground dispatch when the next step depends on the child's report:

```text
subagent(agent="<agent>", description="<short title>",
         prompt="<complete task prompt>", background=false)
```

Omit `sessionID` for a new child. Never pass a placeholder session ID.

The call waits for the child run and returns its response. Treat the response as a
candidate report, not proof that the requested work exists. Before accepting it:

1. Require nonempty report text in the requested format.
2. Validate every declared file, artifact, or working-tree change independently.
3. Run the required focused checks for the work.
4. Treat a host `succeeded` or `completed` lifecycle state only as evidence that the
   child run terminated; it does not verify the deliverables.

## 3. Background dispatch

Use background dispatch only when useful independent work remains or the workflow
explicitly supports deferred result retrieval:

```text
subagent(agent="<agent>", description="<short title>",
         prompt="<complete task prompt>", background=true)
```

Omit `sessionID` for a new child. Never pass a placeholder session ID.

The initial return is an acknowledgement containing a child `sessionID`, not the final
report. Record that ID immediately. Continue only non-overlapping work. If there is
nothing productive to do, end the turn so the native terminal notification can be
delivered.

Do not use shell sleeps or tight status loops. After a terminal notification, a host
plugin may advertise read-only lifecycle and result tools:

```text
task_status(sessionID="<child session ID>")
task_result(sessionID="<child session ID>")
```

Use `task_status` for one bounded inspection when the notification is ambiguous. Use
`task_result` to retrieve verified terminal report text. If either reports
`running`, `pending`, or `running (unconfirmed)`, stop checking and wait for the next
native notification. Do not loop.

These `task_*` tools are plugin extensions, not guaranteed OpenCode built-ins. When
they are absent, use foreground dispatch for work whose report is required. Never
invent a result-retrieval tool.

## 4. Resume is not result retrieval

Continue an existing child conversation only when more work or clarification is
required:

```text
subagent(agent="<agent>", description="<follow-up title>",
         prompt="<new follow-up instruction>",
         sessionID="<existing child session ID>", background=false)
```

Passing `sessionID` resumes the child and may run tools or change files again. Never
call `subagent` with `sessionID` merely to fetch a prior report. Use `task_result` when
it is advertised, or report that native result retrieval is unavailable.

## 5. Deliverable verification

The parent owns final verification. A child report and host lifecycle state are two
separate signals:

| Signal                     | What it proves                                        |
| -------------------------- | ----------------------------------------------------- |
| `succeeded` / `completed`  | The host observed a terminal child run.               |
| Nonempty structured report | The child described an outcome in the required shape. |
| Required files or diff     | The requested on-disk work exists.                    |
| Focused checks             | The produced work satisfies the requested validation. |

Do not mark parent work complete until every required signal for that task is present.
For code-writing children, inspect the working tree and validate the files they owned.
For research or review children, read the declared artifact as well as the report.

## 6. Contentless and failed outcomes

A contentless completion is incomplete even when the host reports success. Handle it
in this order:

1. Record and report the child `sessionID`.
2. Inspect the working tree and every declared artifact before retrying; the child may
   have made edits without returning a report.
3. Preserve valid existing edits and avoid duplicate work.
4. Retry at most once with the same child only when a follow-up report is safe, or with
   a new child when the original session cannot continue. State which form of one retry
   you chose.
5. If the retry is also contentless, report the task as incomplete. Do not synthesize a
   success report.

Treat explicit `failed`, `error`, `interrupted`, or `cancelled` outcomes as failures.
Surface the child ID and available error text. Continue only work that is independent
of the failed deliverable.

## 7. Artifact backstop

Content-producing children should write their result to a declared artifact path and
return the same material in their report. Code-writing children use their owned diff as
the artifact and finish with the required machine-readable status line.

When report text is missing:

1. Read the artifact or inspect the owned diff.
2. Validate it before using it.
3. Still report the missing child report as incomplete; an artifact can preserve useful
   work but does not turn a contentless run into a verified child response.

## 8. Worktree and Branch Preparation

Single source for plan, plan-workflow, prp-plan (annotation directive) and the executors
`implement-plan`, `prp-implement`, `orchestrate`. Applies to standalone runs.

### 8.1 How worktree mode is decided

1. `--no-worktree` present: `WORKTREE_MODE=false`. Forced off regardless of plan annotations;
   no feature worktree; work on the prepared `feat/<slug>` branch in the current checkout.
2. Plan contains `## Worktree Setup`: `WORKTREE_MODE=true`. Annotations are the source of truth.
3. Neither: `WORKTREE_MODE=true` (default). Derive the single path below.

`--worktree` is a silent legacy no-op; combining it with `--no-worktree` is an error where the
skill says so. When the plan has `## Worktree Setup`, read `WT_PARENT_PATH` from its
`**Parent**:` line and `WT_FEATURE_SLUG` as the segment after `<repo>-`. Set
`WORKTREE_ACTIVE=true` if annotations exist or `WORKTREE_MODE=true`; false for `--no-worktree`.

Default-on deduction (no annotations):

- `WT_REPO_NAME` = basename of `git rev-parse --show-toplevel`
- `WT_FEATURE_SLUG` per skill: `implement-plan` uses the raw feature-name argument;
  `prp-implement` sanitizes the plan basename (cap 40); `orchestrate` sanitizes the task
  description (cap 20); `plan` confirmed execution uses the team sanitization (cap 20,
  fallback `untitled`). Shared sanitizer: lowercase, `[^a-z0-9-]` to `-`, collapse runs, trim
- `FEATURE_BRANCH` = `feat/${WT_FEATURE_SLUG}`
- `WT_PARENT_PATH` = `<repo-root>/.opencode/worktrees/${WT_REPO_NAME}-${WT_FEATURE_SLUG}/`

### 8.2 Prepare (before any implementor dispatch)

Set `REPO_ROOT=$(git rev-parse --show-toplevel)`. Inspect `git status --porcelain`: expected pre-commit plan artifacts may be dirty;
unrelated dirty files: stop and ask user to stash, commit or clean. Then:

```bash
FEATURE_BRANCH=$(bash {{package-root}}/shared/scripts/prepare-feature-branch.sh "${WT_FEATURE_SLUG}")
```

Do not skip it. Narrative-only branch instructions let agents commit to `main`. Contract:
`branch-prep.md`. When `WORKTREE_ACTIVE=true`, once before the first batch (idempotent; adopts
the prepared branch; echoes path, store as `WT_PARENT_PATH`):

```bash
WT_PARENT_PATH=$(bash {{package-root}}/shared/scripts/setup-worktree.sh parent "${WT_REPO_NAME}" "${WT_FEATURE_SLUG}")
```

Then move plan artifacts once (never `cp`, `rsync` or sync; never move back); companions such as
`shared.md` ride as extra arguments. Use `$PLAN_PATH` for every later reference; run later
validation/reports/archive inside `$WT_PARENT_PATH`:

```bash
PLAN_PATH=$(bash {{package-root}}/shared/scripts/move-plan-to-worktree.sh "<plan-path>" "$WT_PARENT_PATH" ["<companion>" ...])
```

`WORKTREE_ACTIVE=false`: skip worktree setup and the move; keep original plan path and run in
the prepared current checkout.

### 8.3 Agent prompt lines

Active worktree, every agent prompt (parallel and sequential):

```
Working directory: ${WT_PARENT_PATH}
All parallel agents in this batch share this path; batching guarantees no two agents touch the same file.
```

`--no-worktree`:

```
Working directory: ${REPO_ROOT}
All parallel agents in this batch share the current feature branch; batching guarantees no two agents touch the same file.
```

Treat that directory as repo root for Read/Write/Edit/Bash. Never pass `isolation: "worktree"` or
`subagent(isolation: "worktree", background=false)`; it creates separate harness worktrees. Codex/opencode: prompt line is
sufficient. Cursor: warn and print the manual `git worktree add` command.

### 8.4 Planner annotation directive (default WORKTREE_MODE=true; omit for --no-worktree)

Append to planner and persona prompts:

```
WORKTREE MODE:

The plan consumer will run all tasks in a single shared git worktree.
In your emitted plan:

1. Add a top-level `## Worktree Setup` section BEFORE the Batches summary
   (or before Implementation Steps when there is no Batches section):

   ## Worktree Setup

   - **Parent**: <repo-root>/.opencode/worktrees/<repo>-<feature>/ (branch: feat/<feature>)

   Substitute the concrete `<repo>` and `<feature>` values; keep `<repo-root>/.opencode/worktrees/`
   as this runtime's worktree root. All tasks - parallel and sequential - share this one path.
   Do NOT add a `**Children**:` list and do NOT add per-task `**Worktree**:` annotations.
```

## 9. Dependency Resolution and Batching

### 9.1 Graph and batches

Build the graph from `Depends on [...]` annotations. Tasks with `Depends on [none]` form batch 1.
A task joins the earliest batch whose dependencies are all in prior batches. Two tasks touching the
same file never share a batch. Cross-cutting shared types/config get a dedicated early batch.
Prefer wide-shallow graphs over narrow-deep chains. Dispatch each batch as one message;
wait for the whole batch before the next.

### 9.2 Planner output directives (parallel plans)

When a planner is asked for parallel output, append:

```
PARALLEL OUTPUT MODE:

Shape the output for parallel execution:
1. Number steps hierarchically (1.1, 1.2, 2.1); first digit is batch.
2. Populate Dependencies on every step with explicit IDs (`Depends on [1.1, 1.2]` or `Depends on [none]`).
3. Add `## Batches` after `## Architecture Changes` and before `## Implementation Steps`:

   | Batch | Steps         | Depends On | Parallel Width |
   | ----- | ------------- | ---------- | -------------- |
   | B1    | 1.1, 1.2, 1.3 | -          | 3              |

   - **Total steps**: N
   - **Total batches**: M
   - **Max parallel width**: X
4. Apply the batch construction rules from section 9.1.
```

### 9.3 Between batches and failures

Run the skill's own validation inside the execution tree (worktree path or prepared checkout).
After each batch update todos and print the skill's verbatim `[done] Batch BN: K tasks — complete` marker (em dash; transcript loops match the marker).
Do not auto-retry a failed batch (usually file conflict or hidden dependency) and do not skip it;
later batches may depend on it. Preserve completed work; ask the user (fix/resume, switch to
sequential, abort) per the `failure-recovery` class in `question-policy.md` in this directory.
Standalone partial failure: continue only independent tasks.

## 10. Executing a Confirmed Plan

After a user confirms an in-conversation parallel plan: run section 8 (worktree: plan names parent
`<repo-root>/.opencode/worktrees/<repo>-<feature>/`; run `setup-worktree.sh parent` once, dispatch with
`Working directory: <parent path>`; `--no-worktree`: derive the slug with the team-name sanitization
rules (lowercase, non `[a-z0-9-]` to `-`, collapse, cap 20, fallback `untitled`) and run
`prepare-feature-branch.sh`). The helper is idempotent, exits 1 on unrelated dirty tree, exits 2 on
a different feature branch (`--allow-existing-feature-branch` after confirmation) or on `release/*`
when `RELEASING.md` exists (`--allow-release-branch` for release-only fixes). Do not skip.
Then process section 9 batches with one `implementor` `subagent` per step in one message; run the
project type-check and unit-test commands between batches; on failure stop and ask the user
(`failure-recovery` class in `question-policy.md`).

## 11. Unsupported team mode

OpenCode V2 standalone dispatch has no team-name argument, shared team roster, or Claude Code
team lifecycle. If a workflow receives `--team`, abort with a compatibility message and
instruct the caller to rerun the default standalone mode. Never translate team identity
into `sessionID`; a child-session resume ID is a different concept.
