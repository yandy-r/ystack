# Plan: [Feature Name]

## Contents

- Summary
- User Story
- Problem → Solution
- Metadata
- UX Design
- Mandatory Reading
- External Documentation
- Patterns to Mirror
- Files to Change
- NOT Building
- Step-by-Step Tasks
- Testing Strategy
- Validation Commands
- Acceptance Criteria
- Completion Checklist
- Risks
- Notes

## Summary

[2-3 sentence overview]

## User Story

As a [user], I want [capability], so that [benefit].

## Problem → Solution

[Current state] → [Desired state]

## Metadata

- **Complexity**: [Small | Medium | Large | XL]
- **Source PRD**: [path or "N/A"]
- **PRD Phase**: [phase name or "N/A"]
- **Estimated Files**: [count]

---

## UX Design

### Before

[ASCII diagram or "N/A — internal change"]

### After

[ASCII diagram or "N/A — internal change"]

### Interaction Changes

| Touchpoint | Before | After | Notes |
| ---------- | ------ | ----- | ----- |

---

## Mandatory Reading

Files that MUST be read before implementing:

| Priority       | File           | Lines | Why                    |
| -------------- | -------------- | ----- | ---------------------- |
| P0 (critical)  | `path/to/file` | 1-50  | Core pattern to follow |
| P1 (important) | `path/to/file` | 10-30 | Related types          |
| P2 (reference) | `path/to/file` | all   | Similar implementation |

## External Documentation

| Topic | Source | Key Takeaway |
| ----- | ------ | ------------ |

---

## Patterns to Mirror

Code patterns discovered in the codebase. Follow these exactly.

### NAMING_CONVENTION

```
// SOURCE: [file:lines]
[actual code snippet showing the naming pattern]
```

### ERROR_HANDLING

```
// SOURCE: [file:lines]
[actual code snippet showing error handling]
```

### LOGGING_PATTERN

```
// SOURCE: [file:lines]
[actual code snippet showing logging]
```

### REPOSITORY_PATTERN

```
// SOURCE: [file:lines]
[actual code snippet showing data access]
```

### SERVICE_PATTERN

```
// SOURCE: [file:lines]
[actual code snippet showing service layer]
```

### TEST_STRUCTURE

```
// SOURCE: [file:lines]
[actual code snippet showing test setup]
```

---

## Files to Change

| File                  | Action | Justification           |
| --------------------- | ------ | ----------------------- |
| `path/to/file.ts`     | CREATE | New service for feature |
| `path/to/existing.ts` | UPDATE | Add new method          |

## NOT Building

- [Explicit item 1 that is out of scope]
- [Explicit item 2 that is out of scope]

---

## Step-by-Step Tasks

### Task 1: [Name]

- **ACTION**: [What to do]
- **IMPLEMENT**: [Specific code/logic to write]
- **MIRROR**: [Pattern from Patterns to Mirror section to follow]
- **IMPORTS**: [Required imports]
- **GOTCHA**: [Known pitfall to avoid]
- **VALIDATE**: [How to verify this task is correct]

### Task 2: [Name]

- **ACTION**: ...
- **IMPLEMENT**: ...
- **MIRROR**: ...
- **IMPORTS**: ...
- **GOTCHA**: ...
- **VALIDATE**: ...

[Continue for all tasks...]

---

## Testing Strategy

### Unit Tests

| Test | Input | Expected Output | Edge Case? |
| ---- | ----- | --------------- | ---------- |
| ...  | ...   | ...             | ...        |

### Edge Cases Checklist

- [ ] Empty input
- [ ] Maximum size input
- [ ] Invalid types
- [ ] Concurrent access
- [ ] Network failure (if applicable)
- [ ] Permission denied

---

## Validation Commands

### Static Analysis

```bash
# Run type checker
[project-specific type check command]
```

EXPECT: Zero type errors

### Unit Tests

```bash
# Run tests for affected area
[project-specific test command]
```

EXPECT: All tests pass

### Full Test Suite

```bash
# Run complete test suite
[project-specific full test command]
```

EXPECT: No regressions

### Database Validation (if applicable)

```bash
# Verify schema/migrations
[project-specific db command]
```

EXPECT: Schema up to date

### Browser Validation (if applicable)

```bash
# Start dev server and verify
[project-specific dev server command]
```

EXPECT: Feature works as designed

### Manual Validation

- [ ] [Step-by-step manual verification checklist]

---

## Acceptance Criteria

- [ ] All tasks completed
- [ ] All validation commands pass
- [ ] Tests written and passing
- [ ] No type errors
- [ ] No lint errors
- [ ] Matches UX design (if applicable)

## Completion Checklist

- [ ] Code follows discovered patterns
- [ ] Error handling matches codebase style
- [ ] Logging follows codebase conventions
- [ ] Tests follow test patterns
- [ ] No hardcoded values
- [ ] Documentation updated (if needed)
- [ ] No unnecessary scope additions
- [ ] Self-contained — no questions needed during implementation

## Risks

| Risk | Likelihood | Impact | Mitigation |
| ---- | ---------- | ------ | ---------- |
| ...  | ...        | ...    | ...        |

## Notes

[Any additional context, decisions, or observations]
