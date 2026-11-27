# Orchestrate Dispatch Playbook

## Contents

- 1. Usage Block
- 2. Dry-Run Output
- 3. Plan-Only Worktree Section
- 4. Path A Dispatch Call (standalone)
- 5. Path B Dispatch Call (`--team`)
- 6. Final Summary Template
- 7. Quality Checklists
- 8. Coordination Principles and Patterns
- 9. Troubleshooting
- 10. Subtask Registration Formats
- 11. Orchestrate Batch Adapter

Output templates, dispatch call examples, checklists, and troubleshooting for the
`orchestrate` skill. SKILL.md holds the gates and phase order; this file holds the
blocks that are copied or filled in.

---

## 1. Usage Block

Print this verbatim when no task description remains after stripping flags, then abort:

```
Usage: /ycc:orchestrate [--team] [--dry-run] [--plan-only] [--sequential] [--worktree] [--no-worktree] <task-description>

Examples:
  /ycc:orchestrate "Implement user authentication with tests and docs"
    # default: all parallel and sequential tasks share one feature worktree

  /ycc:orchestrate --team "Implement user authentication with tests and docs"
    # agent-team dispatch (worktree still on by default for parallel tasks)

  /ycc:orchestrate --dry-run "Debug payment processing failure"
  /ycc:orchestrate --plan-only "Refactor database layer"
  /ycc:orchestrate --sequential "Migrate legacy config"
  /ycc:orchestrate --team --dry-run "Update API documentation across all services"

  /ycc:orchestrate --no-worktree "Refactor the auth middleware"
    # opt out of worktree isolation; all tasks run in the current checkout

  /ycc:orchestrate --team --no-worktree "Implement user authentication with tests and docs"
    # agent-team dispatch without worktrees
```

---

## 2. Dry-Run Output

Default dry-run (no `--team`) shows the batch roster only:

```markdown
# Dry Run: Orchestration Plan for [Task]

## Task Analysis

- Complexity: [Simple/Medium/Complex]
- Execution Mode: [Parallel/Sequential]
- Total Subtasks: [count]

## Subtask Breakdown

### Batch 1 (Independent Tasks)

1. **[Subtask 1]**
   - Agent: [agent-type]
   - Focus: [brief description]
   - Output: [expected deliverable]

2. **[Subtask 2]**
   - Agent: [agent-type]
   - Focus: [brief description]
   - Output: [expected deliverable]

### Batch 2 (After Batch 1)

1. **[Subtask 3]**
   - Agent: [agent-type]
   - Dependencies: [subtask-1]
   - Focus: [brief description]
   - Output: [expected deliverable]

## Agent Deployment Summary

- Total Agents: [count]
- Parallel Batches: [count]
- Max Parallelism: [largest batch size]

## Next Steps

Remove --dry-run flag to execute the orchestration.
```

`--team --dry-run` also prints the team name and roster; the exact block is in SKILL.md Phase 3.

When worktree mode is active, append this line to either variant. No
`setup-worktree.sh` or `list-worktrees.sh` calls happen in dry-run mode:

```
Worktree:   feature=<repo-root>/<worktree-root>/<repo>-<FEATURE_SLUG>/  (all subtasks)
```

---

## 3. Plan-Only Worktree Section

When `WORKTREE_MODE=true`, the plan file at `docs/orchestration/[sanitized-task-name].md`
gains a `## Worktree Setup` section immediately after frontmatter, before Batch 1.
Follow the annotation format in `~/.local/share/ycc/muse/ycc/ycc-shared/references/worktree-strategy.md`
section 2: list only the parent path. Do not add child paths or a `**Children**:` list.

---

## 4. Path A Dispatch Call (standalone)

One message, multiple calls, no `name`, no `run_in_background`. Each prompt
uses the Path A Coordination Block from `agent-prompts.md`. With `WORKTREE_MODE=true`
each prompt starts with the `Working directory:` line and the coordination note. Do not
pass `isolation: "worktree"`: it creates a separate harness worktree per agent and
breaks the single-worktree contract. With `WORKTREE_MODE=false` omit the
`Working directory:` line and the note.

```
Agent(
  subagent_type = "nodejs-backend-architect",
  description = "Implement auth system",
  prompt = "Working directory: <repo-root>/<worktree-root>/<repo>-<FEATURE_SLUG>/\nAll parallel agents in this batch share this path; batching guarantees no two agents touch the same file.\n\n[substituted template with Path A coordination block]"
)
Agent(
  subagent_type = "test-strategy-planner",
  description = "Create auth test plan",
  prompt = "Working directory: <repo-root>/<worktree-root>/<repo>-<FEATURE_SLUG>/\nAll parallel agents in this batch share this path; batching guarantees no two agents touch the same file.\n\n[substituted template with Path A coordination block]"
)
Agent(
  subagent_type = "documentation-writer",
  description = "Document auth API",
  prompt = "Working directory: <repo-root>/<worktree-root>/<repo>-<FEATURE_SLUG>/\nAll parallel agents in this batch share this path; batching guarantees no two agents touch the same file.\n\n[substituted template with Path A coordination block]"
)
```

