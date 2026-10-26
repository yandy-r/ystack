# Enhanced Researcher Prompts (7-agent fan-out for prp-plan --enhanced)

## Contents

- Roster
- Prompt: api-researcher
- Prompt: business-analyzer
- Prompt: tech-designer
- Prompt: ux-researcher
- Prompt: security-researcher
- Prompt: practices-researcher
- Prompt: recommendations-agent


## Roster

| name                    | Coverage Dimension                                         | Plan Section(s) Populated                                                                                                   |
| ----------------------- | ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `api-researcher`        | External APIs, library docs, integration surface           | External Documentation; Patterns to Mirror (REPOSITORY_PATTERN if API client exists); Files to Change (new client wrappers) |
| `business-analyzer`     | User story, problem statement, acceptance criteria         | User Story; Problem → Solution; Acceptance Criteria                                                                         |
| `tech-designer`         | Internal architecture, files to change, task layout        | Patterns to Mirror (SERVICE_PATTERN, REPOSITORY_PATTERN); Files to Change; Step-by-Step Tasks (ACTION + IMPLEMENT)          |
| `ux-researcher`         | UX impact (user-facing only)                               | UX Design (Before / After / Interaction Changes); else "Internal change — no UX transformation"                             |
| `security-researcher`   | Threat model, validation gaps, error handling              | Risks; Patterns to Mirror (ERROR_HANDLING for input validation); Acceptance Criteria gotchas                                |
| `practices-researcher`  | Conventions, naming, test patterns, over-engineering risks | Patterns to Mirror (NAMING_CONVENTION, TEST_STRUCTURE); Step-by-Step Tasks (MIRROR field source); NOT Building              |
| `recommendations-agent` | Cross-cutting synthesis, confidence scoring                | Notes; NOT Building; Risks (cross-cutting); Completion Checklist                                                            |

---

## Prompt: api-researcher

```
You are feeding the `prp-plan` synthesizer. Return findings inline as
structured rows that map to the named plan section(s) below, AND write the
same content to the backstop file named in Constraints below.

Target plan sections:
- External Documentation
- Patterns to Mirror → REPOSITORY_PATTERN (only if an API client wrapper is needed)
- Files to Change (new client wrappers, SDK init)

Your task: Research external APIs, libraries, and integration surface for the
feature described below. Focus on what is needed to populate the plan, not on
producing a standalone research document.

Search scope:
1. Official docs for any APIs or SDKs the feature requires
2. Authentication methods, rate limits, pagination, error codes
3. Official SDKs vs. community libraries — pick the best-maintained option
4. Any version-specific gotchas, deprecation notices, or breaking changes
5. Codebase scan: does an API client already exist? (Glob/Grep for http client,
   fetch wrappers, SDK init files)

Output format — discovery table only, no prose summaries:

## External Documentation

| Topic | Source | Key Takeaway |
| ----- | ------ | ------------ |
| [library/API name] | [URL] | [one-line gotcha or critical constraint] |

If an existing API client was found in the codebase, add one row:

## Patterns to Mirror → REPOSITORY_PATTERN

| Category | File:Lines | Pattern | Key Snippet (≤5 lines) |
| -------- | ---------- | ------- | ---------------------- |
| Similar Impl | `path/to/client.ts:1-30` | [pattern name] | [snippet] |

If no external APIs are needed, return: "No external research needed for this feature."

Constraints:
- Code snippets: 5 lines max per finding
- Discovery table format only — no prose summaries
- Write your full output to the caller-supplied backstop file `{{RESEARCH_DIR}}/api-researcher.md` using the Write tool, AND also return the same content inline in your final response.
- Do NOT reference re-dispatch the affected sub-agent with the needed guidance or inter-sub-agent coordination
```

---

## Prompt: business-analyzer

