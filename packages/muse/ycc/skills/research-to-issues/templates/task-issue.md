# Task Issue Template

Use this template for implementation task issues created from parallel-plan or PRP plan output. Task issues are implementation-focused with explicit scope, mandatory reading, and validation criteria to support agentic engineering workflows.

## Template

```markdown
## Task Summary

{task_summary}

## Mandatory Reading

> Read these files before starting this task:

{mandatory_reading_list}

## Scope

**Files to Create:**
{files_to_create}

**Files to Modify:**
{files_to_modify}

## Implementation Guidance

{implementation_instructions}

## Patterns to Follow

{pattern_references}

## Gotchas

{gotchas_warnings}

## Acceptance Criteria

{validation_criteria}

## Dependencies

{dependency_info}

## Source Context

> Extracted from: {source_document}
> Task: {task_id} of {total_tasks}
> Phase/Batch: {phase_or_batch}

{linear_refs_line}
```

## Field Descriptions

| Field                       | Source (parallel-plan)                        | Source (prp-plan)                           |
| --------------------------- | --------------------------------------------- | ------------------------------------------- |
| task_summary                | Task title + first paragraph of Instructions  | ACTION field content                        |
| mandatory_reading_list      | "READ THESE BEFORE TASK" file list            | Mandatory Reading table (P0/P1/P2 items)    |
| files_to_create             | "Files to Create" list from Instructions      | Files to Change table (CREATE rows)         |
| files_to_modify             | "Files to Modify" list from Instructions      | Files to Change table (UPDATE rows)         |
| implementation_instructions | Full Instructions section content             | IMPLEMENT field content                     |
| pattern_references          | Critically Relevant Files (pattern examples)  | MIRROR field + Patterns to Mirror section   |
| gotchas_warnings            | Advice section (relevant items)               | GOTCHA field content                        |
| validation_criteria         | Inferred from task scope and success criteria | VALIDATE field content                      |
| dependency_info             | "Depends on [N.M, ...]" notation              | Task ordering or Batches dependency info    |
| source_document             | Path to parallel-plan.md                      | Path to plan.md                             |
| task_id                     | "Task N.M" identifier                         | "Task N" identifier                         |
| total_tasks                 | Total task count across all phases            | Total task count                            |
| phase_or_batch              | "Phase N: {name}"                             | "Batch N" (parallel) or sequential position |
| linear_refs_line            | `Refs <KEY>` from frontmatter `tasks` map     | Same                                        |

## Field Adaptation

Not all fields will be present in every source. Adapt:

- If no "Patterns to Follow" data exists, omit the section entirely
- If no "Gotchas" data exists, omit the section
- If no explicit dependencies, write "None -- this task can start independently"
- If mandatory reading is empty, write "No mandatory prereading identified. Review the source document for full context."
- For files lists, use relative paths from project root
- Omit `{linear_refs_line}` for local sources and for tasks absent from the `tasks` map

## Label Assignment Rules

### Type Label

All task issues receive `type:task`.

### Phase/Batch Labels

- parallel-plan tasks: `phase:{N}` matching their phase number
- prp-plan tasks (parallel mode): `batch:{N}` matching their batch number
- prp-plan tasks (sequential mode): no phase/batch label

### Priority Labels

| Signal                                         | Label             |
| ---------------------------------------------- | ----------------- |
| Phase 1 / Batch 1 / first 2 tasks (sequential) | `priority:high`   |
| Middle phases / batches / tasks                | `priority:medium` |
| Final phase / batch / last tasks               | `priority:low`    |

### Source Labels

- parallel-plan tasks: `source:parallel-plan`
- prp-plan tasks: `source:prp-plan`
