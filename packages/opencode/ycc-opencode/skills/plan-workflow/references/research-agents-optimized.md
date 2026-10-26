# Optimized Research Agent Prompts (Unified Agents)

## Contents

- Agent 1: Architecture Analyst (Unified)
- Agent 2: Pattern Analyst (Unified)
- Agent 3: Integration Analyst
- Agent 4: Documentation Analyst
- Agent 5: Task Planner (Unified)
- Optimized Mode Sub-agent Configuration

Each `{{ANALYSIS_<NAME>_FILE}}` placeholder is the absolute path resolved by the orchestrator for the `analysis-<name>` kind. These artifacts remain local-only in linear mode.


### Agent 1: Architecture Analyst (Unified)

**Sub-agent Role**: `arch-analyst`

**Subagent Type**: `codebase-research-analyst`

**Prompt Template**:

```markdown
## PRIMARY DELIVERABLE

**Output File**: {{ANALYSIS_ARCHITECTURE_FILE}}

You MUST write this file using the Write tool. This is your #1 job. Everything else is secondary. Do NOT return your findings in summary text without writing the file — the orchestrator will fail the pre-generation gate and re-dispatch you.

---

Analyze the codebase architecture for implementing "{{FEATURE_NAME}}" and synthesize actionable context in a single pass.

## Combined Task

Perform both architecture research AND context synthesis:

1. **Architecture Research** — System structure, data flow, component relationships, integration points
2. **Context Synthesis** — Condense findings into actionable insights, critical files, cross-cutting concerns

## Output Format

Structure your report as:

\`\`\`markdown

# Architecture Analysis: {{FEATURE_NAME}}

## Executive Summary

[2-3 sentences on the overall architecture and what it means for this feature]

## Architecture Context

- **System Structure**: [How the relevant components are organized]
- **Data Flow**: [Key data flow patterns relevant to this feature]
- **Integration Points**: [Where new code plugs in]

## Critical Files Reference

- /path/to/file: [Why critical — 1 sentence]

## Cross-Cutting Concerns

- [Security, performance, testing, or other concerns affecting multiple tasks]

## Parallelization Opportunities

- [Areas where work can be done independently]

## Implementation Constraints

- [Technical and business constraints]
  \`\`\`

Be concise. Each bullet should be information-dense.

## Completion Checklist

1. **Write file**: Use the Write tool to create {{ANALYSIS_ARCHITECTURE_FILE}}
2. **Verify file**: Use the Read tool to confirm the file exists and has the expected structure
3. **(Path B only)** Share findings via re-dispatch the affected sub-agent with the needed guidance, then mark your task complete via update the todo tracker
```

### Agent 2: Pattern Analyst (Unified)

**Sub-agent Role**: `pattern-analyst`

**Subagent Type**: `codebase-research-analyst`

**Prompt Template**:

```markdown
## PRIMARY DELIVERABLE

**Output File**: {{ANALYSIS_PATTERNS_FILE}}

You MUST write this file using the Write tool. This is your #1 job. Everything else is secondary. Do NOT return your findings in summary text without writing the file — the orchestrator will fail the pre-generation gate and re-dispatch you.

---

Analyze coding patterns for implementing "{{FEATURE_NAME}}" and extract implementation guidance in a single pass.

## Combined Task

Perform both pattern research AND code analysis:

1. **Pattern Research** — Architectural patterns, code conventions, error handling, testing
2. **Code Analysis** — Implementation patterns from relevant files, file organization, integration points

## Output Format

Structure your report as:

\`\`\`markdown

# Pattern & Code Analysis: {{FEATURE_NAME}}

## Executive Summary

[2-3 sentences on dominant patterns and conventions relevant to this feature]

## Implementation Patterns

- **Pattern Name**: [Description] — example: /path/to/file

## Existing Code Structure

[File organization, module boundaries, imports, config]

## Code Conventions

[Naming, style, error handling, testing approach]

## Integration Points

- /path/to/file: [Files to create vs. modify]

## Gotchas and Warnings

- [Things that look like patterns but aren't, deprecated paths, etc.]
  \`\`\`

Extract actual code patterns with file paths, not just file listings.

## Completion Checklist

1. **Write file**: Use the Write tool to create {{ANALYSIS_PATTERNS_FILE}}
2. **Verify file**: Use the Read tool to confirm the file exists and has the expected structure
3. **(Path B only)** Share findings via re-dispatch the affected sub-agent with the needed guidance, then mark your task complete via update the todo tracker
```

### Agent 3: Integration Analyst

**Sub-agent Role**: `integration-analyst`

**Subagent Type**: `codebase-research-analyst`

**Prompt Template**:

