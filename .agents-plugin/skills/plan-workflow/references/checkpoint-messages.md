# Checkpoint Messages

## Contents

- Dry Run Output
- Checkpoint Question (Phase 2)
- Research Complete Summary
- Full Workflow Complete Summary
- Existing State Warnings
- Error Messages
- Usage Instructions

Templates for user interaction points during the unified planning workflow.

`{{RESEARCH_DIR}}` is the resolved research directory: equal to `{{FEATURE_DIR}}` in local mode, or `{{FEATURE_DIR}}/research` in linear mode. Other artifacts use their resolved feature-directory paths.

---

## Dry Run Output

Use this template when `--dry-run` flag is present:

```markdown
# Dry Run: Plan Workflow for {{FEATURE_NAME}}

## Dispatch Mode

[standalone sub-agents | agent team pw-{{FEATURE_NAME}}]

## Execution Mode

[Standard (10 agents) / Optimized (7 agents)]

## Directory

{{FEATURE_DIR}}/

## Execution Plan

### Phase 1: Research

Agents to deploy:

1. Architecture Researcher (codebase-research-analyst) -> research-architecture.md
2. Pattern Researcher (codebase-research-analyst) -> research-patterns.md
3. Integration Researcher (codebase-research-analyst) -> research-integration.md
4. Documentation Researcher (codebase-research-analyst) -> research-docs.md

Output: shared.md

### Phase 2: Checkpoint

[Will pause for user review unless --no-checkpoint]

### Phase 3: Analysis (Standard Mode Only)

Agents to deploy:

1. Context Synthesizer (codebase-research-analyst) -> analysis-context.md
2. Code Analyzer (codebase-research-analyst) -> analysis-code.md
3. Task Structure Agent (codebase-research-analyst) -> analysis-tasks.md

### Phase 4: Plan Generation

Output: parallel-plan.md

### Phase 5: Validation

Agents to deploy:

1. File Path Validator (explore)
2. Dependency Graph Validator (explore)
3. Task Completeness Validator (codebase-research-analyst)

## Files That Would Be Created

### Research Files

- {{RESEARCH_DIR}}/research-architecture.md
- {{RESEARCH_DIR}}/research-patterns.md
- {{RESEARCH_DIR}}/research-integration.md
- {{RESEARCH_DIR}}/research-docs.md
- {{FEATURE_DIR}}/shared.md

### Analysis Files (Standard Mode)

- {{FEATURE_DIR}}/analysis-context.md
- {{FEATURE_DIR}}/analysis-code.md
- {{FEATURE_DIR}}/analysis-tasks.md

### Planning Files

- {{FEATURE_DIR}}/parallel-plan.md

## Execution Model

- Default (`AGENT_TEAM_MODE=false`): each stage deploys its agents as standalone sub-agents in a single message with multiple `Agent` calls. No team coordination; each sub-agent writes its assigned artifact and returns. Orchestrator validates and synthesizes between stages.
- With `--team` (`AGENT_TEAM_MODE=true`): use the implicit session team (run label `pw-{{FEATURE_NAME}}`), register each stage's tasks up front, spawn teammates per stage (research → analysis → validation) with `SendMessage` coordination and `TaskList` progress tracking, shut down between stages, then send shutdown requests to every teammate at the end.

If `--team` was passed, the above plan additionally includes team `pw-{{FEATURE_NAME}}` with the corresponding teammate roster.

Do **not** call `TaskCreate`, `Agent`, or `SendMessage` in dry-run mode.

## Next Steps

Remove --dry-run flag to execute the workflow.
```

---

## Checkpoint Question (Phase 2)

Use with AskUserQuestion after research completes:

**Question**: `Research complete for {{FEATURE_NAME}}. Review the shared context before continuing to planning?`

**Header**: `Checkpoint`

**Options**:

1. **Continue to planning**
   - Description: Proceed to analysis and plan generation phases

2. **Review shared.md first**
   - Description: Display the shared context document, then decide

3. **Stop here**
   - Description: End workflow - continue manually with /parallel-plan later

---

## Research Complete Summary

Display after research phase (if --research-only or user stops at checkpoint):

```markdown
# Research Phase Complete

## Feature

{{FEATURE_NAME}}

## Files Created

Standard mode:

- {{RESEARCH_DIR}}/research-architecture.md - System structure analysis
- {{RESEARCH_DIR}}/research-patterns.md - Coding patterns identified
- {{RESEARCH_DIR}}/research-integration.md - APIs and integrations
- {{RESEARCH_DIR}}/research-docs.md - Relevant documentation
- {{FEATURE_DIR}}/shared.md - Consolidated shared context

Optimized mode (`--research-only --optimized`) — no `research-*.md`; the unified artifacts are:

- {{FEATURE_DIR}}/analysis-architecture.md
- {{FEATURE_DIR}}/analysis-patterns.md
- {{FEATURE_DIR}}/analysis-integration.md
- {{FEATURE_DIR}}/analysis-docs.md
- {{FEATURE_DIR}}/analysis-tasks.md
- {{FEATURE_DIR}}/shared.md

## Agent Summary

- Research agents deployed: [4 standard / 5 unified]
- Mode: [Standard research / Optimized unified]

## Shared Context Overview

[Brief summary of key findings from shared.md]

## Next Steps

To continue with planning:

/plan-workflow {{FEATURE_NAME}} --plan-only

Or use the parallel-plan skill directly:

/parallel-plan {{FEATURE_NAME}}

To review the shared context:

cat {{FEATURE_DIR}}/shared.md
```