---

## 5. Path B Dispatch Call (`--team`)

One message, multiple `Agent` calls. Every call includes `name`. With
`WORKTREE_MODE=true` each prompt carries the same `Working directory:` line and
coordination note as Path A. Do not pass `isolation: "worktree"` in either worktree
mode. Each prompt includes the Path B Team Communication section from
`agent-prompts.md` with `{{BATCH_NUMBER}}` and `{{BATCH_TEAMMATES}}` substituted.

```
Agent(
  name = "subtask-1",
  subagent_type = "nodejs-backend-architect",
  description = "Implement auth system",
  prompt = "Working directory: <repo-root>/<worktree-root>/<repo>-<FEATURE_SLUG>/\nAll parallel agents in this batch share this path; batching guarantees no two agents touch the same file.\n\n[substituted template with Path B Team Communication section]"
)
Agent(
  name = "subtask-2",
  subagent_type = "test-strategy-planner",
  description = "Create auth test plan",
  prompt = "Working directory: <repo-root>/<worktree-root>/<repo>-<FEATURE_SLUG>/\nAll parallel agents in this batch share this path; batching guarantees no two agents touch the same file.\n\n[substituted template with Path B Team Communication section]"
)
Agent(
  name = "subtask-3",
  subagent_type = "documentation-writer",
  description = "Document auth API",
  prompt = "Working directory: <repo-root>/<worktree-root>/<repo>-<FEATURE_SLUG>/\nAll parallel agents in this batch share this path; batching guarantees no two agents touch the same file.\n\n[substituted template with Path B Team Communication section]"
)
```

Shutdown after each batch:
`SendMessage(to="subtask-<N>", message={type: "shutdown_request"})` per teammate.

---

## 6. Final Summary Template

```markdown
# Orchestration Complete: [Task]

## Execution Mode

[Standalone sub-agents | Agent team (team: orch-<sanitized-task>)]

## Team Summary (Path B only)

- Team: orch-<sanitized-task>
- Total teammates spawned: [count across all batches]
- Batches executed: [count]
- Inter-agent sharing: Enabled (teammates shared findings within batches via SendMessage)

## Execution Summary

- **Total Subtasks**: [count]
- **Completed**: [count]
- **Failed**: [count]
- **Execution Batches**: [count]

## Results by Agent

### [Agent Type 1] - [Subtask 1]

**Status**: Success
**Outputs**:

- Created: [files]
- Modified: [files]
- Notes: [key points]

### [Agent Type 2] - [Subtask 2]

**Status**: Success
**Outputs**:

- Created: [files]
- Modified: [files]
- Notes: [key points]

## Files Changed

### Created

- /path/to/new/file1.ext
- /path/to/new/file2.ext

### Modified

- /path/to/modified/file1.ext
- /path/to/modified/file2.ext

## Integration Status

- [x] All agent outputs integrated successfully
- [x] No conflicting changes detected
- [x] Cross-references validated
- [ ] Manual review needed for: [items]

## Issues Encountered

[List any problems, warnings, or areas needing attention]

## Next Steps

1. Review the changes in your editor
2. Test the integrated functionality
3. Address any failed subtasks if needed
4. Commit the changes when satisfied
```

---

## 7. Quality Checklists

Task decomposition (each subtask):

- [ ] Clear, specific scope (not too broad or vague)
- [ ] Single responsibility (no overlapping work)
- [ ] Appropriate size (completable in one session)
- [ ] Explicit dependencies stated
- [ ] Clear success criteria
- [ ] Agent type assignment justified

Agent assignment (each agent):

- [ ] Agent type matches subtask requirements
- [ ] No duplicate work between agents
- [ ] Context files identified for agent
- [ ] Expected output format specified
- [ ] Non-overlapping scope with other agents
- [ ] Clear boundaries defined

Execution:

- [ ] Parse flags and set `TEAM_FLAG`, `DRY_RUN`, `PLAN_ONLY`, `SEQUENTIAL`, `WORKTREE_MODE` before any side effects (default `WORKTREE_MODE=true` unless `--no-worktree`)
- [ ] Deploy independent tasks in parallel (single message, multiple dispatch calls)
- [ ] Respect dependency ordering between batches
- [ ] Track progress via `TaskCreate`/`TaskUpdate` (Path A) or `TaskList` (Path B)
- [ ] Handle failures gracefully
- [ ] Synthesize results on completion
- [ ] Verify integration between agent outputs
- [ ] Path B: use the implicit session team, include `name` (never `team_name`) on every `Agent` call, shut down teammates between batches via `SendMessage`, confirm all teammates have stopped

