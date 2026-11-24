# Feature Issue Template

Use this template for individual feature/deliverable issues created from research output.

## Template

```markdown
## Summary

{feature_summary}

## User Story

{user_story}

## Acceptance Criteria

{acceptance_criteria}

## Technical Details

- **Complexity**: {complexity}
- **Dependencies**: {dependencies}
- **Confidence**: {confidence_level} ({confidence_detail})

## Research Context

> Extracted from: {source_document}
> Research date: {research_date}

{additional_context}
```

## Field Descriptions

| Field               | Source                                        | Example                                     |
| ------------------- | --------------------------------------------- | ------------------------------------------- |
| feature_summary     | Synthesized from feature description          | "Implement encrypted credential storage..." |
| user_story          | Strategic recommendations feature table       | "As a network engineer, I can store..."     |
| acceptance_criteria | Strategic recommendations acceptance criteria | Numbered list                               |
| complexity          | Strategic recommendations complexity          | "Large", "Medium", "Small"                  |
| dependencies        | Strategic recommendations dependencies        | "Multi-tenant data model, auth system"      |
| confidence_level    | Convergence analysis confidence               | "High", "Medium-High", "Medium"             |
| confidence_detail   | Personas supporting                           | "8/8 personas", "5/8 personas"              |
| source_document     | File the feature was extracted from           | "synthesis/strategic-recommendations.md"    |
| research_date       | RESEARCH-REPORT.md date field                 | "2026-03-09"                                |
| additional_context  | Relevant notes from other research docs       | Architecture notes, risk notes              |

## Label Assignment Rules

### Priority Labels (from confidence)

| Confidence                               | Label                           |
| ---------------------------------------- | ------------------------------- |
| High (7-8 personas or explicitly "High") | `priority:high`                 |
| Medium-High (5-6 personas)               | `priority:medium`               |
| Medium or lower                          | `priority:low` + `under-review` |

### Feature Labels

Format: `feat:{feature-name-kebab-case}`

Examples:

- `feat:multi-tenant-data-model`
- `feat:credential-vault`
- `feat:snmp-discovery`
- `feat:topology-visualization`

### Status Labels

| Condition                               | Label                          |
| --------------------------------------- | ------------------------------ |
| Anti-scope item (explicitly deferred)   | `under-review`, `deferred`     |
| Research gap (needs more investigation) | `under-review`, `research-gap` |
| Low/medium confidence                   | `under-review`                 |
| High confidence, in-scope               | (no extra status label)        |

### Phase Labels

All feature issues also receive `phase:{N}` matching their tracking issue.

## Issue for Anti-Scope Items

Anti-scope items use a simplified template:

```markdown
## Summary

{anti_scope_description}

## Why Deferred

{reason_for_deferral}

## When to Revisit

{when_to_build}

## Research Context

> Extracted from: {source_document} (Anti-Scope)
> Research date: {research_date}
```

## Issue for Research Gaps

Research gap items use a simplified template:

```markdown
## Summary

{gap_description}

## Gap Severity

{severity}

## What Was Missed

{what_was_missed}

## What Needs Further Research

{research_needed}

## Research Context

> Extracted from: {source_document} (Research Gaps)
> Research date: {research_date}
```