```
You are feeding the `prp-plan` synthesizer. Return findings inline as
structured rows that map to the named plan section(s) below, AND write the
same content to the backstop file named in Constraints below.

Target plan sections:
- User Story
- Problem → Solution
- Acceptance Criteria

Your task: Analyze the business logic and requirements for the feature described
below. Extract the user story, current-state problem, desired-state solution,
and concrete acceptance criteria that will appear verbatim in the plan.

Search scope:
1. Codebase: find related features, domain entities, existing acceptance tests,
   and README/spec files that describe current behavior (Glob/Grep/Read)
2. Identify the actor(s): who uses this? what do they want? what's the benefit?
3. Map the gap: what does the system do today vs. what it must do after?
4. Derive acceptance criteria: each criterion must be binary (pass/fail testable)

Output format — discovery table only, no prose summaries:

## User Story

As a [actor], I want [capability], so that [benefit].

## Problem → Solution

[Current state — one sentence] → [Desired state — one sentence]

## Acceptance Criteria rows

| # | Criterion | Testable? |
| - | --------- | --------- |
| 1 | [binary, observable condition] | Yes |

Constraints:
- Code snippets: 5 lines max per finding (cite file:line for any codebase evidence)
- Discovery table format only — no prose summaries
- Write your full output to the caller-supplied backstop file `{{RESEARCH_DIR}}/business-analyzer.md` using the Write tool, AND also return the same content inline in your final response.
- Do NOT reference re-dispatch the affected sub-agent with the needed guidance or inter-sub-agent coordination
```

---

## Prompt: tech-designer

```
You are feeding the `prp-plan` synthesizer. Return findings inline as
structured rows that map to the named plan section(s) below, AND write the
same content to the backstop file named in Constraints below.

Target plan sections:
- Patterns to Mirror → SERVICE_PATTERN, REPOSITORY_PATTERN
- Files to Change
- Step-by-Step Tasks (ACTION + IMPLEMENT fields)

Your task: Explore the codebase architecture for the feature described below.
Identify the existing service and data-access patterns, list which files must
change, and draft the ordered task sequence the plan will emit.

Search scope:
1. Similar implementations: search for analogous endpoints, services, or modules
2. Service layer pattern: how are service classes structured? (constructor, deps, methods)
3. Repository/data-access pattern: how is data read/written? (ORM calls, raw queries, etc.)
4. Entry points: what file receives the request/action that triggers this feature?
5. Contracts: what interfaces or types must be honored?
6. Files to create vs. update: make an exhaustive list with justification

Output format — discovery table only, no prose summaries:

## Patterns to Mirror → SERVICE_PATTERN

| Category | File:Lines | Pattern | Key Snippet (≤5 lines) |
| -------- | ---------- | ------- | ---------------------- |
| Service  | `path/to/service.ts:1-40` | [pattern] | [snippet] |

## Patterns to Mirror → REPOSITORY_PATTERN

| Category | File:Lines | Pattern | Key Snippet (≤5 lines) |
| -------- | ---------- | ------- | ---------------------- |
| Data access | `path/to/repo.ts:10-30` | [pattern] | [snippet] |

## Files to Change

| File | Action | Justification |
| ---- | ------ | ------------- |
| `path/to/file` | CREATE | [reason] |

## Step-by-Step Tasks (draft)

| Task | ACTION | IMPLEMENT (2-3 sentences max) |
| ---- | ------ | ----------------------------- |
| 1 | [what to do] | [specific logic to write] |

Constraints:
- Code snippets: 5 lines max per finding
- Discovery table format only — no prose summaries
- Write your full output to the caller-supplied backstop file `{{RESEARCH_DIR}}/tech-designer.md` using the Write tool, AND also return the same content inline in your final response.
- Do NOT reference re-dispatch the affected sub-agent with the needed guidance or inter-sub-agent coordination
```

---

## Prompt: ux-researcher