```markdown
## PRIMARY DELIVERABLE

**Output File**: {{ANALYSIS_INTEGRATION_FILE}}

You MUST write this file using the Write tool. This is your #1 job. Everything else is secondary. Do NOT return your findings in summary text without writing the file — the orchestrator will fail the pre-generation gate and re-dispatch you.

---

Analyze APIs, databases, and integrations relevant to implementing "{{FEATURE_NAME}}".

## Your Task

Investigate:

1. **API Endpoints** — Existing related endpoints, route organization, middleware
2. **Database Schema** — Relevant tables, relationships, migrations
3. **External Services** — Third-party integrations, credentials, config
4. **Internal Services** — Internal service communication patterns

## Output Format

Structure your report as:

\`\`\`markdown

# Integration Analysis: {{FEATURE_NAME}}

## Executive Summary

[2-3 sentences summarizing the integration surface for this feature]

## API Endpoints

- METHOD /path: [Purpose] — handler at /path/to/file

## Database

[Tables, relationships, migrations relevant to this feature]

## External Services

[Third-party APIs, credentials, configuration]

## Integration Points

[Where this feature plugs into existing integration code]
\`\`\`

Be specific with route paths, table names, and file references.

## Completion Checklist

1. **Write file**: Use the Write tool to create {{ANALYSIS_INTEGRATION_FILE}}
2. **Verify file**: Use the Read tool to confirm the file exists and has the expected structure
3. **(Path B only)** Share findings via re-dispatch the affected sub-agent with the needed guidance, then mark your task complete via update the todo tracker
```

### Agent 4: Documentation Analyst

**Sub-agent Role**: `docs-analyst`

**Subagent Type**: `codebase-research-analyst`

**Prompt Template**:

```markdown
## PRIMARY DELIVERABLE

**Output File**: {{ANALYSIS_DOCS_FILE}}

You MUST write this file using the Write tool. This is your #1 job. Everything else is secondary. Do NOT return your findings in summary text without writing the file — the orchestrator will fail the pre-generation gate and re-dispatch you.

---

Find and analyze documentation relevant to implementing "{{FEATURE_NAME}}".

## Your Task

Search for documentation in:

1. **docs/ directory** — Architecture, API, feature, development guides
2. **README files** — Root, directory-level, module READMEs
3. **Code comments** — Well-documented modules, API docs in code
4. **External references** — Links to external docs, specs, library docs

## Output Format

Structure your report as:

\`\`\`markdown

# Documentation Analysis: {{FEATURE_NAME}}

## Executive Summary

[2-3 sentences on the documentation surface for this feature]

## Must-Read Documents

- /path/to/doc: [Why required — 1 sentence]

## Architecture Docs

- /path/to/doc: [What it covers]

## Reading List

[Prioritized list for implementers — required vs. nice-to-have]

## Documentation Gaps

[Areas where documentation is missing or stale and should be written]
\`\`\`

Identify which documents are REQUIRED reading vs nice-to-have.

## Completion Checklist

1. **Write file**: Use the Write tool to create {{ANALYSIS_DOCS_FILE}}
2. **Verify file**: Use the Read tool to confirm the file exists and has the expected structure
3. **(Path B only)** Share findings via re-dispatch the affected sub-agent with the needed guidance, then mark your task complete via update the todo tracker
```

### Agent 5: Task Planner (Unified)

**Sub-agent Role**: `task-planner`

**Subagent Type**: `codebase-research-analyst`

**Prompt Template**:

```markdown
## PRIMARY DELIVERABLE

**Output File**: {{ANALYSIS_TASKS_FILE}}

You MUST write this file using the Write tool. This is your #1 job. Everything else is secondary. Do NOT return your findings in summary text without writing the file — the orchestrator will fail the pre-generation gate and re-dispatch you.

---

Analyze the codebase structure for "{{FEATURE_NAME}}" and suggest an optimal task breakdown and phase organization.

## Your Task

1. **Understand feature scope** — Read shared context and prior research files
2. **Analyze codebase structure** — Module boundaries, file groupings
3. **Suggest task organization** — Phases, task boundaries (1-3 files per task), parallelism, dependencies
4. **Consider implementation order** — Foundation → core logic → integration → docs

## Output Format

Structure your report as:

\`\`\`markdown

# Task Structure Analysis: {{FEATURE_NAME}}

## Executive Summary

[2-3 sentences on the recommended task shape for this feature]

## Recommended Phase Structure

- **Phase 1: [name]** — [purpose, dependencies]
- **Phase 2: [name]** — [purpose, dependencies]

## Task Granularity

[Recommendation on task size, files per task, what to bundle vs. split]

## Dependency Analysis

[Which tasks block which; circular-dependency check]

## File-to-Task Mapping

- /path/to/file: [Which task owns it]
  \`\`\`

Focus on actionable structure. The goal is to help organize the parallel plan, not to write the plan itself.

## Completion Checklist

1. **Write file**: Use the Write tool to create {{ANALYSIS_TASKS_FILE}}
2. **Verify file**: Use the Read tool to confirm the file exists and has the expected structure
3. **(Path B only)** Share findings via re-dispatch the affected sub-agent with the needed guidance, then mark your task complete via update the todo tracker
```

---
