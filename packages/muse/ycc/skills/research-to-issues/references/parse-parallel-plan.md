# Parse Parallel-Plan Output

## Contents

- Expected Source Structure
- Step 1: Extract Plan Context
- Step 2: Extract Phase Structure
- Step 3: Extract Tasks per Phase
- Step 4: Extract Advice
- Issue Mapping
- Dependency Cross-References
- Priority Classification
- Source-Specific Labels

Extraction instructions for `parallel-plan.md` documents produced by `parallel-plan` or `plan-workflow`.

## Expected Source Structure

A single file at `docs/plans/[feature-name]/parallel-plan.md` containing:

| Section                           | What to Extract                                      |
| --------------------------------- | ---------------------------------------------------- |
| Opening paragraph (3-4 sentences) | Feature name, technical summary for all issue bodies |
| `## Critically Relevant Files`    | Mandatory reading context for every child issue      |
| `### Phase N: [Name]`             | Phase becomes a tracking issue                       |
| `#### Task N.M: [Title]`          | Each task becomes a child issue                      |
| Task > `Depends on [...]`         | Dependency notation for issue cross-references       |
| Task > `READ THESE BEFORE TASK`   | Mandatory reading section in child issue             |
| Task > `Files to Create/Modify`   | Scope section in child issue                         |
| Task > Instructions               | Implementation guidance in child issue               |
| `## Advice`                       | Appended as context to all tracking issues           |

## Step 1: Extract Plan Context

Read the opening paragraph to determine:

- **Feature name** (from the document title or first heading)
- **Technical summary** (the 3-4 sentence overview)

Read `## Critically Relevant Files and Documentation` to build a global context block. This list is referenced in every child issue under "Mandatory Reading" as supplementary context.

## Step 2: Extract Phase Structure

For each `### Phase N: [Name]` heading, extract:

- **Phase number** (N)
- **Phase name** (the heading text after the colon)
- **Phase description** (if present, the paragraph after the heading)

## Step 3: Extract Tasks per Phase

For each `#### Task N.M: [Title]` under a phase, extract:

### Title and Dependencies

- **Task ID**: "N.M" (e.g., "1.1", "2.3")
- **Task title**: The heading text between the colon and `Depends on`
- **Dependencies**: Parse `Depends on [none]` or `Depends on [1.1, 2.3]` appended to the end of the heading line itself (e.g., `#### Task 1.6: lib/ipc.ts callCommand adapter Depends on [1.1, 1.4]`)

### Mandatory Reading

Extract the `**READ THESE BEFORE TASK**` list. Each item is a file path -- include these verbatim in the issue body. Prepend the global "Critically Relevant Files" list.

### Scope

Extract from the Instructions subsection:

- **Files to Create**: Bulleted list of new files
- **Files to Modify**: Bulleted list of existing files to change

All paths should be relative to the project root.

### Implementation Guidance

Extract the numbered instruction steps from the Instructions subsection. Preserve the step-by-step format for agentic consumption.

### Gotchas

Extract any warnings, caveats, or "be careful" notes from the task instructions.

## Step 4: Extract Advice

Read the `## Advice` section at the end of the plan. This contains cross-cutting insights, gotchas, and implementation strategy notes. Append relevant advice items to tracking issues.

## Issue Mapping

| Source Element             | Issue Type                    | Template            |
| -------------------------- | ----------------------------- | ------------------- |
| Each `### Phase N: [Name]` | 1 tracking issue              | `tracking-issue.md` |
| Each `#### Task N.M`       | 1 child issue under its phase | `task-issue.md`     |

## Dependency Cross-References

After creating all child issues and capturing their issue numbers, update dependency info:

1. Build a map: `Task N.M -> Issue #XX`
2. For each child issue with dependencies, note in the issue body:

   ```
   ## Dependencies
   - Depends on #42 (Task 1.1: Set up data models)
   - Depends on #43 (Task 1.2: Configure auth)
   ```

3. For tracking issues, include a dependency summary showing which tasks in the phase can start independently vs which are blocked.

If issue numbers are not yet known at body composition time, use placeholder text: `Depends on Task N.M (issue number TBD -- update after creation)`. Then update after all issues are created if the tool supports editing, or note the cross-references in the tracking issue.

## Priority Classification

| Signal                     | Priority Label    |
| -------------------------- | ----------------- |
| Phase 1 tasks (all)        | `priority:high`   |
| Phase 2 tasks              | `priority:medium` |
| Phase 3+ tasks             | `priority:low`    |
| Tasks with no dependencies | Bump one level up |

## Source-Specific Labels

All issues from this source type receive:

- `source:parallel-plan`
- Child task issues: `type:task`
- Phase labels: `phase:{N}`
