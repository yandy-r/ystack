# Parse PRP Plan Output

## Contents

- Expected Source Structure
- Step 1: Detect Plan Mode
- Step 2: Extract Plan Context
- Step 3: Extract Tasks
- Step 4: Build Tracking Issue Content
- Issue Mapping
- Priority Classification
- Source-Specific Labels

Extraction instructions for plan documents produced by `prp-plan`.

## Expected Source Structure

A single file at `docs/prps/plans/{name}.plan.md`. PRP plans come in two structural variants that must be detected and handled differently.

### Variant Detection

Check for these signals in order:

1. **Standard format** (ACTION/IMPLEMENT fields): Contains `### Task` headings AND task bodies with `ACTION:` or `IMPLEMENT:` field labels
2. **Narrative format** (bold task markers): Contains `**T` bold task markers (e.g., `**T1 — Title**`) with `_Depends on []._` italic dependency notation and free-form narrative descriptions ending with `Acceptance:` criteria

Both formats may include a `## Batches` section (parallel mode) or be sequential-only.

### Common Sections (both variants)

| Section                                                   | What to Extract                                                    |
| --------------------------------------------------------- | ------------------------------------------------------------------ |
| `## Summary`                                              | Project description for all issue bodies                           |
| `## User Story`                                           | User story for tracking issue                                      |
| `## Problem -> Solution`                                  | Context for tracking issue (may appear as `## Problem → Solution`) |
| `## Metadata`                                             | Complexity, estimated files for labels                             |
| `## Patterns to Mirror`                                   | Pattern references for child issues                                |
| `## Acceptance Criteria`                                  | Tracking issue success criteria                                    |
| `## Batches` or `## Batches (parallel execution summary)` | Batch groupings for parallel mode                                  |

### Standard Format Sections

| Section                 | What to Extract                             |
| ----------------------- | ------------------------------------------- |
| `## Mandatory Reading`  | P0/P1/P2 reading list for every child issue |
| `## Files to Change`    | Cross-reference with tasks for scope        |
| `## NOT Building`       | Anti-scope block on tracking issue          |
| `## Step-by-Step Tasks` | Each `### Task N:` becomes a child issue    |
| `## Testing Strategy`   | Testing section on tracking issue           |
| `## Risks`              | Risk context on tracking issue              |

### Narrative Format Sections

| Section                     | What to Extract                                  |
| --------------------------- | ------------------------------------------------ |
| `## References (file:line)` | Code reference list (replaces Mandatory Reading) |
| `## Out of scope`           | Anti-scope block (replaces NOT Building)         |
| `## Tasks`                  | Task container with batch sub-headings           |
| `## Gotchas / Risks`        | Risk context on tracking issue                   |
| `## Validation Commands`    | Build/test commands for tracking issue           |

## Step 1: Detect Plan Mode

Check for a `## Batches` section (may be `## Batches (parallel execution summary)`):

- **If Batches section exists**: Parallel mode -- batches define tracking issue groupings
- **If no Batches section**: Sequential mode -- tasks are numbered sequentially

## Step 2: Extract Plan Context

Read global sections to build context blocks:

### Summary and User Story

- **Project name**: From the document title or Summary first sentence
- **Summary**: Full content of `## Summary`
- **User Story**: Full "As a... I want... so that..." block
- **Problem -> Solution**: Current state vs desired state

### Code References / Mandatory Reading (Global)

**Standard format**: Parse the `## Mandatory Reading` table:

| Priority | File        | Lines | Why                      |
| -------- | ----------- | ----- | ------------------------ |
| P0       | src/auth.ts | 1-50  | Core auth patterns       |
| P1       | src/db.ts   | 20-80 | Database access patterns |

Include P0 items in EVERY child issue. P1 in relevant child issues. P2 as optional context.

**Narrative format**: Parse `## References (file:line)` section. Treat all listed files as mandatory reading context. Group by sub-heading if present (e.g., "Code under audit", "Patterns to reference").

### Patterns to Mirror

Extract code snippets and source references from `## Patterns to Mirror`. Include in child issues as "Patterns to Follow", referencing the pattern name and source file.

### Files to Change

**Standard format**: Parse `## Files to Change` table to build a global file-action map.

**Narrative format**: No standalone table exists. File changes are embedded in individual task descriptions. Extract files-to-create and files-to-modify from each task body individually.

### Anti-Scope

**Standard format**: Extract `## NOT Building` items.
**Narrative format**: Extract `## Out of scope` items.

Include as "Out of Scope" block on the top-level tracking issue.

## Step 3: Extract Tasks

### Standard Format Tasks

For each `### Task N: [Title]` under `## Step-by-Step Tasks`, extract:

- **Task number** (N)
- **Task title**
- **ACTION**: Brief action description (becomes issue title suffix)
- **IMPLEMENT**: Detailed implementation instructions
- **MIRROR**: Pattern to follow (reference from Patterns to Mirror)
- **IMPORTS**: Required imports or dependencies
- **GOTCHA**: Warnings and pitfalls
- **VALIDATE**: Validation/testing criteria