Result:

- [ ] All subtasks attempted
- [ ] Clear status for each subtask (success/fail)
- [ ] Complete list of files changed
- [ ] Integration issues identified
- [ ] Failed subtasks documented
- [ ] Next steps provided

---

## 8. Coordination Principles and Patterns

Principles:

1. Delegate everything: only coordinate; do not implement.
2. Maximize parallelism: run independent tasks simultaneously.
3. Clear boundaries: no overlap between agents.
4. Single goal: keep all agents aligned to the main objective.
5. Track progress: `TaskCreate`/`TaskUpdate` in Path A, `TaskList` in Path B.
6. Synthesize results into a coherent whole.
7. Path B additions: follow shared agent-team-dispatch §8.2 (single team, graph, batch spawn and cleanup).

Use `--sequential` when subtasks are tightly coupled, each step informs the next,
conflict risk is high, or the work is debugging/exploratory.

Use `--plan-only` when approval is needed before execution, the task is very large or
risky, the approach needs review first, or a reusable orchestration pattern is being built.

Common patterns:

- Feature implementation: research agent -> multiple implementation agents -> test agent -> docs agent
- Bug investigation: root cause analyzer -> fix implementor -> test verifier -> docs updater
- Refactoring: architecture analyst -> multiple refactor agents -> test updater -> docs updater
- Documentation update: code analyzer -> multiple doc writers -> cross-link validator

---

## 9. Troubleshooting

- Agents produce conflicting changes: review subtask boundaries, ensure non-overlapping scopes, redeploy with clearer instructions.
- Dependencies not properly sequenced: review the dependency graph, adjust batch organization, ensure proper ordering.
- Agent outputs do not integrate: add an integration subtask, deploy an agent to resolve conflicts, update instructions for clarity.
- Too many agents for one batch: break into smaller batches, stagger deployment, or use sequential mode.
- Unclear what to orchestrate: ask clarifying questions before decomposition, use dry-run to preview, iterate on the plan.

---

## 10. Subtask Registration Formats

Path A (`TEAM_FLAG=false`): register each subtask as a task item with `TaskCreate`; no teammate dispatch is used. Capture the returned task IDs and track batch completion
after all results have arrived.

```
TaskCreate: subject="subtask-1: <title>", description="Agent: <type>. Scope: <full spec>"
TaskCreate: subject="subtask-2: <title>", description="Agent: <type>. Scope: <full spec>"
TaskUpdate: taskId="<subtask-2 returned ID>", addBlockedBy=["<subtask-1 returned ID>"]
```

Path B (`--team`): implicit session team, run label `orch-<FEATURE_SLUG>`, purpose `Orchestration team for: <task description>`. Register `subject="[subtask-N]: [Description]"`, `description="Agent: [agent-type]. Scope: [details]. Expected output: [deliverables]."`; dependencies from decomposed graph. `DRY_RUN` or `PLAN_ONLY`: skip registration/setup, compute sanitized name in memory. Mechanism follows shared team §8.2.

---

## 11. Orchestrate Batch Adapter

Follow the shared dispatch primitive's spawn, return, and shutdown contract. These
orchestrate-specific policies supplement the shared mechanism; generic confirmed-plan
execution defaults do not change this skill's agent assignments or output format.

Path A (standalone), per batch in order:

1. Build the agent list: each subtask's name, agent type, focus, deliverables.
2. Spawn all agents in one message with multiple `Agent` calls (section 4). Prompts use
   the Path A coordination block and, when active, the shared parent working directory.
3. Wait for all batch calls to return; the shared standalone-dispatch.md result and
   fallback rules govern how results are read.
4. Review each returned summary; update matching tasks via `TaskUpdate` to `completed`.
5. If a subtask fails, record the failure, decide whether dependent subtasks can proceed,
   and continue independent subtasks. Never start a task before its dependencies complete.
6. Scan `TaskList` for pending subtasks whose dependencies are all `completed`. If
   subtasks remain but none is unblocked, report deadlock and stop.

No `SendMessage` shutdown is needed in Path A: there are no teammates.

Path B (`--team`): follow shared team §8.2. Before spawn build teammate list (name/description per subtask); substitute `{{BATCH_NUMBER}}` and `{{BATCH_TEAMMATES}}` in the Path B Team Communication prompt. If a subtask fails, record it, decide whether dependents can proceed, continue only independent tasks. Pending-but-none-unblocked: report deadlock and stop.

Repeat for subsequent batches until all subtasks complete or none can be unblocked.
No new per-batch validation or confirmation gate is imposed on this workflow: Phase 5
still owns integration verification and the completion summary.
