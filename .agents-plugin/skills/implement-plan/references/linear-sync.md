# Implement-plan Linear Lifecycle

Read `~/.agents/ycc-shared/references/artifact-store.md` **Implementation skills** (Inputs, Resolve and hydrate, Status sync, Report and completion), **Plan task issues**, **Sync**, and **Lookup**. Those sections are the contract; this file maps them to executor phases, not a second sync protocol. All hooks below are linear-mode only. Local mode keeps its existing paths, worktree move and report behavior, with no Linear calls.

## Phase hooks

- **Phase 0:** apply Inputs and Resolve and hydrate before prerequisites. Retain `STORE_FLAG`, resolved feature slug, absolute `PLAN_PATH`, and available `SHARED_PATH` across tool calls. Use Lookup and Load with the Linear call gate and Conflict rules; never overwrite unpushed cache edits. Read the `tasks` map; rebuild a missing map in memory only (no issue creation, no cache write). Tasks without issues remain runnable and are reported as untracked.
- **Phases 1–2:** fetch mapped task states. Treat `completed` tasks as done and skip dispatch on resume; skip `canceled` tasks as removed. Retain both lists for the summary and account for completed dependencies in the execution graph. Never renumber task ids or change the plan body.
- **After Step 7's dry-run exit:** replay pending transitions from the prior report through Offline and the normal remote checks before dispatch. Apply Status sync's run-start row to the parent and Project by state type, never by a hardcoded team state name. A dry run follows the contract's `--dry-run` rule: Lookup and read-only reuse only; no `--ensure`, no cache write, no Linear writes (state changes, comments, pending replay, report Save, Project updates).
- **Before every batch, Path A or B:** apply Status sync's dispatch row to each mapped task issue. The orchestrator alone performs these transitions; implementors receive read-only absolute cache paths and report only to it.
- **After each batch's orchestrator validation:** mark issues for tasks that passed their required validation `completed`. Do not mark success merely because an agent returned. Apply Status sync's failure row to failed tasks/batches: leave issues `started` and add one sanitized comment identifying the task id, failed check and short excerpt; no secrets or full logs. Preserve the existing standalone/team failure policy.
- **After every state change or failure comment:** apply the contract's Timestamps rule (fetch `updatedAt` first; re-stamp `tasks.<id>.updatedAt` only when it matched the stored stamp). Never move issues backwards, reopen them, change assignees, or touch issues outside this plan's map and parent.

## Phase 4 report and completion

After final verification, apply **Report and completion**: resolve kind `report` with `${STORE_FLAG} --ensure --kind=report --slug=<resolved-slug>` through the shared resolver, retain its absolute path, write the run report, and Save as the Project status update (plus a Document when long), recording `linear.statusUpdate`. Use the contract's health, parent-completion and Project completion rules (name equals slug, label, not `ARTIFACT_LINEAR_PROJECT`, all issues done); otherwise leave the Project open and report why. Local mode does not run this hook.

If an installed, authorized MCP becomes unreachable mid-run, keep implementing through **Offline**. At the moment a transition fails, resolve the report path with `--ensure`, append it under `## Linear sync pending` in that file and set `pending: true`; the final report merges into the same file. Print the same list; the next run replays it before dispatch, without overriding remote changes. Do not claim an unapplied transition or status update succeeded. Missing/unauthorized MCP at initial hydration follows the gate, not a local fallback.

Use `references/output-formats.md` for Linear URLs, issues moved, skipped/untracked tasks, pending transitions and the Project completion reason. Keep the existing Goal Signals unchanged.
