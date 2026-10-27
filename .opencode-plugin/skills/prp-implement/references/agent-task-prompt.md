# PRP Implementor Task Prompt

Read once before parallel or agent-team dispatch. Substitute complete task details, not summaries.

## Prompt fields

- `agent`: `implementor`
- `description`: task title (e.g. `Task 1.1: add rate limiter middleware`)
- `prompt`: complete task spec (ACTION, IMPLEMENT, MIRROR, IMPORTS, GOTCHA, VALIDATE), plus relevant excerpt from the plan's Patterns to Mirror section.

## Prompt template

```text
Implement {{TASK_ID}}: {{TASK_TITLE}}

Plan: {{PLAN_PATH}} (absolute, read-only)
Patterns to Mirror:
{{PATTERNS_TO_MIRROR}}

Task specification:
{{TASK_SPEC}}

Read the MIRROR source file before writing code. Follow its pattern exactly,
apply GOTCHA warnings and use specified IMPORTS. Implement only this task.
Run your own type-check on modified files before reporting complete.
Report files created/modified, validation results, issues and deviations
verbatim (what changed and why).
Never edit the plan or its frontmatter, and never call Linear MCP or other
external tracker tools; report status only to the orchestrator.

{{WORKING_DIRECTORY_LINES}}
{{TEAM_COMPLETION_DIRECTIVE}}
```

`WORKING_DIRECTORY_LINES`: use shared execution-directory prompt contract, for
both parallel and sequential tasks. Treat that directory as repo root for all
writes and for reads of files not supplied by absolute path (the plan path may
lie outside it); no per-agent worktree isolation.
to call `update the todo tracker` to mark its own registered task complete.
