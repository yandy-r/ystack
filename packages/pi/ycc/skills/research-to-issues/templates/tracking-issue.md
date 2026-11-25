# Tracking Issue Template

Use this template for phase-level, batch-level, or cluster-level tracking issues that group related child issues.

## Template

```markdown
## Overview

{phase_description}

{metadata_block}

## Features / Deliverables

{checkbox_list}

## Success Criteria

{success_criteria}

{optional_sections}

{linear_refs_line}

## Notes

- This is a tracking issue. Individual items are linked above.
- Check off items as their linked issues are completed.
```

## Metadata Block

Include available metadata fields. Omit fields that are not present in the source document.

```markdown
**Duration**: {duration}
**Team**: {team_size}
**Risk Level**: {risk_level}
**Prerequisites**: {prerequisites}
```

| Field         | When Present                                         | Example                 |
| ------------- | ---------------------------------------------------- | ----------------------- |
| duration      | deep-research (implementation roadmap), feature-spec | "3-4 weeks"             |
| team_size     | deep-research (implementation roadmap)               | "1-2 developers"        |
| risk_level    | deep-research (implementation roadmap), feature-spec | "Low", "Medium", "High" |
| prerequisites | deep-research, parallel-plan (phase dependencies)    | "Phase 0 complete"      |

For parallel-plan and prp-plan sources, the metadata block may instead contain:

```markdown
**Dependencies**: {dependency_summary}
**Tasks in scope**: {task_count}
```

## Optional Sections

Include these sections when data is available from the source document:

### Dependencies (parallel-plan, prp-plan)

```markdown
## Dependencies

{dependency_info}
```

List which phases/batches must complete before this one. Reference child issue numbers when known.

### Out of Scope (prp-plan, feature-spec)

```markdown
## Out of Scope

{not_building_items}
```

Items explicitly excluded from this scope, extracted from "NOT Building" or anti-scope sections.

### Advice / Context (parallel-plan)

```markdown
## Implementation Advice

{advice_items}
```

Cross-cutting insights and gotchas from the plan's Advice section.

### Risk Context (feature-spec, prp-plan)

```markdown
## Risks

{risk_items}
```

Relevant risks with likelihood, impact, and mitigation strategies.

### Testing Strategy (prp-plan)

```markdown
## Testing Strategy

{testing_approach}
```

Testing approach and validation commands from the plan.

## Field Descriptions

| Field              | Source                                            | Example                               |
| ------------------ | ------------------------------------------------- | ------------------------------------- |
| phase_description  | Phase objective from source document              | "Establish project infrastructure..." |
| checkbox_list      | Generated from child issues after creation        | "- [ ] #12 Set up data models"        |
| success_criteria   | Success criteria, acceptance criteria from source | Bulleted list of criteria             |
| dependency_summary | Phase/batch dependencies from plan                | "Requires Phase 1 complete"           |
| linear_refs_line   | `Refs <linear.issue>` (linear sources)            | "Refs YAN-1152"                       |

## Label Assignment

Tracking issues receive:

- `tracking` -- identifies this as a parent tracking issue
- `phase:{N}` -- for phase-based groupings (deep-research, feature-spec, parallel-plan)
- `batch:{N}` -- for batch-based groupings (prp-plan parallel mode)
- `priority:high` -- tracking issues are always high priority
- Source provenance label (`source:deep-research`, `source:feature-spec`, etc.)
