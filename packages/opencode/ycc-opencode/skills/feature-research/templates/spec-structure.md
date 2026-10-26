# Feature Spec Template

This template defines the structure for `feature-spec.md` - the consolidated research document that serves as input for plan-workflow.

Resolve research links for the active store: in linear mode use `./research/research-<lens>.md`; in local mode (default) use `./research-<lens>.md`.

---

## Complete Example Format

```markdown
# Feature Spec: [Feature Name]

## Executive Summary

[3-5 sentence, information-dense summary covering:]

- What the feature does (functionality)
- Why it matters (business value)
- How it will be implemented (technical approach)
- Key integration points
- Primary risks or challenges

## External Dependencies

### APIs and Services

#### [Primary API Name]

- **Documentation**: [URL]
- **Authentication**: [Method - OAuth2, API Key, etc.]
- **Key Endpoints**:
  - `GET /endpoint`: [Purpose]
  - `POST /endpoint`: [Purpose]
- **Rate Limits**: [Requests per time period]
- **Pricing**: [Free tier limits, paid requirements]

#### [Secondary API if applicable]

[Same structure]

### Libraries and SDKs

| Library | Version   | Purpose      | Installation      |
| ------- | --------- | ------------ | ----------------- |
| [name]  | [version] | [why needed] | `install command` |

### External Documentation

- [Doc Name]([URL]): [What it covers]

## Business Requirements

### User Stories

**Primary User: [Role]**

- As a [role], I want to [action] so that [benefit]
- As a [role], I want to [action] so that [benefit]

**Secondary User: [Role]** (if applicable)

- As a [role], I want to [action] so that [benefit]

### Business Rules

1. **[Rule Name]**: [Specific rule description]
   - Validation: [How to enforce]
   - Exception: [When it doesn't apply]

2. **[Another Rule]**: [Description]

### Edge Cases

| Scenario   | Expected Behavior | Notes                |
| ---------- | ----------------- | -------------------- |
| [Scenario] | [Behavior]        | [Additional context] |

### Success Criteria

- [ ] [Measurable criterion 1]
- [ ] [Measurable criterion 2]
- [ ] [Measurable criterion 3]

## Technical Specifications

### Architecture Overview
```

[ASCII diagram showing component relationships]

[Component A] ──▶ [Component B] ──▶ [External Service]
│ │
▼ ▼
[Database] [Cache/Queue]

````

### Data Models

#### [Entity/Table Name]

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| id | UUID | PK | Primary identifier |
| [field] | [type] | [constraints] | [description] |

**Indexes:**
- `idx_[name]` on ([columns]): [Purpose]

**Relationships:**
- [Relationship description]

#### [Another Entity if needed]
[Same structure]

### API Design

#### `[METHOD] /api/[path]`

**Purpose**: [What this endpoint does]
**Authentication**: [Required/Optional, method]

**Request:**

```json
{
  "field": "type - description"
}
```

**Response (200):**

```json
{
  "field": "type - description"
}
```

**Errors:**

| Status | Condition   | Response       |
| ------ | ----------- | -------------- |
| 400    | [Condition] | [Error format] |
| 401    | [Condition] | [Error format] |
| 404    | [Condition] | [Error format] |

### System Integration

#### Files to Create

- `/path/to/new/file.ext`: [Purpose and responsibilities]

#### Files to Modify

- `/path/to/existing.ext`: [What changes are needed]

#### Configuration

- [Config key]: [Value and purpose]

## UX Considerations

### User Workflows

#### Primary Workflow: [Name]

1. **[Step Name]**
   - User: [Action]
   - System: [Response/Feedback]

2. **[Step Name]**
   - User: [Action]
   - System: [Response/Feedback]

3. **Success State**
   - [Final outcome and feedback]

#### Error Recovery Workflow

1. **Error Occurs**: [Condition]
2. **User Sees**: [Error message/UI]
3. **Recovery**: [User action to resolve]

### UI Patterns

| Component   | Pattern        | Notes                  |
| ----------- | -------------- | ---------------------- |
| [Component] | [Pattern name] | [Implementation notes] |

### Accessibility Requirements

- [WCAG requirement]: [Implementation approach]
- [WCAG requirement]: [Implementation approach]

### Performance UX

- **Loading States**: [Pattern to use]
- **Optimistic Updates**: [Where applicable]
- **Error Feedback**: [Timing and format]

## Recommendations

### Implementation Approach

**Recommended Strategy**: [Description of overall approach]

**Phasing:**

1. **Phase 1 - Foundation**: [Scope]
2. **Phase 2 - Core Features**: [Scope]
3. **Phase 3 - Polish**: [Scope]

### Technology Decisions

| Decision        | Recommendation | Rationale |
| --------------- | -------------- | --------- |
| [Decision area] | [Choice]       | [Why]     |

### Quick Wins

- [Quick win 1]: [Low effort, immediate value]
- [Quick win 2]: [Low effort, immediate value]

### Future Enhancements

- [Enhancement]: [Value and when to consider]

## Risk Assessment

### Technical Risks

| Risk               | Likelihood   | Impact       | Mitigation |
| ------------------ | ------------ | ------------ | ---------- |
| [Risk description] | High/Med/Low | High/Med/Low | [Strategy] |