---

## Full Workflow Complete Summary

Display after all phases complete:

```markdown
# Plan Workflow Complete

## Feature

{{FEATURE_NAME}}

## Files Created

### Research Phase

- {{RESEARCH_DIR}}/research-architecture.md
- {{RESEARCH_DIR}}/research-patterns.md
- {{RESEARCH_DIR}}/research-integration.md
- {{RESEARCH_DIR}}/research-docs.md
- {{FEATURE_DIR}}/shared.md

### Analysis Phase

- {{FEATURE_DIR}}/analysis-context.md
- {{FEATURE_DIR}}/analysis-code.md
- {{FEATURE_DIR}}/analysis-tasks.md

Optimized mode — the five unified files replace both the research and analysis sets:

- {{FEATURE_DIR}}/analysis-architecture.md
- {{FEATURE_DIR}}/analysis-patterns.md
- {{FEATURE_DIR}}/analysis-integration.md
- {{FEATURE_DIR}}/analysis-docs.md
- {{FEATURE_DIR}}/analysis-tasks.md

### Planning Phase

- {{FEATURE_DIR}}/parallel-plan.md

## Agent Deployment Summary

- Mode: [Standard / Optimized]
- Research agents: [4 standard / 0 optimized (unified agents counted below)]
- Analysis agents: [3 standard / 5 optimized (unified)]
- Validation agents: [3 / 2]
- Total agents: [10 / 7]

## Plan Overview

- **Total Phases**: [count]
- **Total Tasks**: [count]
- **Independent Tasks**: [count that can run in parallel]
- **Max Dependency Depth**: [deepest chain]

## Validation Results

- File Path Validation: [status]
- Dependency Graph: [status]
- Task Completeness: [status]

## Next Steps

In local mode only, print:

/implement-plan {{FEATURE_NAME}}

This will execute the plan with parallel agents where dependencies allow.

In linear mode, replace that command with:

/implement-plan --store=linear {{FEATURE_NAME}}

This loads the plan from the Linear artifact-store cache and executes it with parallel agents where dependencies allow.

To review the plan:

cat {{FEATURE_DIR}}/parallel-plan.md
```

---

## Existing State Warnings

### shared.md Already Exists

When shared.md exists and not using --plan-only:

```markdown
## Warning: Existing Research Found

{{FEATURE_DIR}}/shared.md already exists.

Options:

1. Use --plan-only to skip research and use existing shared.md
2. Continue to regenerate shared.md (will overwrite)

Current state:

- shared.md: exists
- research-\*.md: [exist/missing]
```

### parallel-plan.md Already Exists

```markdown
## Warning: Existing Plan Found

{{FEATURE_DIR}}/parallel-plan.md already exists.

Continuing will overwrite the existing plan.

To preserve the existing plan, rename it first:
mv {{FEATURE_DIR}}/parallel-plan.md {{FEATURE_DIR}}/parallel-plan.backup.md
```

---

## Error Messages

### Missing Feature Name

```
Error: Feature name required

Usage: /plan-workflow [feature-name] [options]

Options:
  --research-only   Stop after research phase
  --plan-only       Skip research, use existing shared.md
  --no-checkpoint   No pause between research and planning
  --optimized       Use 7-agent optimized deployment
  --dry-run         Show execution plan without running

Example:
  /plan-workflow user-authentication
```

### Missing shared.md for --plan-only

```
Error: Cannot use --plan-only without existing shared.md

{{FEATURE_DIR}}/shared.md not found.

--plan-only never runs research inline. Either:
1. Run /shared-context {{FEATURE_NAME}} first (or: /plan-workflow {{FEATURE_NAME}} --research-only)
2. Create shared.md manually, then re-run with --plan-only
```

### Invalid Feature Name

```
Error: Invalid feature name "{{FEATURE_NAME}}"

Feature names should:
- Use kebab-case (lowercase with hyphens)
- Contain only letters, numbers, and hyphens
- Not start or end with a hyphen

Examples of valid names:
- user-authentication
- payment-integration
- api-v2-endpoints
```

## Usage Instructions

Read when the feature name is missing; abort with this complete usage block.

```
Usage: /plan-workflow [--team] [options] [--visual] [--store=local|linear] [feature-name]

Options:
  --team            (Claude Code only) Dispatch stages as agent team (default: standalone sub-agents)
  --research-only   Stop after research phase (creates shared.md only)
  --plan-only       Skip research, use existing shared.md
  --no-checkpoint   No pause between research and planning (default: checkpoint enabled)
  --optimized       Use 7-agent optimized deployment (default: 10-agent standard)
  --dry-run         Show execution plan without running
  --worktree        (legacy — now default; safe to omit) Worktree annotations emitted by default
  --no-worktree     Opt out of worktree annotations in the generated parallel-plan.md
  --visual          Render the finished plan as a visual artifact via visual-plan (local-files by default; hosted link requires --share)
  --store=local|linear  Optional artifact-store override (default: local)

Examples:
  /plan-workflow user-authentication
  /plan-workflow payment-integration --no-checkpoint
  /plan-workflow api-refactor --research-only
  /plan-workflow user-auth --plan-only
  /plan-workflow --team new-feature --optimized
  /plan-workflow --team --dry-run new-feature
  /plan-workflow add-billing-dashboard                 # worktree annotations included by default
  /plan-workflow --no-worktree add-billing-dashboard   # skip worktree annotations
  /plan-workflow --visual add-billing-dashboard        # render the finished plan as a visual artifact
```
