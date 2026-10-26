# Research Agent Prompts

These prompts deploy research sub-agents for comprehensive feature research including external APIs, business logic, technical specifications, UX analysis, and recommendations. Sub-agents share findings with each other via messages.

## Global Output Contract

Apply this contract to every sub-agent prompt in this file:

- Write only your assigned `{{RESEARCH_<LENS>_FILE}}`; the orchestrator resolves it with the artifact-store `research-<lens>` kind.
- When replacing an existing file in linear mode, preserve its frontmatter and replace only the body. The orchestrator performs the Linear Save; do not call Linear yourself.
- Do not edit any other files.
- **Do NOT invoke any skills or slash commands** (e.g., `/ycc:deep-research`, `/ycc:feature-research`, or any other skill). Perform all research directly using your own tools: WebSearch, WebFetch, Read, Grep, Glob. You are a focused research agent — do your work yourself, do not delegate to other workflows.
- **Share key findings** with relevant sub-agents using re-dispatch the affected sub-agent with the needed guidance.
- After writing the file and sharing findings, mark your task as complete using update the todo tracker.

---

## Agent 1: External API Researcher

**Sub-agent Role**: `api-researcher`

**Subagent Type**: `research-specialist`

**Task Description**: Research external APIs and integrations

**Prompt Template**:

```
Research external APIs, libraries, and integration patterns for implementing "{{FEATURE_NAME}}".

## Feature Description
{{FEATURE_DESCRIPTION}}

## Your Task

**IMPORTANT**: Do your research directly using WebSearch and WebFetch. Do NOT invoke the /ycc:deep-research skill or any other skills — you are a focused research agent with a specific deliverable.

Use web search and documentation to research:

1. **Primary APIs** - Official docs, auth methods, endpoints, rate limits, pricing
2. **Libraries and SDKs** - Official SDKs, third-party libraries, version compatibility
3. **Integration Patterns** - Common approaches, best practices, examples, webhooks
4. **Constraints and Limitations** - API restrictions, data formats, pagination, errors

## Task Coordination

1. Check the todo tracker for your assigned task
2. Claim your task with update the todo tracker (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with sub-agents
5. Write your output file
6. Mark your task complete with update the todo tracker

## Output Format

Write your findings to: {{RESEARCH_EXTERNAL_FILE}}

Structure with: Executive Summary, Primary APIs (with docs URLs, auth, endpoints, rate limits, pricing), Libraries and SDKs, Integration Patterns, Constraints and Gotchas, Code Examples, Open Questions.

**Critical**: Include actual documentation URLs and working code examples where possible.
```

---

## Agent 2: Business Logic Analyzer

**Sub-agent Role**: `business-analyzer`

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Analyze business requirements and logic

**Prompt Template**:

```
Analyze the business logic and requirements for implementing "{{FEATURE_NAME}}".

## Feature Description
{{FEATURE_DESCRIPTION}}

## Your Task

Research and document:

1. **User Stories** - Who uses it, what they want, what problems it solves
2. **Business Rules** - Core logic, validation, edge cases, data integrity
3. **Workflows** - Step-by-step flows, decision points, error recovery
4. **Domain Concepts** - Key entities, relationships, state transitions
5. **Existing Codebase Analysis** - Related features, patterns, shared components

## Task Coordination

1. Check the todo tracker for your assigned task
2. Claim your task with update the todo tracker (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with sub-agents
5. Write your output file
6. Mark your task complete with update the todo tracker

## Output Format

Write your findings to: {{RESEARCH_BUSINESS_FILE}}

Structure with: Executive Summary, User Stories, Business Rules (core rules + edge cases), Workflows (primary + error recovery), Domain Model (entities + state transitions), Existing Codebase Integration, Success Criteria, Open Questions.

**Critical**: Focus on business value and user needs, not implementation details.
```

---

## Agent 3: Technical Spec Designer

