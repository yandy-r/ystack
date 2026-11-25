# Parse Feature-Spec Output

## Contents

- Expected Source Structure
- Step 1: Extract Project Context
- Step 2: Extract Phase and Task Structure
- Step 3: Build Agentic Context for Child Issues
- Step 4: Extract Decision Items (Optional)
- Step 5: Extract Risk Context
- Issue Mapping
- Priority Classification
- Source-Specific Labels

Extraction instructions for `feature-spec.md` documents produced by `/skill:feature-research`.

## Expected Source Structure

A single file at `docs/plans/[feature-name]/feature-spec.md` containing:

| Section                                        | What to Extract                                   |
| ---------------------------------------------- | ------------------------------------------------- |
| `## Executive Summary`                         | Project name, description for all issue bodies    |
| `## External Dependencies`                     | API docs, libraries, services for context blocks  |
| `## Business Requirements > User Stories`      | User stories become acceptance criteria           |
| `## Business Requirements > Success Criteria`  | Tracking issue success criteria                   |
| `## Technical Specifications`                  | Architecture, data models, API design for context |
| `## Recommendations > Implementation Approach` | Phasing strategy for grouping                     |
| `## Task Breakdown Preview`                    | Phase/task structure for issue hierarchy          |
| `## Risk Assessment`                           | Risk items for tracking issue context             |
| `## Decisions Needed`                          | Decision items become separate issues             |

## Step 1: Extract Project Context

Read the Executive Summary to determine:

- **Project name** (first heading or first sentence subject)
- **Project description** (3-5 sentence summary)
- **Date** (from file metadata or document content)

This context block is included in every child issue body under "Source Context".

## Step 2: Extract Phase and Task Structure

Locate the `## Task Breakdown Preview` section. Extract:

**For each phase:**

- Phase number and name
- Phase objective/description
- Task list (bulleted items under the phase)
- Parallelization notes (if present)

If `## Task Breakdown Preview` is absent, fall back to `## Recommendations > Implementation Approach` and extract phasing from there.

**For each task within a phase:**

- Task name and brief description
- Inferred complexity from the description

## Step 3: Build Agentic Context for Child Issues

For each child task issue, assemble context from the feature-spec sections:

### Mandatory Reading

Build a mandatory reading list from:

- Relevant sections of the feature-spec itself (e.g., "Read `## Technical Specifications > Data Models` for schema details")
- External documentation links from `## External Dependencies`
- API documentation URLs from `## External Dependencies > APIs and Services`

### Scope

Infer files to create/modify from:

- `## Technical Specifications > System Integration` (files to create/modify lists)
- Task description context

### Implementation Guidance

Synthesize from:

- The task description in Task Breakdown Preview
- Relevant Technical Specifications subsection
- Relevant Recommendations subsection

### Acceptance Criteria

Build from:

- `## Business Requirements > User Stories` (relevant to this task)
- `## Business Requirements > Success Criteria` (relevant items)
- `## Business Requirements > Edge Cases` (relevant scenarios)

## Step 4: Extract Decision Items (Optional)

Check for a `## Decisions Needed` section. If present, extract each decision:

- **Decision name/area**
- **Options** listed
- **Impact** description
- **Recommendation** (if present)

Each open decision becomes a separate issue with the `needs-decision` label.

If the document instead has `## Resolved Decisions` (decisions already finalized), do NOT create separate issues for them. Instead, note resolved decisions as context on the relevant tracking issue.

## Step 5: Extract Risk Context

From `## Risk Assessment > Technical Risks`, extract:

- Risk name, likelihood, impact, mitigation
- Security considerations (Critical/Warning/Advisory levels)

Risk items do NOT become separate issues. Instead, append relevant risks as a context block on the corresponding tracking issue.

## Issue Mapping

| Source Element                      | Issue Type                        | Template            |
| ----------------------------------- | --------------------------------- | ------------------- |
| Each phase from Task Breakdown      | 1 tracking issue                  | `tracking-issue.md` |
| Each task within a phase            | 1 child issue under its phase     | `task-issue.md`     |
| Each decision from Decisions Needed | 1 child issue (no parent tracker) | `feature-issue.md`  |

## Priority Classification

| Signal                          | Priority Label    |
| ------------------------------- | ----------------- |
| Phase 1 tasks                   | `priority:high`   |
| Phase 2 tasks                   | `priority:medium` |
| Phase 3+ tasks                  | `priority:low`    |
| Decisions blocking Phase 1      | `priority:high`   |
| Decisions blocking later phases | `priority:medium` |

## Source-Specific Labels

All issues from this source type receive:

- `source:feature-spec`
- Child task issues: `type:task`
- Decision issues: `needs-decision`
- Phase labels: `phase:{N}`
