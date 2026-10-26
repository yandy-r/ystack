# Research Agent Prompts

## Contents

- Global Output Contract
- Agent 1: Architecture Researcher
- Agent 2: Pattern Researcher
- Agent 3: Integration Researcher
- Agent 4: Documentation Researcher
- Usage Instructions
- Variable Reference
- Teammate Configuration

These prompts are used to spawn research teammates for gathering shared context. This is Phase 1 of the unified planning workflow. Teammates share findings with each other via messages.

## Global Output Contract

Apply this contract to every teammate prompt in this file:

- Write only your assigned `{{RESEARCH_<LENS>_FILE}}`; the orchestrator resolves it with the artifact-store `research-<lens>` kind.
- When replacing an existing file in linear mode, preserve its frontmatter and replace only the body. The orchestrator performs the Linear Save; do not call Linear yourself.
- Do not edit any other files.
- After writing the file, verify it exists using the Read tool or equivalent.
- **Share key findings** with relevant teammates using SendMessage.
- After writing the file and sharing findings, mark your task as complete using `todo`.

---

## Agent 1: Architecture Researcher

**Teammate Name**: `architecture-researcher`

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Analyze system architecture

**Prompt Template**:

````markdown
Research the codebase architecture relevant to implementing "{{FEATURE_NAME}}".

## Your Task

Analyze the codebase to understand:

1. **System Structure**
   - What are the main components/modules involved?
   - How is the codebase organized (directories, layers)?
   - What frameworks or libraries are in use?

2. **Data Flow**
   - How does data flow through the system?
   - What are the entry points (APIs, events, etc.)?
   - Where is business logic concentrated?

3. **Component Relationships**
   - How do components communicate?
   - What are the key dependencies?
   - Are there shared services or utilities?

4. **Integration Points**
   - Where would new feature code plug in?
   - What existing components would be affected?

## Team Communication

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `SendMessage` or `todo`, ignore this section entirely and just write your output file.

You are part of a research team. Your teammates are:

- **patterns-researcher**: Researching code patterns and conventions
- **integration-researcher**: Researching APIs, databases, external systems
- **docs-researcher**: Finding relevant documentation

**Share these findings via SendMessage:**

- Message `patterns-researcher` with: architectural patterns you discover (service layers, repository patterns, etc.) and their file locations
- Message `integration-researcher` with: any API endpoints, database connections, or external service integrations you find during architecture analysis
- Message `docs-researcher` with: any architecture documentation files or inline docs you encounter

## Task Coordination

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `todo`, ignore this section entirely; the orchestrator gates on the artifact file existing on disk.

