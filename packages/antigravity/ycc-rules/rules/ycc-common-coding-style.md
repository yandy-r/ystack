---
trigger: model_decision
description: When implementing or refactoring code, preserve request scope, trust
  boundaries and observable verification; prefer simple, cohesive code.
---

# Coding Style

## Immutability (CRITICAL)

ALWAYS create new objects, NEVER mutate existing ones:

```
// Pseudocode
WRONG:  modify(original, field, value) → changes original in-place
CORRECT: update(original, field, value) → returns new copy with change
```

Rationale: Immutable data prevents hidden side effects, makes debugging easier, and enables safe concurrency.

## Core Principles

### KISS (Keep It Simple)

- Prefer the simplest solution that actually works
- Avoid premature optimization
- Optimize for clarity over cleverness

### DRY (Don't Repeat Yourself)

- Extract repeated logic into shared functions or utilities
- Avoid copy-paste implementation drift
- Introduce abstractions when repetition is real, not speculative

### YAGNI (You Aren't Gonna Need It)

- Do not build features or abstractions before they are needed
- Avoid speculative generality
- Start simple, then refactor when the pressure is real

## Assumptions, Scope, and Verification

Guidance adapted from [Andrej Karpathy’s observations](https://x.com/karpathy/status/2015883857489522876) on LLM coding pitfalls.

### Think Before Coding

- State material assumptions before implementing
- Present competing interpretations; ask when uncertainty affects correctness or scope

### Surgical Changes

- Tie each changed line to the request; no adjacent cleanup, unrelated refactors, or format changes
- Match existing style
- Remove only imports, variables, or functions made unused by the change; report pre-existing dead code unless deletion was requested
- Preserve trust-boundary validation, necessary error handling, security, and accessibility

### Observable Success Criteria

- Define observable criteria and corresponding checks before coding; pair plan steps with checks
- Bugs: reproduce the failure with a test, then verify it passes
- Refactors: run relevant tests before and after
- Run relevant checks and report results against the criteria; unrelated passing checks are not success

## File Organization

MANY SMALL FILES > FEW LARGE FILES:

- High cohesion, low coupling
- 200-400 lines typical, 800 max
- Extract utilities from large modules
- Organize by feature/domain, not by type

## Error Handling

ALWAYS handle errors comprehensively:

- Handle errors explicitly at every level
- Provide user-friendly error messages in UI-facing code
- Log detailed error context on the server side
- Never silently swallow errors

## Input Validation

ALWAYS validate at system boundaries:

- Validate all user input before processing
- Use schema-based validation where available
- Fail fast with clear error messages
- Never trust external data (API responses, user input, file content)

## Code Smells to Avoid

### Deep Nesting

Prefer early returns over nested conditionals once the logic starts stacking.

### Magic Numbers

Use named constants for meaningful thresholds, delays, and limits.

### Long Functions

Split large functions into focused pieces with clear responsibilities.
