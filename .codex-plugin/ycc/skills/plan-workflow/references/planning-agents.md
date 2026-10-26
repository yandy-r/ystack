## Native prompt substitution

Before forwarding any prompt, replace every `<installed ycc plugin root>` with the absolute installed ycc plugin root (resolve `../../..` from this document's directory). Forward only absolute resource paths; keep the user's project as cwd.

# Planning Agent Prompts

## Contents

- Global Output Contract
- Agent 1: Context Synthesizer
- Agent 2: Code Analyzer
- Agent 3: Task Structure Agent
- Usage Instructions
- Teammate Configuration
- Expected Output Size

These prompts are used to spawn analysis teammates for condensing planning context before generating the parallel implementation plan. This is Phase 5 of the unified planning workflow (standard mode only). Teammates share findings with each other via messages.

## Global Output Contract

Apply this contract to every teammate prompt in this file:

- Write only your assigned `{{ANALYSIS_<NAME>_FILE}}`; the orchestrator resolves it with the artifact-store `analysis-<name>` kind. Analysis artifacts remain local-only in linear mode.
- Do not edit any other files.
- After writing the file, verify it exists using the Read tool or equivalent.
- **Share key findings** with relevant teammates using send follow-up instructions.
- After writing the file and sharing findings, mark your task as complete using update the task tracker.

---

## Agent 1: Context Synthesizer

**Teammate Name**: `context-synthesizer`

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Synthesize planning context

**Prompt Template**:

````markdown
## PRIMARY DELIVERABLE

**Output File**: {{ANALYSIS_CONTEXT_FILE}}

You MUST write this file using the Write tool. This is your #1 job. Everything else is secondary.

## DO NOT SKIP THE WRITE

`analysis-context.md` is a REQUIRED PLANNING ARTIFACT, not implementation code or source code. The orchestrator gates on this file existing on disk via `persist-or-fail.sh` and will re-dispatch you if it is missing. You MUST call the Write tool to create the file at the path above. Do not ask for confirmation. Do not return findings as a Task result without writing. The path is fixed and provided — use it as-is.

---

Synthesize and condense all planning documentation for the "{{FEATURE_NAME}}" feature into an
actionable summary.

## Your Task

Read and analyze all planning documentation:

1. **Core Planning Documents**
   - {{FEATURE_DIR}}/shared.md
   - {{FEATURE_DIR}}/requirements.md (if exists)
   - All other .md files in {{FEATURE_DIR}}/, plus research files in {{RESEARCH_DIR}}/ when it differs from {{FEATURE_DIR}}/

2. **Extract Key Information**
   - Architecture decisions relevant to implementation
   - Critical files that must be referenced
   - Existing patterns that must be followed
   - Integration points and dependencies
   - Constraints and gotchas

3. **Synthesize Don't Summarize**
   - Focus on information that directly informs task breakdown
   - Extract actionable insights, not just descriptions
   - Identify cross-cutting concerns
   - Highlight potential parallelization opportunities

## Team Communication

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `send follow-up instructions`, `update the task tracker`, or `the task tracker`, ignore this section entirely and just write your output file.

You are part of an analysis team. Your teammates are:

- **code-analyzer**: Extracting code patterns from relevant files
- **task-structurer**: Suggesting task breakdown and phases

**Share these findings via send follow-up instructions:**

- Message `code-analyzer` with: critical files you identify that they should prioritize reading, and any architectural patterns or conventions that affect code analysis
- Message `task-structurer` with: cross-cutting concerns, parallelization opportunities, and constraints that should influence task breakdown

**Listen for messages from teammates** — `code-analyzer` may share patterns that affect your synthesis, and `task-structurer` may ask for clarification on scope.

## Task Coordination

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `the task tracker` / `update the task tracker`, ignore this section entirely; the orchestrator gates on the artifact file existing on disk.

1. Check the task tracker for your assigned task
2. Claim your task with update the task tracker (set status to in_progress, owner to your name)
3. Do your analysis
4. Share findings with teammates
5. Write your output file
6. Mark your task complete with update the task tracker

## Output Format

Structure your report as:

```markdown
# Context Analysis: {{FEATURE_NAME}}

## Executive Summary

[2-3 sentences: What is being built and the core architectural approach]

## Architecture Context

- **System Structure**: [How the relevant components are organized]
- **Data Flow**: [Key data flow patterns relevant to this feature]
- **Integration Points**: [Where new code plugs into existing system]

## Critical Files Reference

- /path/to/file: [Why critical - 1 sentence]
- /path/to/another: [Why critical - 1 sentence]

## Patterns to Follow

- **Pattern Name**: [Description with example file path]
- **Another Pattern**: [Description with example file path]

## Cross-Cutting Concerns

- [Security, performance, testing, or other concerns that affect multiple tasks]

## Parallelization Opportunities

- [Areas where work can be done independently]
- [Shared files or components that need coordination]

## Implementation Constraints

- [Technical constraints (APIs, libraries, etc.)]
- [Business constraints (must maintain X, cannot break Y)]

## Key Recommendations

- [Specific advice for task breakdown]
- [Suggested phase organization]
- [Dependency management suggestions]
```

Be concise. Each bullet should be information-dense. Aim for 60-80% compression versus reading all source documents directly.

## Completion Checklist

You MUST complete ALL of these steps in order:

1. **Write file**: Use the Write tool to create {{ANALYSIS_CONTEXT_FILE}}
2. **Verify file**: Use the Read tool to confirm the file exists and has content
3. **Share findings**: Message teammates with key insights
4. **Mark complete**: Update your task status to completed
````

---

## Agent 2: Code Analyzer

**Teammate Name**: `code-analyzer`

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Analyze relevant code files

**Prompt Template**:

````markdown
## PRIMARY DELIVERABLE

**Output File**: {{ANALYSIS_CODE_FILE}}

You MUST write this file using the Write tool. This is your #1 job. Everything else is secondary.

## DO NOT SKIP THE WRITE

`analysis-code.md` is a REQUIRED PLANNING ARTIFACT, not implementation code or source code. The orchestrator gates on this file existing on disk via `persist-or-fail.sh` and will re-dispatch you if it is missing. You MUST call the Write tool to create the file at the path above. Do not ask for confirmation. Do not return findings as a Task result without writing. The path is fixed and provided — use it as-is.

---

Analyze the critically relevant code files for implementing "{{FEATURE_NAME}}" and extract
actionable patterns and integration points.

## Your Task

Read and analyze code files identified in the planning documents:

1. **Read Source Files**
   - First, read {{FEATURE_DIR}}/shared.md to find "Relevant Files"
   - Read each file listed in that section
   - Note: Focus on files that inform implementation patterns, not every possible file

2. **Extract Code Patterns**
   - How are similar features structured?
   - What are the naming conventions?
   - How is error handling done?
   - What testing patterns are used?
   - How are dependencies injected?

3. **Identify Integration Points**
   - Where will new code connect?
   - What interfaces exist?
   - What services/utilities are available?
   - What needs to be modified vs created?

4. **Document Code Structure**
   - File organization patterns
   - Module boundaries
   - Import/export patterns
   - Configuration patterns

## Team Communication

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `send follow-up instructions`, `update the task tracker`, or `the task tracker`, ignore this section entirely and just write your output file.

You are part of an analysis team. Your teammates are:

- **context-synthesizer**: Condensing planning documentation
- **task-structurer**: Suggesting task breakdown and phases

**Share these findings via send follow-up instructions:**

- Message `context-synthesizer` with: any patterns or architectural insights that should be reflected in the context synthesis
- Message `task-structurer` with: file-to-task mapping suggestions, files that should be grouped together, and any dependency relationships between code modules

**Listen for messages from teammates** — especially from `context-synthesizer` who may point you to critical files to prioritize.

## Task Coordination

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `the task tracker` / `update the task tracker`, ignore this section entirely; the orchestrator gates on the artifact file existing on disk.

1. Check the task tracker for your assigned task
2. Claim your task with update the task tracker (set status to in_progress, owner to your name)
3. Do your analysis
4. Share findings with teammates
5. Write your output file
6. Mark your task complete with update the task tracker

## Output Format

Structure your report as:

```markdown
# Code Analysis: {{FEATURE_NAME}}

## Executive Summary

[2-3 sentences: Current code structure and how new feature fits]

## Existing Code Structure

### Related Components

- /path/to/component: [Role and relevance - 1 sentence]
- /path/to/another: [Role and relevance - 1 sentence]

### File Organization Pattern

[How similar features are organized in the codebase]

## Implementation Patterns

### Pattern: [Pattern Name]

**Description**: [How this pattern is used - 1-2 sentences]
**Example**: See `/path/to/example.ext` lines X-Y
**Apply to**: [Which tasks should use this pattern]

### Pattern: [Another Pattern]

**Description**: [How this pattern is used - 1-2 sentences]
**Example**: See `/path/to/example.ext` lines X-Y
**Apply to**: [Which tasks should use this pattern]

## Integration Points

### Files to Create

- /path/to/new/file: [Purpose and where it fits]

### Files to Modify

- /path/to/existing/file: [What kind of changes needed]
- /path/to/another/file: [What kind of changes needed]

## Code Conventions

### Naming

[File naming, function naming, class naming patterns]

### Error Handling

[How errors are handled in similar code]

### Testing

[Testing patterns and file organization]

## Dependencies and Services

### Available Utilities

- Utility/Service: [What it provides]

### Required Dependencies

- Package/module: [Why needed]

## Gotchas and Warnings

- [Non-obvious issues discovered in existing code]
- [Common pitfalls to avoid]
- [Breaking changes to watch for]

## Task-Specific Guidance

- **For database tasks**: [Specific patterns to follow]
- **For API tasks**: [Specific patterns to follow]
- **For UI tasks**: [Specific patterns to follow]
```

Focus on patterns that inform implementation. Extract actual code patterns, not just file listings.

## Completion Checklist

You MUST complete ALL of these steps in order:

1. **Write file**: Use the Write tool to create {{ANALYSIS_CODE_FILE}}
2. **Verify file**: Use the Read tool to confirm the file exists and has content
3. **Share findings**: Message teammates with key insights
4. **Mark complete**: Update your task status to completed
````

---

## Agent 3: Task Structure Agent

**Teammate Name**: `task-structurer`

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Suggest task structure

**Prompt Template**:

````markdown
## PRIMARY DELIVERABLE

**Output File**: {{ANALYSIS_TASKS_FILE}}

You MUST write this file using the Write tool. This is your #1 job. Everything else is secondary.

## DO NOT SKIP THE WRITE

`analysis-tasks.md` is a REQUIRED PLANNING ARTIFACT, not implementation code or source code. The orchestrator gates on this file existing on disk via `persist-or-fail.sh` and will re-dispatch you if it is missing. You MUST call the Write tool to create the file at the path above. Do not ask for confirmation. Do not return findings as a Task result without writing. The path is fixed and provided — use it as-is.

---

Analyze the codebase structure and planning documents for "{{FEATURE_NAME}}" to suggest an optimal
task breakdown and phase organization.

## Your Task

Based on the codebase structure and planning context:

1. **Understand Feature Scope**
   - Read {{FEATURE_DIR}}/shared.md
   - Read {{FEATURE_DIR}}/requirements.md (if exists)
   - Understand what components are affected

2. **Analyze Codebase Structure**
   - Explore directories relevant to the feature
   - Identify natural module boundaries
   - Find similar features for reference
   - Understand dependency relationships

3. **Suggest Task Organization**
   - Logical phases for implementation
   - Natural task boundaries (based on files/modules)
   - Which tasks can run in parallel
   - Which tasks have dependencies
   - Appropriate granularity (1-3 files per task)

4. **Consider Implementation Order**
   - Foundation tasks (models, schemas, types)
   - Core logic tasks (services, handlers)
   - Integration tasks (API, UI, tests)
   - Documentation tasks

5. **Label Parallel vs Sequential** - In your output, clearly label each task as **parallel** (can run concurrently with siblings) or **sequential** (must follow a predecessor). The orchestrator uses this labeling for batch ordering. Follow `<installed ycc plugin root>/shared/references/worktree-strategy.md` for the single-worktree contract.

## Team Communication

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `send follow-up instructions`, `update the task tracker`, or `the task tracker`, ignore this section entirely and just write your output file.

You are part of an analysis team. Your teammates are:

- **context-synthesizer**: Condensing planning documentation
- **code-analyzer**: Extracting code patterns from relevant files

**Share these findings via send follow-up instructions:**

- Message `context-synthesizer` with: any scope clarifications or missing context you identify while analyzing the codebase
- Message `code-analyzer` with: specific files you think are important for pattern analysis that they may not have found yet

**Listen for messages from teammates** — especially from `code-analyzer` who may share file-to-task mapping insights, and from `context-synthesizer` who may share parallelization opportunities and constraints.

## Task Coordination

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `the task tracker` / `update the task tracker`, ignore this section entirely; the orchestrator gates on the artifact file existing on disk.

1. Check the task tracker for your assigned task
2. Claim your task with update the task tracker (set status to in_progress, owner to your name)
3. Do your analysis
4. Share findings with teammates
5. Write your output file
6. Mark your task complete with update the task tracker

## Output Format

Structure your report as:

```markdown
# Task Structure Analysis: {{FEATURE_NAME}}

## Executive Summary

[2-3 sentences: Suggested approach for breaking down implementation]

## Recommended Phase Structure

### Phase 1: [Foundation/Setup Phase Name]

**Purpose**: [What this phase establishes]
**Suggested Tasks**: [3-5 task descriptions at high level]
**Parallelization**: [How many can run in parallel]

### Phase 2: [Core Implementation Phase Name]

**Purpose**: [What this phase builds]
**Suggested Tasks**: [3-5 task descriptions at high level]
**Dependencies**: [What from Phase 1 is needed]
**Parallelization**: [How many can run in parallel]

### Phase 3: [Integration/Testing Phase Name]

**Purpose**: [What this phase completes]
**Suggested Tasks**: [3-5 task descriptions at high level]
**Dependencies**: [What from Phase 2 is needed]

## Task Granularity Recommendations

### Appropriate Task Sizes

- Example: "Create user model and validation" (1-2 files)
- Example: "Add authentication middleware" (1 file)
- Example: "Implement login endpoint" (1-2 files)

### Tasks to Split

- [If you see any task that's too large, suggest how to split it]

### Tasks to Combine

- [If you see any task that's too small, suggest combinations]

## Dependency Analysis

### Independent Tasks (Can Run in Parallel)

- Task: [Description] - File(s): [paths]
- Task: [Description] - File(s): [paths]

### Sequential Dependencies

- Task A must complete before Task B because: [reason]
- Task C must complete before Task D because: [reason]

### Potential Bottlenecks

- [Tasks that many others depend on]
- [Shared files that could create conflicts]

## File-to-Task Mapping

### Files to Create

| File              | Suggested Task   | Phase | Dependencies     |
| ----------------- | ---------------- | ----- | ---------------- |
| /path/to/new/file | Task description | 1     | none             |
| /path/to/another  | Task description | 2     | Phase 1 complete |

### Files to Modify

| File              | Suggested Task   | Phase | Dependencies |
| ----------------- | ---------------- | ----- | ------------ |
| /path/to/existing | Task description | 2     | Phase 1      |
| /path/to/another  | Task description | 3     | Phase 2      |

## Optimization Opportunities

### Maximize Parallelism

- [Suggestions for independent tasks]
- [Ways to reduce dependency chains]

### Minimize Risk

- [Critical path tasks that need extra attention]
- [High-risk changes that should be isolated]

## Implementation Strategy Recommendations

- [Advice on order: bottom-up vs top-down]
- [Testing strategy: when to write tests]
- [Integration approach: how to wire components together]
```

Focus on actionable structure suggestions. The goal is to help organize the parallel plan, not to write the plan itself.

## Completion Checklist

You MUST complete ALL of these steps in order:

1. **Write file**: Use the Write tool to create {{ANALYSIS_TASKS_FILE}}
2. **Verify file**: Use the Read tool to confirm the file exists and has content
3. **Share findings**: Message teammates with key insights
4. **Mark complete**: Update your task status to completed
````

---

## Usage Instructions

When spawning analysis teammates:

1. **Read this file** to get the prompt templates
2. **Substitute variables**:
   - `{{FEATURE_NAME}}` - The feature directory name
   - `{{FEATURE_DIR}}` - Resolved feature directory (`${feature_dir}`, resolved in Step 2)
   - `{{RESEARCH_DIR}}` - Resolved research directory (`${research_dir}`; equals `${feature_dir}` in local mode)
   - `{{ANALYSIS_<NAME>_FILE}}` - Absolute output path resolved for kind `analysis-<name>`
3. **Create tasks** - Use record the task to create 3 analysis tasks
4. **Spawn in parallel** - Use a single message with 3 parallel agent runs, each with `name`
5. **Monitor progress** - Use the task tracker to check when all tasks complete
6. **Verify artifacts** - Check all analysis files exist on disk
7. **Shut down teammates** - Send shutdown requests via send follow-up instructions
8. **Read condensed outputs** - Review the 3 analysis files before creating parallel-plan.md

## Teammate Configuration

| Teammate            | Type                        | Output File         | Model  |
| ------------------- | --------------------------- | ------------------- | ------ |
| context-synthesizer | `codebase-research-analyst` | analysis-context.md | sonnet |
| code-analyzer       | `codebase-research-analyst` | analysis-code.md    | sonnet |
| task-structurer     | `codebase-research-analyst` | analysis-tasks.md   | sonnet |

## Expected Output Size

Each analysis file should be:

- **Condensed**: 60-80% smaller than reading source files directly
- **Actionable**: Focus on what informs task breakdown
- **Structured**: Follow the output format exactly for consistent consumption

Total context consumption: ~5-10K tokens (vs 50-100K+ reading files directly)