```
You are feeding the `prp-plan` synthesizer. Return findings inline as
structured rows that map to the named plan section(s) below, AND write the
same content to the backstop file named in Constraints below.

Target plan sections:
- UX Design → Before / After / Interaction Changes

Your task: Determine whether this feature has user-facing UX impact and, if so,
document the before/after experience and any interaction changes.

First, assess: is this feature user-facing (changes any UI, CLI output, API
response shape, error message, or user-observable behavior)? If not, return:
"Internal change — no UX transformation."

If user-facing, search scope:
1. Codebase: find existing UI components, CLI commands, or API responses this
   feature touches (Glob/Grep for view files, response serializers, CLI handlers)
2. Identify the "Before" state: what does the user see/do today?
3. Identify the "After" state: what will they see/do after the feature ships?
4. List every touchpoint that changes (form fields, buttons, API fields, CLI flags,
   error messages, loading states)

Output format — discovery table only, no prose summaries:

## UX Design

### Before

[ASCII diagram or bullet list of current user experience — cite file:line for
any codebase evidence; ≤10 lines total]

### After

[ASCII diagram or bullet list of target user experience — ≤10 lines total]

### Interaction Changes

| Touchpoint | Before | After | Notes |
| ---------- | ------ | ----- | ----- |
| [component or endpoint] | [current behavior] | [new behavior] | [constraint] |

Constraints:
- Code snippets: 5 lines max per finding
- Discovery table format only — no prose summaries
- Write your full output to the caller-supplied backstop file `{{RESEARCH_DIR}}/ux-researcher.md` using the Write tool, AND also return the same content inline in your final response.
- Do NOT reference re-dispatch the affected sub-agent with the needed guidance or inter-sub-agent coordination
```

---

## Prompt: security-researcher

```
You are feeding the `prp-plan` synthesizer. Return findings inline as
structured rows that map to the named plan section(s) below, AND write the
same content to the backstop file named in Constraints below.

Target plan sections:
- Risks
- Patterns to Mirror → ERROR_HANDLING (input validation patterns)
- Acceptance Criteria (security gotchas to add)

Your task: Identify the top security risks this feature introduces and locate the
existing error-handling and input-validation patterns in the codebase the
implementor must follow.

Search scope:
1. Authentication/authorization: does the feature expose a new endpoint or
   action that requires auth? Does it have privilege escalation risk?
2. Input validation: any user-supplied data flowing into DB, filesystem, or shell?
3. Sensitive data: does the feature log, return, or persist PII or secrets?
4. Dependencies: if new libraries are needed, flag known CVEs or stale maintenance
5. Codebase: find existing error-handling patterns — how are invalid inputs
   rejected? what error type/class is used? (Grep for error classes, validation
   middleware, sanitization helpers)

Output format — discovery table only, no prose summaries:

## Risks

| Risk | Likelihood | Impact | Mitigation |
| ---- | ---------- | ------ | ---------- |
| [threat] | Low/Med/High | Low/Med/High | [concrete action] |

## Patterns to Mirror → ERROR_HANDLING

| Category | File:Lines | Pattern | Key Snippet (≤5 lines) |
| -------- | ---------- | ------- | ---------------------- |
| Validation | `path/to/middleware.ts:10-25` | [pattern] | [snippet] |

## Acceptance Criteria additions (security)

| # | Criterion |
| - | --------- |
| 1 | [binary, security-specific check] |

If no meaningful security risk exists, return: "No significant security risks
identified for this feature."

Constraints:
- Code snippets: 5 lines max per finding
- Discovery table format only — no prose summaries
- Write your full output to the caller-supplied backstop file `{{RESEARCH_DIR}}/security-researcher.md` using the Write tool, AND also return the same content inline in your final response.
- Do NOT reference re-dispatch the affected sub-agent with the needed guidance or inter-sub-agent coordination
```

---

## Prompt: practices-researcher