Not all fields may be present. Adapt to available content.

### Narrative Format Tasks

Tasks appear under `## Tasks`, organized under `### Batch X — description` sub-headings. Each task is a bold-prefixed block:

```
**T{N} — {Title}** _Depends on [{deps}]._ {narrative description}
... continued description ...
Acceptance: {acceptance criteria}
```

For each task, extract:

- **Task number** (N from `T{N}`)
- **Task title** (text between `—` and `**`)
- **Dependencies**: Parse from `_Depends on [{deps}]._` (e.g., `[]` for none, `[T2]` for single dep)
- **Batch assignment**: From the `### Batch X` sub-heading the task appears under
- **Implementation guidance**: The full narrative description (everything between the dependency notation and "Acceptance:")
- **Acceptance criteria**: Text following `Acceptance:` at the end of the task block
- **Files to create/modify**: Extract file paths mentioned in the narrative (look for path patterns like `src/...`, `crates/...`, `tests/...`)

### Mapping Narrative Fields to Task Issue Template

| Task Issue Field            | Narrative Format Source                                      |
| --------------------------- | ------------------------------------------------------------ |
| task_summary                | Task title + first sentence of narrative                     |
| mandatory_reading_list      | Global References list + files mentioned with `:line` ranges |
| files_to_create             | Paths in narrative prefixed by "Create" or "Add"             |
| files_to_modify             | Paths in narrative prefixed by "Update", "Change", "Fix"     |
| implementation_instructions | Full narrative description                                   |
| pattern_references          | Patterns to Mirror table entries referenced in the narrative |
| gotchas_warnings            | Global Gotchas/Risks relevant to this task                   |
| validation_criteria         | `Acceptance:` statement from the task block                  |
| dependency_info             | `_Depends on [...]._` notation                               |

## Step 4: Build Tracking Issue Content

### Sequential Mode (<=6 tasks)

Create 1 top-level tracking issue containing:

- Summary and User Story
- Checkbox list of all task issues
- Acceptance Criteria from the plan
- Testing Strategy / Validation Commands
- Risks / Gotchas
- Anti-scope (NOT Building / Out of scope)

### Sequential Mode (>6 tasks)

Group tasks into logical clusters and create sub-tracking issues:

1. **Foundation** (setup, configuration, scaffolding tasks)
2. **Core Implementation** (main feature logic tasks)
3. **Testing and Polish** (test, validation, documentation tasks)

Each cluster becomes a tracking issue. Create 1 top-level tracking issue linking to the cluster trackers.

### Parallel/Batch Mode

Each Batch becomes a tracking issue containing:

- Batch description (from Batches table or `### Batch X` heading)
- Batch dependencies (from Batches table "Depends on" column)
- Checkbox list of task issues in this batch
- Relevant acceptance criteria

Create 1 top-level tracking issue linking to all batch trackers.

**Batch naming**: Use the batch identifier from the document (e.g., "Batch A", "Batch B" for letter-based; "Batch 1", "Batch 2" for number-based).

## Issue Mapping

### Sequential Mode (<=6 tasks)

| Source Element | Issue Type                 | Template            |
| -------------- | -------------------------- | ------------------- |
| Entire plan    | 1 top-level tracking issue | `tracking-issue.md` |
| Each Task N    | 1 child issue              | `task-issue.md`     |

### Sequential Mode (>6 tasks)

| Source Element    | Issue Type                      | Template            |
| ----------------- | ------------------------------- | ------------------- |
| Entire plan       | 1 top-level tracking issue      | `tracking-issue.md` |
| Each task cluster | 1 sub-tracking issue            | `tracking-issue.md` |
| Each Task N       | 1 child issue under its cluster | `task-issue.md`     |

### Parallel/Batch Mode

| Source Element     | Issue Type                    | Template            |
| ------------------ | ----------------------------- | ------------------- |
| Entire plan        | 1 top-level tracking issue    | `tracking-issue.md` |
| Each Batch         | 1 batch tracking issue        | `tracking-issue.md` |
| Each Task in batch | 1 child issue under its batch | `task-issue.md`     |

## Priority Classification

| Signal                                       | Priority Label    |
| -------------------------------------------- | ----------------- |
| Sequential: first 2 tasks or Batch A/1 tasks | `priority:high`   |
| Sequential: middle tasks or Batch B/2 tasks  | `priority:medium` |
| Sequential: last tasks or Batch C+/3+ tasks  | `priority:low`    |

## Source-Specific Labels

All issues from this source type receive:

- `source:prp-plan`
- Child task issues: `type:task`
- Batch mode: `batch:{letter-or-number}` labels (e.g., `batch:a`, `batch:1`)
- Sequential mode with clusters: `phase:{N}` labels (Foundation=1, Core=2, Testing=3)