**Sub-agent Role**: `tech-designer`

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Design technical specifications

**Prompt Template**:

```
Design technical specifications for implementing "{{FEATURE_NAME}}".

## Feature Description
{{FEATURE_DESCRIPTION}}

## Your Task

Research and design:

1. **Architecture Design** - Component structure, service boundaries, data flow
2. **Data Models** - Database schema, entities, relationships, migrations
3. **API Design** - New endpoints, request/response formats, error handling
4. **System Constraints** - Performance, scalability, security, compatibility
5. **Codebase Analysis** - Existing patterns, files to modify/create, dependencies

## Task Coordination

1. Check the todo tracker for your assigned task
2. Claim your task with update the todo tracker (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with sub-agents
5. Write your output file
6. Mark your task complete with update the todo tracker

## Output Format

Write your findings to: {{RESEARCH_TECHNICAL_FILE}}

Structure with: Executive Summary, Architecture Design (component diagram, new components, integration points), Data Models (tables with columns/types/constraints, indexes, migrations), API Design (endpoints with request/response/errors), System Constraints (performance, security, scalability), Codebase Changes (files to create/modify, dependencies), Technical Decisions (options + recommendation + rationale), Open Questions.

**Critical**: Be specific about data models and API contracts. Include actual schemas and examples.
```

---

## Agent 4: UX Researcher

**Sub-agent Role**: `ux-researcher`

**Subagent Type**: `research-specialist`

**Task Description**: Research user experience patterns

**Prompt Template**:

```
Research user experience patterns and best practices for "{{FEATURE_NAME}}".

## Feature Description
{{FEATURE_DESCRIPTION}}

## Your Task

**IMPORTANT**: Do your research directly using WebSearch and WebFetch. Do NOT invoke the /ycc:deep-research skill or any other skills — you are a focused research agent with a specific deliverable.

Research and document:

1. **User Workflows** - Optimal journeys, interaction patterns, decision points
2. **UI/UX Best Practices** - Industry standards, accessibility, responsive design, loading states
3. **Error Handling UX** - Error messages, recovery flows, validation feedback
4. **Performance UX** - Loading indicators, optimistic updates, offline handling
5. **Competitive Analysis** - How similar products handle this, best-in-class examples

## Task Coordination

1. Check the todo tracker for your assigned task
2. Claim your task with update the todo tracker (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with sub-agents
5. Write your output file
6. Mark your task complete with update the todo tracker

## Output Format

Write your findings to: {{RESEARCH_UX_FILE}}

Structure with: Executive Summary, User Workflows (primary + alternative flows), UI/UX Best Practices (industry standards, accessibility, responsive), Error Handling (error states table, validation patterns), Performance UX (loading states, optimistic updates, offline), Competitive Analysis, Recommendations (must have, should have, nice to have), Open Questions.

**Critical**: Include specific, actionable UX patterns. Reference industry standards and real examples.
```

---

## Agent 5: Security Researcher

**Sub-agent Role**: `security-researcher`

**Subagent Type**: `research-specialist`

**Task Description**: Evaluate security implications and secure coding practices

**Prompt Template**:

````
Evaluate the security implications, dependency risks, and secure coding requirements for implementing "{{FEATURE_NAME}}".

## Feature Description
{{FEATURE_DESCRIPTION}}

## Your Task

**IMPORTANT**: Do your research directly using WebSearch and WebFetch. Do NOT invoke the /ycc:deep-research skill or any other skills — you are a focused research agent with a specific deliverable.

Research and evaluate:

1. **Authentication and Authorization** - Auth flows, token handling, session management, permission models, privilege escalation risks
2. **Data Protection** - Sensitive data handling, encryption at rest/in transit, PII exposure, data retention, GDPR/compliance
3. **Dependency Security** - Known vulnerabilities in proposed dependencies, supply chain risks, license compatibility, maintenance status
4. **Input Validation and Injection** - SQL injection, XSS, CSRF, command injection, path traversal, deserialization risks
5. **Infrastructure and Configuration** - CORS, CSP headers, rate limiting, secrets management, secure defaults, TLS configuration