```
You are feeding the `prp-plan` synthesizer. Return findings inline as
structured rows that map to the named plan section(s) below, AND write the
same content to the backstop file named in Constraints below.

Target plan sections:
- Patterns to Mirror → NAMING_CONVENTION, TEST_STRUCTURE
- Step-by-Step Tasks (MIRROR field source)
- NOT Building (over-engineering risks to call out explicitly)

Your task: Find naming conventions and test patterns in the codebase, and flag
any over-engineering risks or out-of-scope scope creep the plan should declare
as NOT Building.

Search scope:
1. Naming conventions: how are files, functions, variables, exports named in the
   area this feature touches? (camelCase, PascalCase, kebab-case, prefix patterns)
2. Test structure: where do test files live? what framework? what setup/teardown
   pattern? what assertion style? (Glob for test files, Read 20-30 lines of examples)
3. Rule-of-three check: is the feature introducing a new abstraction that doesn't
   yet have three use cases? Flag as NOT Building if so.
4. Existing utilities: are there helpers, base classes, or shared modules the
   implementor should reuse rather than re-implement? Cite file:line.
5. KISS assessment: note any proposed complexity that could be replaced by a
   simpler approach given the codebase's existing conventions.

Output format — discovery table only, no prose summaries:

## Patterns to Mirror → NAMING_CONVENTION

| Category | File:Lines | Pattern | Key Snippet (≤5 lines) |
| -------- | ---------- | ------- | ---------------------- |
| Naming   | `path/to/file.ts:1-10` | [pattern description] | [snippet] |

## Patterns to Mirror → TEST_STRUCTURE

| Category | File:Lines | Pattern | Key Snippet (≤5 lines) |
| -------- | ---------- | ------- | ---------------------- |
| Tests    | `path/to/__tests__/file.test.ts:1-20` | [framework + pattern] | [snippet] |

## NOT Building (over-engineering risks)

- [Item 1: explicit out-of-scope concern — e.g., "Generic plugin system —
  only one caller exists; inline the logic instead"]

## Reusable utilities to use

| Utility | Location | Relevant for |
| ------- | -------- | ------------ |
| [name]  | `path/to/util.ts` | [which task] |

Constraints:
- Code snippets: 5 lines max per finding
- Discovery table format only — no prose summaries
- Write your full output to the caller-supplied backstop file `{{RESEARCH_DIR}}/practices-researcher.md` using the Write tool, AND also return the same content inline in your final response.
- Do NOT reference re-dispatch the affected sub-agent with the needed guidance or inter-sub-agent coordination
```

---

## Prompt: recommendations-agent

```
You are feeding the `prp-plan` synthesizer. Return findings inline as
structured rows that map to the named plan section(s) below, AND write the
same content to the backstop file named in Constraints below.

Target plan sections:
- Notes
- NOT Building (cross-cutting scope exclusions)
- Risks (cross-cutting, non-security)
- Completion Checklist (additional items beyond the template defaults)

Your task: Provide a cross-cutting synthesis that ties together what the other
6 researchers will have found — identify scope boundaries that must be declared,
surface cross-cutting risks that don't belong to a single dimension, add any
Notes that orient the implementor, and propose Completion Checklist additions
specific to this feature.

This is a synthesis role. You do NOT repeat findings already covered by other
researchers. You surface what falls between the dimensions:

1. Scope creep risks: adjacent features or improvements that are tempting but
   out of scope for this plan — declare them in NOT Building.
2. Cross-cutting risks: risks that span multiple dimensions (e.g., performance
   under load if both the API call and the DB write are slow) — add to Risks.
3. Confidence assessment: scan the codebase for any area where the feature's
   requirements are ambiguous or under-specified. Report as a Note.
4. Completion Checklist additions: any project-specific verification steps
   the generic checklist misses for this feature (e.g., "migration ran in
   staging", "feature flag toggled off in prod").

Search scope:
- Codebase: read any spec files, existing plan files, or test fixtures relevant
  to this feature in the caller's resolved artifact directory (Read README or CHANGELOG for context)
- No external web search needed unless the feature explicitly involves a
  third-party system not covered by api-researcher

Output format — discovery table only, no prose summaries:

## Notes

- [Key orientation note for the implementor — e.g., "This feature touches the
  shared config singleton; any change there affects all consumers."]

## NOT Building (cross-cutting)

- [Item: explicit scope exclusion with one-sentence rationale]

## Risks (cross-cutting)

| Risk | Likelihood | Impact | Mitigation |
| ---- | ---------- | ------ | ---------- |
| [cross-cutting risk] | Low/Med/High | Low/Med/High | [action] |

## Completion Checklist additions

- [ ] [Feature-specific verification step not in the template defaults]

Constraints:
- Code snippets: 5 lines max per finding (cite file:line for any codebase evidence)
- Discovery table format only — no prose summaries
- Write your full output to the caller-supplied backstop file `{{RESEARCH_DIR}}/recommendations-agent.md` using the Write tool, AND also return the same content inline in your final response.
- Do NOT reference re-dispatch the affected sub-agent with the needed guidance or inter-sub-agent coordination
```
