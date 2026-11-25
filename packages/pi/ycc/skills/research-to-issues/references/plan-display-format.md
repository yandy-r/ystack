# Plan Display Format

## Contents

- Plan Header
- Labels Section (Always)
- Tracking Issues Section (Always)
- Child Issues Section (Always)
- Anti-Scope Section (deep-research, feature-spec, and prd only)
- Research Gap Section (deep-research only)
- Dependency Graph Section (parallel-plan and prp-plan only)
- Decision Issues Section (feature-spec and prd only)
- Footer (Always)

Display this plan before creating any issues. Adapt sections based on source type.

## Plan Header

```markdown
# {source_type_label} -> Issues Plan

**Source**: {source_path}
**Project**: {project_name}
**Source type**: {detected_type}
**Date**: {date_if_available}
```

Source type labels:

| Detected Type | Label         |
| ------------- | ------------- |
| deep-research | Deep Research |
| feature-spec  | Feature Spec  |
| parallel-plan | Parallel Plan |
| prp-plan      | PRP Plan      |
| prd           | PRD           |

## Labels Section (Always)

```markdown
## Labels to Create

{list of labels that don't exist yet, with colors}
```

## Tracking Issues Section (Always)

```markdown
## Tracking Issues ({count})

### {tracking_title_1}

- Labels: {label_list}
- Child issues: {count}

### {tracking_title_2}

- Labels: {label_list}
- Child issues: {count}
```

For deep-research, feature-spec, and prd, include "Deferred / Under Review" and "Research Gaps" tracking sections if applicable.

## Child Issues Section (Always)

For deep-research, feature-spec, and prd sources:

```markdown
## Feature Issues ({total count})

| #   | Title                   | Phase | Labels                       | Priority |
| --- | ----------------------- | ----- | ---------------------------- | -------- |
| 1   | Multi-Tenant Data Model | 0-1   | feat:multi-tenant-data-model | high     |
```

For parallel-plan and prp-plan sources:

```markdown
## Task Issues ({total count})

| #   | Title              | Phase/Batch | Dependencies | Files    | Priority |
| --- | ------------------ | ----------- | ------------ | -------- | -------- |
| 1   | Set up data models | Phase 1     | none         | 3 create | high     |
```

## Anti-Scope Section (deep-research, feature-spec, and prd only)

```markdown
## Anti-Scope Issues ({count})

| #   | Title         | Labels                 |
| --- | ------------- | ---------------------- |
| 1   | Path Analysis | under-review, deferred |
```

## Research Gap Section (deep-research only)

```markdown
## Research Gap Issues ({count})

| #   | Title            | Severity | Labels                     |
| --- | ---------------- | -------- | -------------------------- |
| 1   | Testing Strategy | High     | under-review, research-gap |
```

## Dependency Graph Section (parallel-plan and prp-plan only)

```markdown
## Dependency Graph

Phase 1 (independent):

- Task 1.1: Set up data models
- Task 1.2: Configure auth

Phase 2 (depends on Phase 1):

- Task 2.1: Build API endpoints [depends on 1.1]
- Task 2.2: Add validation [depends on 1.1, 1.2]
```

## Decision Issues Section (feature-spec and prd only)

```markdown
## Decision Issues ({count})

| #   | Title                  | Options | Labels         |
| --- | ---------------------- | ------- | -------------- |
| 1   | Auth strategy decision | 3       | needs-decision |
```

## Footer (Always)

```markdown
**Total issues to create**: {total}
```
