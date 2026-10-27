# PRP Linear Sync (linear mode only)

Canonical rules: `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/artifact-store.md` **Implementation skills** (Status sync, Report and completion, Offline). This file only adapts them to prp-implement's phases. Local mode never reads this file and makes no Linear calls. Only the orchestrating skill calls Linear MCP; `ycc:implementor` subagents never do. Move issues by state type, never team-specific state names, and never move an issue backwards, reopen it, change its assignee, or touch issues outside the plan's `tasks` map and parent.

## Run start

Run start and pending replay happen immediately before the first task or batch dispatch (Path C: after C.2, so `--team --dry-run` exits first). Parent tracking issue → `started` when `backlog`/`unstarted`/`triage`; Project → `started` when `backlog`/`planned`. Replay any `## Linear sync pending` transitions from a prior report on this plan first. A `--dry-run` follows the contract's rule: no `--ensure`, no cache write, no Linear writes.

## Phase 3 status sync

- Sequential (Path A): before each task, its issue → `started` when `backlog`/`unstarted`/`triage`; after that task's Phase 0 type-check passes, its issue → `completed`.
- Parallel/team: at batch dispatch, every task issue in the batch → `started` (same guard); after the between-batch validation (type-check + affected tests) passes, every issue in that batch → `completed`.
- Failure (task or batch): leave the issue `started`; add one comment with the task id, the failing check, and a short excerpt — never secrets or full logs.
- Re-run: a task whose issue is already `completed` is treated as done and skipped; a `canceled` issue's task is skipped as removed. Print both in the summary. A task with no issue still runs; list it as untracked in the report and suggest re-saving the plan with its planning skill.
- After every state change or failure comment, apply the contract's Timestamps rule (fetch `updatedAt` first; re-stamp `tasks.<id>.updatedAt` only when it matched the stored stamp).

## Phase 5 report and completion

1. Resolve the report path: `bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --ensure --kind=prp-report --slug=<slug>`; write the report there (same content as the local report template). Do this on failure as well as success.
2. Save it: post one Project status update with health `onTrack` when every task passed, `atRisk` otherwise; when the report exceeds the status-update size, also save it as a Document (`<slug> · report`). Record `linear.statusUpdate` (and `linear.document` when long) in the report cache file's frontmatter.
3. Replace the archive move: parent tracking issue → `completed` once all tasks pass final validation. Complete the Project only under the contract's Project completion rule (name equals the plan slug, carries `ARTIFACT_LINEAR_LABEL` when set, not `ARTIFACT_LINEAR_PROJECT`, every issue `completed` or `canceled`); otherwise leave it open and say why in the report/summary.
4. `PLAN_ARCHIVED: PASS` in linear mode means: parent tracking issue and every tracked task issue are `completed` (or `canceled`) and the Project status update was posted.

## Offline

If the MCP becomes unreachable mid-run, keep implementing. At the moment a transition fails, resolve the report path with `--ensure`, append it under `## Linear sync pending` in that file and set `pending: true`; the final report merges into the same file. Print the list. The next run on the same plan replays the pending transitions before dispatching, following artifact-store.md **Offline**.