### Integration Challenges

- [Challenge]: [Mitigation approach]

### Security Considerations

#### Critical — Hard Stops

| Finding | Risk | Required Mitigation |
|---------|------|---------------------|
| [Finding or "None identified"] | [Impact] | [Required action] |

#### Warnings — Must Address

| Finding | Risk | Mitigation | Alternatives |
|---------|------|-----------|--------------|
| [Finding or "None identified"] | [Impact] | [Recommended fix] | [Other options] |

#### Advisories — Best Practices

- [Advisory]: [Recommendation] (deferral justification: [when OK to skip])

## Task Breakdown Preview

### Phase 1: [Name]

**Focus**: [What this phase accomplishes]
**Tasks**:

- [High-level task 1]
- [High-level task 2]
  **Parallelization**: [What can run concurrently]

### Phase 2: [Name]

**Focus**: [What this phase accomplishes]
**Dependencies**: [What must complete first]
**Tasks**:

- [High-level task 1]
- [High-level task 2]

### Phase 3: [Name]

**Focus**: [What this phase accomplishes]
**Tasks**:

- [High-level task 1]
- [High-level task 2]

## Decisions Needed

Before proceeding to implementation planning, clarify:

1. **[Decision Area]**
   - Options: [A, B, C]
   - Impact: [How choice affects implementation]
   - Recommendation: [Suggested choice and why]

2. **[Another Decision]**
   - Options: [A, B]
   - Impact: [How choice affects implementation]

## Research References

For detailed findings, see:

- [research-external.md](./research-external.md): External API details
- [research-business.md](./research-business.md): Business logic analysis
- [research-technical.md](./research-technical.md): Technical specifications
- [research-ux.md](./research-ux.md): UX research
- [research-security.md](./research-security.md): Security analysis (severity-leveled findings)
- [research-practices.md](./research-practices.md): Engineering practices (modularity, reuse, KISS)
- [research-recommendations.md](./research-recommendations.md): Full recommendations

In linear mode use the nested research path for every reference, for example:
- [research-ux.md](./research/research-ux.md): UX research

````

---

## Section Guidelines

### Executive Summary

The summary should answer in 3-5 sentences:

- What does this feature do?
- Why is it valuable?
- How will it be built (high-level)?
- What are the key challenges?

**Good Example:**

```markdown
## Executive Summary

This feature integrates Plex media library filtering and playlist management into the application. Users can query their Plex server using native filters (rating, genre, year) to find media, then copy selected items to a destination folder while maintaining metadata. The implementation uses the Plex API v2 with X-Plex-Token authentication, requiring a new PlexService component and database tables for tracking sync state. Primary challenges include handling large libraries efficiently and managing the async nature of Plex library scans.
```

**Bad Example:**

```markdown
## Executive Summary

This feature adds Plex integration. It will help users manage their media.
```

### External Dependencies

List external services with enough detail for implementation:

- Documentation URLs (must be real, working links)
- Authentication specifics
- Key endpoints with purposes
- Constraints that affect design

### Business Requirements

Focus on user value and business rules:

- User stories should follow the "As a... I want... so that..." format
- Business rules should be specific and testable
- Edge cases should have clear expected behaviors
- Success criteria should be measurable

### Technical Specifications

Provide implementation-ready details:

- Data models with actual column definitions
- API contracts with request/response examples
- Architecture diagrams showing component relationships
- File paths for new and modified code

### UX Considerations

Document user-facing behavior:

- Step-by-step workflows
- Error messages and recovery paths
- Loading states and feedback patterns
- Accessibility requirements

### Recommendations

Synthesize research into actionable guidance:

- Clear implementation recommendation
- Justified technology choices
- Risk mitigation strategies
- Future enhancement opportunities

### Task Breakdown Preview

Provide high-level structure for plan-workflow:

- Logical phases
- Task groupings
- Dependency relationships
- Parallelization opportunities

---

## Quality Checklist

Before finalizing feature-spec.md, verify:

### Content Quality

- [ ] Executive summary is information-dense (3-5 sentences)
- [ ] All external API URLs are valid and current
- [ ] Business rules are specific and testable
- [ ] Data models include actual field definitions
- [ ] API designs include request/response examples
- [ ] UX workflows cover happy path and errors
- [ ] Recommendations are actionable

### Structure Quality

- [ ] All required sections present
- [ ] Consistent formatting throughout
- [ ] Tables properly formatted
- [ ] Code blocks have language tags
- [ ] Links to research files are correct

### Completeness

- [ ] No placeholder text remains
- [ ] Open questions are documented
- [ ] Decisions needed are clearly stated
- [ ] Task preview aligns with scope

---

## Integration with plan-workflow

The feature-spec.md is read by plan-workflow (or can be used with shared-context) to:

1. **Inform shared.md creation** - Relevant files, patterns, tables
2. **Guide task breakdown** - Business rules become acceptance criteria
3. **Provide technical context** - Data models and APIs inform implementation
4. **Enable parallel planning** - Task preview suggests phase structure

Ensure feature-spec.md is comprehensive enough that planning can proceed without additional research rounds.
