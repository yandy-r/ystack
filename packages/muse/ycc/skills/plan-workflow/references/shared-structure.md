# Shared Context Template

## Contents

- Complete Example Format
- Section Guidelines
- Validation Checklist
- Integration with parallel-plan

This template defines the exact structure for the `shared.md` document that serves as the foundation for parallel-plan.

---

## Complete Example Format

```markdown
# [Feature Name]

[3-4 sentence, information-dense breakdown of how the architecture fits together. Explain the core components involved, their relationships, and how the new feature will integrate with existing systems. Be specific about the technical landscape.]

## Relevant Files

- /src/path/to/component.ext: Brief description of what this file does and why it's relevant
- /src/another/module.ext: How this relates to the feature being implemented
- /src/patterns/example.ext: Existing pattern to follow for similar functionality
- /lib/shared/utility.ext: Utility functions that will be used or extended

## Relevant Tables

- users: Core user data, authentication info
- user_settings: User preferences and configuration
- feature_flags: Controls feature rollout and A/B testing

## Relevant Patterns

**Repository Pattern**: Data access abstraction used throughout the codebase. See [/src/repositories/user-repository.ts](/src/repositories/user-repository.ts) for example implementation.

**Service Layer**: Business logic encapsulation. Services handle complex operations and coordinate between repositories. Example: [/src/services/auth-service.ts](/src/services/auth-service.ts).

**Event-Driven Updates**: State changes trigger events that other components subscribe to. See [/src/events/user-events.ts](/src/events/user-events.ts).

## Relevant Docs

**/docs/architecture/overview.md**: You _must_ read this when working on system-wide changes or adding new components.

**/docs/api/authentication.md**: You _must_ read this when working on auth-related features or protected endpoints.

**/docs/development/patterns.md**: Reference for coding conventions and architectural patterns used in this codebase.
```

---

## Section Guidelines

### Title & Overview

The overview should answer:

- What existing components are involved?
- How do they relate to each other?
- Where does the new feature fit in?
- What's the general technical approach?

**Good example:**

```markdown
# User Authentication

The authentication system spans three layers: API routes in /src/routes/auth/, service logic in /src/services/auth-service.ts, and data access through /src/repositories/user-repository.ts. User sessions are managed via JWT tokens stored in Redis, with refresh token rotation handled by the token-service. New authentication features should follow the existing middleware pattern in /src/middleware/auth.ts.
```

**Bad example:**

```markdown
# User Authentication

This feature is about authentication. We need to add login functionality.
```

### Relevant Files

List files that:

- Will be modified for this feature
- Contain patterns to follow
- Provide context for understanding the system
- Are dependencies of the new feature

Format: `- /path/to/file: Brief description`

Keep descriptions short but informative (< 15 words).

### Relevant Tables

List database tables that:

- Will be queried or modified
- Contain related data
- Have foreign key relationships to new data

Include brief descriptions of what data each table holds.

**Note**: Omit this section if the feature doesn't involve database operations.

### Relevant Patterns

Document architectural patterns with:

- Pattern name in bold
- One-sentence description of how it's used
- Link to example implementation

Focus on patterns directly relevant to implementation, not general best practices.

### Relevant Docs

List documentation that implementers must read:

- Architecture docs for the affected area
- API documentation for endpoints being modified
- Development guides for patterns being used

Use the format: `**path**: You _must_ read this when working on [topics].`

The "must read" phrasing helps parallel-plan identify critical context.

---

## Validation Checklist

Before finalizing shared.md, verify:

- [ ] Overview is 3-4 sentences, information-dense
- [ ] All file paths exist and are relative to project root
- [ ] File descriptions explain relevance, not just content
- [ ] Tables section included only if database is involved
- [ ] Patterns include links to example implementations
- [ ] Documentation paths are valid
- [ ] No placeholder text remains

---

## Integration with parallel-plan

The shared.md file is read by parallel-plan to:

1. Populate the "Critically Relevant Files" section
2. Inform task breakdown and dependencies
3. Identify patterns for implementation guidance
4. Reference documentation in task instructions

Ensure shared.md is comprehensive enough that parallel-plan can create accurate, actionable tasks without additional research.
