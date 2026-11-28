# Parse PRD Output

## Contents

- Expected Source Structure
- Step 1: Extract Project Context
- Step 2: Extract Phase and Task Structure
- Step 3: Extract Feature Items from MoSCoW
- Step 4: Build Agentic Context for Child Issues
- Step 5: Extract Anti-Scope Items
- Step 6: Extract Decision Items
- Step 7: Extract Risk Context
- Issue Mapping
- Priority Classification
- Source-Specific Labels

Extraction instructions for `*.prd.md` documents produced by `ycc:prp-prd`.

## Expected Source Structure

A single file at `docs/prps/prds/[feature-name].prd.md` containing:

| Section                      | What to Extract                                     |
| ---------------------------- | --------------------------------------------------- |
| `## Problem Statement`       | Project name, problem description for all issues    |
| `## Evidence`                | Context block for tracking issues                   |
| `## Proposed Solution`       | Solution summary for all issue bodies               |
| `## Key Hypothesis`          | Success hypothesis for tracking issue context       |
| `## What We're NOT Building` | Anti-scope items become deferred issues             |
| `## Success Metrics`         | Tracking issue success criteria                     |
| `## Open Questions`          | Open questions become decision issues               |
| `## Users & Context`         | User context for issue bodies                       |
| `## Solution Detail`         | Core Capabilities (MoSCoW) for feature extraction   |
| `## Technical Approach`      | Architecture notes, risks for context blocks        |
| `## Implementation Phases`   | Phase/task structure for issue hierarchy            |
| `## Decisions Log`           | Resolved decisions as context (not separate issues) |
| `## Research Summary`        | Additional context for tracking issues              |

## Step 1: Extract Project Context

Read the Problem Statement and Proposed Solution to determine:

- **Project name** (first heading `# {name}` or first sentence subject)
- **Problem description** (the Problem Statement content)
- **Solution summary** (the Proposed Solution content)
- **Key hypothesis** (from Key Hypothesis section)

This context block is included in every child issue body under "Source Context".

## Step 2: Extract Phase and Task Structure

Locate the `## Implementation Phases` section. Extract:

**From the phase table:**

- Phase number, name, description, status, parallelism, dependencies

**From `### Phase Details`:**

For each phase:

- Phase number and name
- Goal
- Scope (bounded deliverables)
- Success signal

If `### Phase Details` is absent, use the table rows as the phase definitions.

## Step 3: Extract Feature Items from MoSCoW

Locate `## Solution Detail > ### Core Capabilities (MoSCoW)`. Extract:

**For each capability row:**

- Priority level (Must/Should/Could/Won't)
- Capability name
- Rationale

Map capabilities to phases:

- **Must** capabilities map to the earliest applicable phase
- **Should** capabilities map to middle phases
- **Could** capabilities become low-priority items in later phases
- **Won't** capabilities become anti-scope/deferred issues

If the MoSCoW table is absent, derive features from the MVP Scope and Phase Details instead.

## Step 4: Build Agentic Context for Child Issues

For each child task issue, assemble context from the PRD sections:

### Mandatory Reading

Build a mandatory reading list from:

- The PRD file itself (e.g., "Read `## Technical Approach` for architecture constraints")
- `## Users & Context` for user flow understanding
- `## Solution Detail > ### User Flow` for the critical path

### Scope

Infer scope from:

- Phase Details scope and goal
- Technical Approach architecture notes
- Relevant MoSCoW capability descriptions

### Implementation Guidance

Synthesize from:

- The phase goal and scope in Phase Details
- Technical Approach architecture notes and feasibility assessment
- MoSCoW rationale for the relevant capability

### Acceptance Criteria

Build from:

- Phase Details success signal
- `## Success Metrics` (relevant metrics for this phase)
- `## Key Hypothesis` (how this phase contributes to validation)

## Step 5: Extract Anti-Scope Items

Check `## What We're NOT Building`. Extract each item:

- **Item name** (the text before the em dash)
- **Reason** (the text after the em dash)

Each anti-scope item becomes a deferred issue with the `deferred` label.

Also extract **Won't** rows from the MoSCoW table as additional anti-scope items.

## Step 6: Extract Decision Items

Check `## Open Questions`. If present, extract each unchecked item:

- **Question text**
- Infer which phase it blocks (if determinable from context)

Each open question becomes a separate issue with the `needs-decision` label.

**Do NOT create issues for checked (resolved) questions.**

Check `## Decisions Log` for resolved decisions. These do NOT become separate issues. Instead, note them as context on the relevant tracking issue.

## Step 7: Extract Risk Context

From `## Technical Approach > Technical Risks`, extract:

- Risk name, likelihood, mitigation

Risk items do NOT become separate issues. Instead, append relevant risks as a context block on the corresponding tracking issue.

## Issue Mapping

| Source Element                        | Issue Type                    | Template            |
| ------------------------------------- | ----------------------------- | ------------------- |
| Each phase from Implementation Phases | 1 tracking issue              | `tracking-issue.md` |
| Each Must/Should capability per phase | 1 child issue under its phase | `feature-issue.md`  |
| Each Could capability                 | 1 child issue (low priority)  | `feature-issue.md`  |
| Each Won't item / anti-scope entry    | 1 deferred issue              | `feature-issue.md`  |
| Each open question                    | 1 decision issue (no parent)  | `feature-issue.md`  |

## Priority Classification

| Signal                             | Priority Label    |
| ---------------------------------- | ----------------- |
| Phase 1 tasks, Must capabilities   | `priority:high`   |
| Phase 2 tasks, Should capabilities | `priority:medium` |
| Phase 3+ tasks, Could capabilities | `priority:low`    |
| Open questions blocking Phase 1    | `priority:high`   |
| Open questions blocking later      | `priority:medium` |

## Source-Specific Labels

All issues from this source type receive:

- `source:prd`
- Child feature issues: `type:feature`
- Anti-scope/Won't issues: `deferred`
- Open question issues: `needs-decision`
- Phase labels: `phase:{N}`
