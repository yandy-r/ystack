# Research Agent Prompts

## Contents

- Global Output Contract
- Agent 1: Architecture Researcher
- Agent 2: Pattern Researcher
- Agent 3: Integration Researcher
- Agent 4: Documentation Researcher
- Usage Instructions
- Variable Reference
- Sub-agent Configuration

These prompts are used to spawn research sub-agents for gathering shared context. This is Phase 1 of the unified planning workflow. Sub-agents share findings with each other via messages.

## Global Output Contract

Apply this contract to every sub-agent prompt in this file:

- Write only your assigned `{{RESEARCH_<LENS>_FILE}}`; the orchestrator resolves it with the artifact-store `research-<lens>` kind.
- When replacing an existing file in linear mode, preserve its frontmatter and replace only the body. The orchestrator performs the Linear Save; do not call Linear yourself.
- Do not edit any other files.
- After writing the file, verify it exists using the Read tool or equivalent.
- **Share key findings** with relevant sub-agents using re-dispatch the affected sub-agent with the needed guidance.
- After writing the file and sharing findings, mark your task as complete using update the todo tracker.

---

## Agent 1: Architecture Researcher

**Sub-agent Role**: `architecture-researcher`

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

## Task Coordination


1. Check the todo tracker for your assigned task
2. Claim your task with update the todo tracker (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with sub-agents
5. Write your output file
6. Mark your task complete with update the todo tracker

## Output Requirements

**CRITICAL**: You MUST write your findings to the specified file. This is not optional.

**Output File**: {{RESEARCH_ARCHITECTURE_FILE}}

Before completing this task:

1. Create the output file using the Write tool
2. Verify the file was created successfully
3. Share key findings with sub-agents
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

**Sub-agent Role**: `patterns-researcher`

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

## Task Coordination


1. Check the todo tracker for your assigned task
2. Claim your task with update the todo tracker (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with sub-agents
5. Write your output file
6. Mark your task complete with update the todo tracker

## Output Requirements

**CRITICAL**: You MUST write your findings to the specified file. This is not optional.

**Output File**: {{RESEARCH_PATTERNS_FILE}}

Before completing this task:

1. Create the output file using the Write tool
2. Verify the file was created successfully
3. Share key findings with sub-agents
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

**Sub-agent Role**: `integration-researcher`

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

## Task Coordination


1. Check the todo tracker for your assigned task
2. Claim your task with update the todo tracker (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with sub-agents
5. Write your output file
6. Mark your task complete with update the todo tracker

## Output Requirements

**CRITICAL**: You MUST write your findings to the specified file. This is not optional.

**Output File**: {{RESEARCH_INTEGRATION_FILE}}

Before completing this task:

1. Create the output file using the Write tool
2. Verify the file was created successfully
3. Share key findings with sub-agents
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

**Sub-agent Role**: `docs-researcher`

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

## Task Coordination


1. Check the todo tracker for your assigned task
2. Claim your task with update the todo tracker (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with sub-agents
5. Write your output file
6. Mark your task complete with update the todo tracker

## Output Requirements

**CRITICAL**: You MUST write your findings to the specified file. This is not optional.

**Output File**: {{RESEARCH_DOCS_FILE}}

Before completing this task:

1. Create the output file using the Write tool
2. Verify the file was created successfully
3. Share key findings with sub-agents
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

When spawning research sub-agents:

1. **Read this file** to get the prompt templates
2. **Substitute variables**:
   - `{{FEATURE_NAME}}` - The feature directory name (e.g., `user-authentication`)
   - `{{RESEARCH_<LENS>_FILE}}` - The absolute path resolved for kind `research-<lens>` (local example: `docs/plans/user-authentication/research-<lens>.md`)
3. **Create tasks** - Use track the task to create research tasks
5. **Monitor progress** - Use the todo tracker to check when all tasks complete
6. **Verify artifacts** - Check all research files exist on disk
7. **Shut down sub-agents** - Send shutdown requests via re-dispatch the affected sub-agent with the needed guidance
8. **Read results** - Review each research file before writing shared.md

## Variable Reference

| Variable                   | Description                   | Example                                                                                                                              |
| -------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `{{FEATURE_NAME}}`         | Feature directory name        | `user-authentication`                                                                                                                |
| `{{RESEARCH_<LENS>_FILE}}` | Absolute research output path | Local: `docs/plans/user-authentication/research-<lens>.md`; linear: `.ycc/artifacts/user-authentication/research/research-<lens>.md` |