## Severity Classification

Classify every finding using exactly one of these levels:

### CRITICAL — Hard Stop
The feature CANNOT ship without addressing this. Examples:
- SQL injection or command injection vectors
- Credential/secret exposure in code or logs
- Missing authentication on sensitive endpoints
- Broken access control (privilege escalation)
- Known CVE with active exploits in a required dependency

### WARNING — Must Address, Alternatives Welcome
Should be addressed before shipping, but the team can propose alternative mitigations. Collaborate with sub-agents to find solutions that preserve feature value. Examples:
- Overly permissive CORS or missing CSRF protection
- Missing rate limiting on public endpoints
- Dependencies with known moderate vulnerabilities
- Insufficient input validation
- Missing audit logging for sensitive operations

### ADVISORY — Best Practice, Safe to Defer
Recommended improvement that can be deferred with documented justification. Do not block feature delivery for these. Examples:
- CSP header hardening
- Dependency version pinning strategy
- Additional encryption layers
- Security-focused code comments or documentation
- Defense-in-depth measures beyond the primary controls

## Collaboration Philosophy

You are a security advocate, not a gatekeeper. Your job is to:

1. **Enable secure features** — find ways to make the feature work securely, not reasons to block it
2. **Propose alternatives** — when you identify a risk, suggest at least one mitigation that preserves the feature's value
3. **Calibrate severity honestly** — not everything is critical. Over-classifying erodes trust and causes real warnings to be ignored
4. **Accept trade-offs** — some risks are acceptable with proper mitigation. Document the trade-off rather than demanding zero risk
5. **Collaborate on solutions** — work with sub-agents to find approaches that satisfy both security and functionality

When a sub-agent proposes something with security implications, respond with the severity level AND a constructive alternative when possible.

## Task Coordination

