# Implementor Agent Task Prompt

## Contents

- Prompt Template
- Variable Reference
- Usage Instructions
- Example Populated Prompt
- Agent Configuration
- Best Practices

This template is used to deploy implementor agents for each task in the parallel plan.

---

## Prompt Template

````
Implement Task {{TASK_ID}}: {{TASK_TITLE}}

## Context

You are implementing one task from a larger feature plan. Read the context documents first to understand the overall architecture and patterns.

### Required Reading

1. **Plan Document**: {{PLAN_PATH}} (absolute, read-only)
   - Read the full plan to understand the feature
   - Focus on Task {{TASK_ID}} for your specific instructions

2. **Shared Context**: {{SHARED_PATH}} (absolute, read-only; omit when unavailable)
   - Understand the architecture and patterns
   - Note the relevant files and their purposes

3. **Task-Specific Files**:
{{FILES_TO_READ}}

## Your Task

**Task {{TASK_ID}}: {{TASK_TITLE}}**

### Files to Create
{{FILES_TO_CREATE}}

### Files to Modify
{{FILES_TO_MODIFY}}

### Instructions
{{TASK_INSTRUCTIONS}}

## Requirements

1. **Read First**: Read all required files before making changes
2. **Implement Only This Task**: Do not implement other tasks
3. **Follow Existing Patterns**: Match the codebase style and conventions
4. **Validate Changes**: Check for linting errors after modifications
5. **Report Results**: Return a summary of what you changed
6. **Orchestrator-Owned Plan and Status**: Never edit the plan or its frontmatter, and never call Linear MCP or other external tracker tools. Report status only to the orchestrator. Read the supplied absolute plan/context paths even if the cache is outside your working directory; all implementation writes stay in the assigned working directory.

## Output Format

After completing the task, provide:

```markdown
## Task {{TASK_ID}} Complete

### Files Created
- /path/to/file.ext

### Files Modified
- /path/to/file.ext: Description of changes

### Validation
- Linting: [Pass/Fail]
- Issues: [None or list issues]

### Notes
[Any important observations or warnings]
````

```

---

## Variable Reference

| Variable | Description | Example |
|----------|-------------|---------|
| `{{PLAN_PATH}}` | Canonical absolute plan path; linear cache is not moved into the feature worktree | `/repo/.ycc/artifacts/user-authentication/parallel-plan.md` |
| `{{SHARED_PATH}}` | Absolute companion context path; omit its reading item when absent | `/repo/.ycc/artifacts/user-authentication/shared.md` |
| `{{TASK_ID}}` | Task identifier | `1.1`, `2.3` or `T0`, `T1` |
| `{{TASK_TITLE}}` | Task title from plan | `Create user model` |
| `{{FILES_TO_READ}}` | Files from "READ THESE BEFORE TASK" | `- /src/models/base.ts` |
| `{{FILES_TO_CREATE}}` | Files from "Files to Create" | `- /src/models/user.ts` |
| `{{FILES_TO_MODIFY}}` | Files from "Files to Modify" | `- /src/index.ts` |
| `{{TASK_INSTRUCTIONS}}` | Implementation instructions | Detailed task steps |

---

## Usage Instructions

When deploying an implementor agent:

1. **Read the task** from parallel-plan.md
2. **Extract all variables** from the task section
3. **Substitute variables** in this template
4. **Deploy agent** with:
   - `subagent_type`: `implementor`
   - `description`: "Implement {{TASK_ID}}: {{TASK_TITLE}}"
   - `prompt`: The substituted template

---

## Example Populated Prompt

```

Implement Task 1.1: Create user model

## Context

You are implementing one task from a larger feature plan. Read the context documents first to understand the overall architecture and patterns.

### Required Reading

1. **Plan Document**: /repo/.ycc/artifacts/user-authentication/parallel-plan.md (absolute, read-only)
   - Read the full plan to understand the feature
   - Focus on Task 1.1 for your specific instructions

2. **Shared Context**: /repo/.ycc/artifacts/user-authentication/shared.md (absolute, read-only)
   - Understand the architecture and patterns
   - Note the relevant files and their purposes

3. **Task-Specific Files**:
   - /src/models/base-model.ts
   - /src/types/user.ts
   - /docs/architecture/models.md

## Your Task

**Task 1.1: Create user model**

### Files to Create

- /src/models/user.ts

### Files to Modify

- /src/models/index.ts

### Instructions

Create a new User model following the BaseModel pattern:

1. Create /src/models/user.ts with:
   - User class extending BaseModel
   - Fields: id, email, passwordHash, createdAt, updatedAt
   - Methods: validateEmail(), hashPassword()

2. Update /src/models/index.ts:
   - Export the new User model

Follow the pattern in /src/models/base-model.ts for consistency.

## Requirements

1. **Read First**: Read all required files before making changes
2. **Implement Only This Task**: Do not implement other tasks
3. **Follow Existing Patterns**: Match the codebase style and conventions
4. **Validate Changes**: Check for linting errors after modifications
5. **Report Results**: Return a summary of what you changed
6. **Orchestrator-Owned Plan and Status**: Never edit the plan or its frontmatter, and never call Linear MCP or other external tracker tools. Report status only to the orchestrator. The supplied absolute plan/context paths may be outside your working directory; implementation writes stay in the assigned working directory.

## Output Format

After completing the task, provide:

```markdown
## Task 1.1 Complete

### Files Created

- /src/models/user.ts

### Files Modified

- /src/models/index.ts: Added User export

### Validation

- Linting: Pass
- Issues: None

### Notes

Followed BaseModel pattern exactly. User model ready for validation task 1.2.
```

```

---

## Agent Configuration

| Setting | Value |
|---------|-------|
| Subagent Type | `implementor` |
| Readonly | No (must modify files) |
| Model | Default |

## Best Practices

1. **One Task Per Agent**: Each agent implements exactly one task
2. **Include All Context**: Provide complete file paths and instructions
3. **Clear Boundaries**: Make it obvious what is in scope vs out of scope
4. **Validation Required**: Agents must check their work before returning
```
