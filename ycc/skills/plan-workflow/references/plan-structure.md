# Parallel Plan Template

## Contents

- Complete Example Format
- Key Guidelines
- Worktree Annotations

This template provides the exact structure for a parallel implementation plan.

---

## Complete Example Format

```markdown
# [Feature Name] Implementation Plan

[3-4 sentence, information-dense breakdown of what needs to be done. Explain the core architecture changes, integration points, and overall approach. Be specific about the technical strategy.]

## Critically Relevant Files and Documentation

- /path/to/relevant/file.ext: Brief description of why this file is relevant
- /path/to/another/file.ext: How this file relates to the feature
- /path/to/pattern/example.ext: Existing pattern to follow
- /docs/architecture/component.md: Architecture documentation to reference
- /docs/api/endpoints.md: API documentation to consult

## Implementation Plan

### Phase 1: [Foundation/Setup Phase Name]

#### Task 1.1: [Descriptive Task Title] Depends on [none]

**READ THESE BEFORE TASK**

- /path/to/file.ext
- /path/to/related/file.ext
- /docs/relevant-doc.md

**Instructions**

Files to Create

- /path/to/new/file.ext
- /path/to/another/new/file.ext

Files to Modify

- /path/to/existing/file.ext
- /path/to/another/existing/file.ext

[Concise but complete instructions for implementing this task. Include:]

- Purpose of the task
- Specific implementation details
- Integration points with existing code
- Gotchas or things to watch out for
- Expected outcome

#### Task 1.2: [Another Task Title] Depends on [1.1]

**READ THESE BEFORE TASK**

- /path/to/dependency/file.ext
- /path/to/context/file.ext

**Instructions**

Files to Create

- /path/to/file.ext

Files to Modify

- /path/to/file.ext

[Implementation instructions following same pattern as above]

#### Task 1.3: [Independent Task Title] Depends on [none]

**READ THESE BEFORE TASK**

- /path/to/file.ext

**Instructions**

Files to Create

- /path/to/file.ext

Files to Modify

- /path/to/file.ext

[Implementation instructions]

### Phase 2: [Core Implementation Phase Name]

#### Task 2.1: [Task Title] Depends on [1.1, 1.2]

**READ THESE BEFORE TASK**

- /path/to/file.ext

**Instructions**

Files to Create

- /path/to/file.ext

Files to Modify

- /path/to/file.ext

[Implementation instructions]

#### Task 2.2: [Task Title] Depends on [none]

**READ THESE BEFORE TASK**

- /path/to/file.ext

**Instructions**

Files to Modify

- /path/to/file.ext

[Implementation instructions]

### Phase 3: [Integration/Testing Phase Name]

#### Task 3.1: [Task Title] Depends on [2.1]

**READ THESE BEFORE TASK**

- /path/to/file.ext

**Instructions**

Files to Modify

- /path/to/file.ext

[Implementation instructions]

## Advice

- [Specific insight about cross-cutting concerns discovered while creating this plan]
- [Warning about a subtle dependency between components]
- [Gotcha that would only be apparent from seeing the full picture]
- [Recommendation for implementation order based on risk or complexity]
- [Note about existing patterns or conventions to follow]
```

---

## Key Guidelines

### Task Structure

Each task must include:

1. **Title**: Descriptive and specific (not generic)
2. **Dependencies**: Explicit list or `[none]` for independent tasks
3. **READ THESE BEFORE TASK**: Files providing context
4. **Files to Create**: New files this task creates
5. **Files to Modify**: Existing files this task changes
6. **Instructions**: Clear, actionable implementation details

### Dependency Format

- Independent task: `Depends on [none]`
- Single dependency: `Depends on [1.1]`
- Multiple dependencies: `Depends on [1.1, 2.3, 2.5]`
- Cross-phase dependencies are allowed

### Task Granularity

- Each task should modify 1-3 files maximum
- Break larger changes into multiple tasks
- Each task should be completable in one focused session

### Parallelization

- Maximize tasks with `Depends on [none]`
- Each phase should have at least one independent task
- Avoid long dependency chains (prefer wide over deep)

### File Paths

- Use relative paths from project root
- Be specific (include actual file names, not placeholders)
- Include line numbers for targeted changes when helpful

### Advice Section

Include insights that:

- Only emerged from seeing the complete picture
- Address cross-cutting concerns
- Warn about non-obvious dependencies
- Recommend implementation strategies
- Reference existing patterns to follow

Avoid generic advice like "test thoroughly" or "follow best practices"

## Worktree Annotations

Read when generating the plan with WORKTREE_MODE=true (default); omit all worktree annotations and prompt directives with --no-worktree.

**Worktree annotations** (default — `WORKTREE_MODE=true`; skipped when `--no-worktree`): insert a `## Worktree Setup` section immediately after the title/overview and before the first batch. When `WORKTREE_MODE=false`, omit all worktree annotations. Use
`<feature-slug>` = the sanitized feature name (same as `${feature_dir}` basename).
Format exactly as defined in
`${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/worktree-strategy.md` §2:

```markdown
## Worktree Setup

- **Parent**: <repo-root>/.claude/worktrees/<repo>-<feature-slug>/ (branch: feat/<feature-slug>)
```

All tasks — parallel and sequential — share this single feature worktree. Do **not**
add a `**Children**:` list. Do **not** add per-task `**Worktree**:` lines.

> **Plan-file handoff**: in local mode (default), leave `parallel-plan.md` and `shared.md` at their resolved paths in the current checkout (default `docs/plans/<feature-slug>/`). The implementor (`ycc:implement-plan` / `ycc:prp-implement`) will **move** them into the feature worktree once created — never copied or synced. In linear mode, never move the cache; print `/ycc:implement-plan --store=linear <feature-slug>` as the next step (the implementor loads the plan from the cache). See `worktree-strategy.md` §7 and artifact-store.md "Worktrees".

**Plan-generation agent prompt** (both standalone Path A and `--team` Path B): by default (`WORKTREE_MODE=true`), append the following directive to the plan-generation prompt. Omit when `--no-worktree` was passed (`WORKTREE_MODE=false`):

> WORKTREE MODE: Annotate the generated `parallel-plan.md` with a single
> `## Worktree Setup` section (containing only the `**Parent**:` line) placed
> before the first batch, following
> `${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/worktree-strategy.md` §2.
> All tasks — parallel and sequential — share this one feature worktree path.
> Do NOT add a `**Children**:` list. Do NOT add per-task `**Worktree**:` lines.

In the `--team` Path B additionally cross-reference
`${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/agent-team-dispatch.md` §7 for
shared-worktree team dispatch: all parallel teammates operate against the same
feature worktree path, not separate per-task paths.