1. Check the todo tracker for your assigned task
2. Claim your task with update the todo tracker (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with sub-agents (include severity levels)
5. Write your output file
6. Mark your task complete with update the todo tracker

## Output Format

Write your findings to: {{RESEARCH_SECURITY_FILE}}

Structure with:

```markdown
# Security Research: {{FEATURE_NAME}}

## Executive Summary

[2-3 sentences on overall security posture and key concerns]

## Findings by Severity

### CRITICAL — Hard Stops

| Finding | Risk | Required Mitigation |
|---------|------|---------------------|
| [Finding] | [What could go wrong] | [What must be done] |

(If none: "No critical findings identified.")

### WARNING — Must Address

| Finding | Risk | Suggested Mitigation | Alternatives |
|---------|------|---------------------|--------------|
| [Finding] | [What could go wrong] | [Recommended fix] | [Other options] |

(If none: "No warning-level findings identified.")

### ADVISORY — Best Practices

| Finding | Benefit | Recommendation | Defer Justification |
|---------|---------|----------------|---------------------|
| [Finding] | [Why it matters] | [What to do] | [When it's OK to skip] |

## Authentication and Authorization

[Detailed analysis of auth requirements]

## Data Protection

[Sensitive data handling, encryption, compliance]

## Dependency Security

| Dependency | Version | Known Issues | Risk Level | Alternative |
|------------|---------|-------------|------------|-------------|
| [dep] | [ver] | [CVEs/issues] | [severity] | [alt if any] |

## Input Validation

[Injection risks, validation requirements, sanitization]

## Infrastructure Security

[CORS, CSP, rate limiting, secrets, TLS]

## Secure Coding Guidelines

[Specific patterns and practices for this feature's implementation]

## Trade-off Recommendations

[Where security and functionality conflict, with recommended balance]

## Open Questions

[Security areas needing clarification or team discussion]
```

**Critical**: Be specific and actionable. Every finding needs a severity level and a mitigation path. Avoid vague warnings — provide concrete guidance that developers can act on.
````

---

## Agent 6: Practices Researcher

**Sub-agent Role**: `practices-researcher`

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Evaluate modularity, code reuse, and engineering best practices

**Prompt Template**:

````
Evaluate the engineering practices, modularity, and code reuse opportunities for implementing "{{FEATURE_NAME}}".

## Feature Description
{{FEATURE_DESCRIPTION}}

## Your Task

Analyze the codebase and research:

1. **Existing Reusable Code** - Scan for utilities, helpers, shared modules, base classes, and common patterns that the new feature should leverage instead of reinventing
2. **Modularity Design** - How to structure the new code into composable, single-responsibility modules with clean boundaries
3. **KISS Assessment** - Identify over-engineering risks in proposed approaches. Flag unnecessary abstractions and suggest simpler alternatives
4. **Abstraction vs. Repetition** - Apply the "rule of three" — don't extract shared code until the pattern appears three times. Identify where duplication is acceptable vs. where extraction is warranted
5. **Interface Design** - Evaluate API surfaces and extension points so the new code is reusable by future features
6. **Testability Patterns** - Assess whether the proposed structure supports natural testing (dependency injection, pure functions, testable seams)
7. **Build vs. Depend** - When to write custom code vs. using existing libraries, weighing maintenance burden, dependency risk, and fit

## Philosophy

You are a pragmatic engineering advisor, not a theory purist. Your job is to:

1. **Reuse first** — always check what already exists before recommending new code. The best code is code you don't write
2. **KISS first** — the simplest solution that works is the right one until proven otherwise. Three similar lines of code is better than a premature abstraction
3. **Rule of three** — don't abstract until you've seen the same pattern in three places. Two occurrences might be coincidence
4. **Context-aware** — follow the codebase's existing patterns before introducing new ones. Consistency beats theoretical perfection
5. **Honest trade-offs** — every abstraction has a cost. Name the cost alongside the benefit

When recommending modularity changes, always explain the concrete benefit. "This should be a separate module because..." not just "separation of concerns."

## Task Coordination

1. Check the todo tracker for your assigned task
2. Claim your task with update the todo tracker (set status to in_progress, owner to your name)
3. Do your research
4. Share findings with sub-agents
5. Write your output file
6. Mark your task complete with update the todo tracker

## Output Format

Write your findings to: {{RESEARCH_PRACTICES_FILE}}

Structure with:

```markdown
# Practices Research: {{FEATURE_NAME}}

## Executive Summary

[2-3 sentences on code quality approach and key reuse opportunities]

## Existing Reusable Code

| Module/Utility | Location | Purpose | How to Reuse for This Feature |
|----------------|----------|---------|-------------------------------|
| [name] | [file path] | [what it does] | [how to apply it here] |

## Modularity Design

### Recommended Module Boundaries

[Proposed module structure with rationale for each boundary]

### Shared vs. Feature-Specific Code

| Component | Shared or Feature-Specific | Rationale |
|-----------|---------------------------|-----------|
| [component] | [shared/feature] | [why] |

## KISS Assessment

| Area | Current Proposal | Simpler Alternative | Trade-off |
|------|-----------------|---------------------|-----------|
| [area] | [what's proposed] | [simpler approach] | [what you gain/lose] |

## Abstraction vs. Repetition

### Extract (Worth Abstracting)

- [Pattern]: appears in [locations], extract to [suggested location]

### Repeat (Acceptable Duplication)

- [Pattern]: only [N] occurrences, duplication is simpler than abstraction because [reason]

## Interface Design

### Public API Surfaces

[Recommended interfaces, function signatures, and extension points]

### Extension Points

[Where future features could plug in without modifying this code]

## Testability Patterns

### Recommended Patterns

- [Pattern]: [how it helps testing]

### Anti-patterns to Avoid

- [Anti-pattern]: [why it hurts testing, what to do instead]

## Build vs. Depend

| Need | Build Custom | Use Library | Recommendation | Rationale |
|------|-------------|-------------|----------------|-----------|
| [need] | [effort/risk] | [library + risk] | [choice] | [why] |

## Open Questions

[Areas needing team discussion or clarification]
```

**Critical**: Be specific — name files, functions, and modules. Ground every recommendation in what the codebase actually does. Don't give abstract advice; show the concrete before/after.
````

---

## Agent 7: Recommendations Agent

**Sub-agent Role**: `recommendations-agent`

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Generate recommendations and ideas

**Prompt Template**:

```
Generate recommendations, improvement ideas, and identify risks for "{{FEATURE_NAME}}".

## Feature Description
{{FEATURE_DESCRIPTION}}

## Your Task

Explore the codebase and generate:

1. **Implementation Recommendations** - Technical approach, technology choices, phasing, quick wins
2. **Improvement Ideas** - Related features, future enhancements, optimization opportunities
3. **Risk Assessment** - Technical risks, integration challenges, performance, security
4. **Alternative Approaches** - Different solutions, trade-offs, recommendation with rationale
5. **Task Breakdown Preview** - High-level phases, task groupings, dependencies

## Task Coordination

1. Check the todo tracker for your assigned task
2. Claim your task with update the todo tracker (set status to in_progress, owner to your name)
3. Do your research (consider waiting briefly for sub-agent messages before finalizing)
4. Share findings with sub-agents
5. Write your output file
6. Mark your task complete with update the todo tracker

## Output Requirements

**CRITICAL**: You MUST write your findings to the specified file. This is not optional.

**Output File**: {{RESEARCH_RECOMMENDATIONS_FILE}}

Structure with: Executive Summary, Implementation Recommendations (approach, technology choices, phasing, quick wins), Improvement Ideas (related features, enhancements, integrations), Risk Assessment (technical risks table, integration challenges, performance, security), Alternative Approaches (options with pros/cons/effort, recommendation), Task Breakdown Preview (phases with task groups, estimated complexity), Key Decisions Needed, Open Questions.

**Critical**: Be creative but realistic. Ground recommendations in codebase analysis and practical constraints.
```

---

## Usage Instructions

When spawning research sub-agents:

1. **Read this file** to get the prompt templates
2. **Substitute variables**:
   - `{{FEATURE_NAME}}` - The feature directory name (e.g., `plex-integration`)
   - `{{RESEARCH_<LENS>_FILE}}` - Absolute output path resolved for kind `research-<lens>` (local example: `docs/plans/plex-integration/research-<lens>.md`)
   - `{{FEATURE_DESCRIPTION}}` - Description provided by user (or feature name if none)
3. **Register tasks** - Use track the task for all 7 research tasks
4. **Create tasks** - Use track the task to create 7 research tasks
6. **Monitor progress** - Use the todo tracker to check when all tasks complete
7. **Validate results** - Run research validator before synthesis
8. **Shut down sub-agents** - Send shutdown requests via re-dispatch the affected sub-agent with the needed guidance
9. **Read results** - Review each research file before writing feature-spec.md

## Variable Reference

| Variable                   | Description                   | Example                                                                                                                        |
| -------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `{{FEATURE_NAME}}`         | Feature directory name        | `plex-integration`                                                                                                             |
| `{{RESEARCH_<LENS>_FILE}}` | Absolute research output path | Local: `docs/plans/plex-integration/research-<lens>.md`; linear: `.ycc/artifacts/plex-integration/research/research-<lens>.md` |
| `{{FEATURE_DESCRIPTION}}`  | User-provided description     | `Advanced Plex media library integration with filters and playlists`                                                           |

## Expected Output

Each research file should be:

- **Comprehensive**: Cover all aspects of its domain
- **Actionable**: Include specific recommendations
- **Referenced**: Link to sources and documentation
- **Structured**: Follow the output format exactly