1. Check todo for your assigned task
2. Claim your task with todo (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with teammates
5. Write your output file
6. Mark your task complete with todo

## Output Requirements

**CRITICAL**: You MUST write your findings to the specified file. This is not optional.

**Output File**: {{RESEARCH_ARCHITECTURE_FILE}}

Before completing this task:

1. Create the output file using the Write tool
2. Verify the file was created successfully
3. Share key findings with teammates
4. Mark your task as complete

Structure your report as:

```markdown
# Architecture Research: {{FEATURE_NAME}}

## System Overview

[2-3 sentences on overall architecture]

## Relevant Components

- /path/to/component: Description of role
- /path/to/another: Description of role

## Data Flow

[Describe how data moves through relevant parts]

## Integration Points

[Where new code should connect]

## Key Dependencies

[External libraries, services, or internal modules]
```

Focus on areas directly relevant to {{FEATURE_NAME}}. Be specific with file paths.
````

---

## Agent 2: Pattern Researcher

**Teammate Name**: `patterns-researcher`

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Identify coding patterns

**Prompt Template**:

````markdown
Research the coding patterns and conventions used in this codebase that are relevant to implementing "{{FEATURE_NAME}}".

## Your Task

Identify and document:

1. **Architectural Patterns**
   - Repository pattern, service layer, etc.
   - How are similar features structured?
   - What abstraction patterns are used?

2. **Code Conventions**
   - Naming conventions (files, functions, classes)
   - File organization within modules
   - Import/export patterns

3. **Error Handling**
   - How are errors propagated?
   - What error types are used?
   - Logging conventions

4. **Testing Patterns**
   - How are similar features tested?
   - Test file organization
   - Mocking patterns

## Team Communication

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `SendMessage` or `todo`, ignore this section entirely and just write your output file.

You are part of a research team. Your teammates are:

- **architecture-researcher**: Analyzing system structure and components
- **integration-researcher**: Researching APIs, databases, external systems
- **docs-researcher**: Finding relevant documentation

**Share these findings via SendMessage:**

- Message `integration-researcher` with: any API patterns, middleware patterns, or database access patterns you discover
- Message `architecture-researcher` with: any structural patterns that affect the overall architecture analysis

**Listen for messages from teammates** — especially from `architecture-researcher` who may share architectural patterns they found that you should investigate deeper.

## Task Coordination

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `todo`, ignore this section entirely; the orchestrator gates on the artifact file existing on disk.

1. Check todo for your assigned task
2. Claim your task with todo (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with teammates
5. Write your output file
6. Mark your task complete with todo

## Output Requirements

**CRITICAL**: You MUST write your findings to the specified file. This is not optional.

**Output File**: {{RESEARCH_PATTERNS_FILE}}

Before completing this task:

1. Create the output file using the Write tool
2. Verify the file was created successfully
3. Share key findings with teammates
4. Mark your task as complete

Structure your report as:

```markdown
# Pattern Research: {{FEATURE_NAME}}

## Architectural Patterns

**Pattern Name**: Description of how it's used

- Example: /path/to/example.ext

**Another Pattern**: Description

- Example: /path/to/example.ext

## Code Conventions

[Naming, organization, style conventions]

## Error Handling

[How errors are handled in similar code]

## Testing Approach

[How to test similar features]

## Patterns to Follow

[Specific patterns that should be used for this feature]
```

Find concrete examples for each pattern. Include file paths.
````

---

## Agent 3: Integration Researcher

**Teammate Name**: `integration-researcher`

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Research APIs and data sources

**Prompt Template**:

````markdown
Research the APIs, databases, and external integrations relevant to implementing "{{FEATURE_NAME}}".

## Your Task

Investigate:

1. **API Endpoints**
   - What existing endpoints are related?
   - How are routes organized?
   - What middleware is used?

2. **Database Schema**
   - What tables are involved?
   - What are the relationships?
   - Are there migrations to reference?

3. **External Services**
   - What third-party services are used?
   - How are they integrated?
   - What credentials/config is needed?

4. **Internal Services**
   - What internal services are called?
   - How is inter-service communication handled?

## Team Communication

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `SendMessage` or `todo`, ignore this section entirely and just write your output file.

You are part of a research team. Your teammates are:

- **architecture-researcher**: Analyzing system structure and components
- **patterns-researcher**: Researching code patterns and conventions
- **docs-researcher**: Finding relevant documentation

**Share these findings via SendMessage:**

- Message `architecture-researcher` with: any service boundaries, data flow patterns, or component dependencies you discover through API/database analysis
- Message `patterns-researcher` with: any middleware patterns, database access patterns, or API conventions you find
- Message `docs-researcher` with: any API documentation, schema documentation, or configuration docs you encounter

**Listen for messages from teammates** — especially from `architecture-researcher` and `patterns-researcher` who may share relevant integration points.

## Task Coordination

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `todo`, ignore this section entirely; the orchestrator gates on the artifact file existing on disk.

1. Check todo for your assigned task
2. Claim your task with todo (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with teammates
5. Write your output file
6. Mark your task complete with todo

## Output Requirements

**CRITICAL**: You MUST write your findings to the specified file. This is not optional.

**Output File**: {{RESEARCH_INTEGRATION_FILE}}

Before completing this task:

1. Create the output file using the Write tool
2. Verify the file was created successfully
3. Share key findings with teammates
4. Mark your task as complete

Structure your report as:

```markdown
# Integration Research: {{FEATURE_NAME}}

## API Endpoints

### Existing Related Endpoints

- GET /api/path: Description
- POST /api/path: Description

### Route Organization

[How routes are structured]

## Database

### Relevant Tables

- table_name: Description of data
- another_table: Description

### Schema Details

[Key columns, relationships, indexes]

## External Services

[Third-party integrations relevant to feature]

## Internal Services

[Internal services that may be called]

## Configuration

[Environment variables, config files needed]
```

Be thorough with database schema - this informs data modeling decisions.
````

---

## Agent 4: Documentation Researcher

**Teammate Name**: `docs-researcher`

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Find relevant documentation

**Prompt Template**:

````markdown
Find all documentation files relevant to implementing "{{FEATURE_NAME}}".

## Your Task

Search for documentation in:

1. **docs/ Directory**
   - Architecture documentation
   - API documentation
   - Feature guides
   - Development guides

2. **README Files**
   - Root README.md
   - Directory-level READMEs
   - Module READMEs

3. **Code Comments**
   - Well-documented modules
   - API documentation in code
   - Configuration documentation

4. **External References**
   - Links to external docs in code
   - Referenced specifications
   - Library documentation needs

## Team Communication

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `SendMessage` or `todo`, ignore this section entirely and just write your output file.

You are part of a research team. Your teammates are:

- **architecture-researcher**: Analyzing system structure and components
- **patterns-researcher**: Researching code patterns and conventions
- **integration-researcher**: Researching APIs, databases, external systems

**Share these findings via SendMessage:**

- Message `architecture-researcher` with: any architecture documentation you find (design docs, ADRs, system diagrams)
- Message `patterns-researcher` with: any coding guidelines, style guides, or convention documentation
- Message `integration-researcher` with: any API documentation, database documentation, or integration guides

**Listen for messages from teammates** — they may point you to documentation files they encountered during their research.

## Task Coordination

> **Path B (`--team`) only — skip in standalone (Path A) mode.** If you do not have access to `todo`, ignore this section entirely; the orchestrator gates on the artifact file existing on disk.

1. Check todo for your assigned task
2. Claim your task with todo (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with teammates
5. Write your output file
6. Mark your task complete with todo

## Output Requirements

**CRITICAL**: You MUST write your findings to the specified file. This is not optional.

**Output File**: {{RESEARCH_DOCS_FILE}}

Before completing this task:

1. Create the output file using the Write tool
2. Verify the file was created successfully
3. Share key findings with teammates
4. Mark your task as complete

Structure your report as:

```markdown
# Documentation Research: {{FEATURE_NAME}}

## Architecture Docs

- /docs/path/file.md: What it covers

## API Docs

- /docs/api/file.md: What it covers

## Development Guides

- /docs/dev/file.md: What it covers

## README Files

- /path/README.md: What it covers

## Must-Read Documents

[List documents that implementers MUST read, with topics]

## Documentation Gaps

[Areas where documentation is missing or outdated]
```

Focus on documents that would help someone implement {{FEATURE_NAME}}.
Identify which documents are REQUIRED reading vs nice-to-have.
````

---

## Usage Instructions

When spawning research teammates:

1. **Read this file** to get the prompt templates
2. **Substitute variables**:
   - `{{FEATURE_NAME}}` - The feature directory name (e.g., `user-authentication`)
   - `{{RESEARCH_<LENS>_FILE}}` - The absolute path resolved for kind `research-<lens>` (local example: `docs/plans/user-authentication/research-<lens>.md`)
3. **Create tasks** - Use `todo` to create research tasks
4. **Spawn in parallel** - Use a single message with multiple `task` tool calls, each with `name`
5. **Monitor progress** - Call `wait` until every spawned job settles
6. **Verify artifacts** - Check all research files exist on disk
7. **Shut down teammates** - Send shutdown requests via SendMessage
8. **Read results** - Review each research file before writing shared.md

## Variable Reference

| Variable                   | Description                   | Example                                                                                                                              |
| -------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `{{FEATURE_NAME}}`         | Feature directory name        | `user-authentication`                                                                                                                |
| `{{RESEARCH_<LENS>_FILE}}` | Absolute research output path | Local: `docs/plans/user-authentication/research-<lens>.md`; linear: `.ycc/artifacts/user-authentication/research/research-<lens>.md` |

## Teammate Configuration

| Teammate                | Type                        | Output File              | Model  |
| ----------------------- | --------------------------- | ------------------------ | ------ |
| architecture-researcher | `codebase-research-analyst` | research-architecture.md | sonnet |
| patterns-researcher     | `codebase-research-analyst` | research-patterns.md     | sonnet |
| integration-researcher  | `codebase-research-analyst` | research-integration.md  | sonnet |
| docs-researcher         | `codebase-research-analyst` | research-docs.md         | sonnet |
