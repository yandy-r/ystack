# Parallel Mode Template Additions

When `--parallel` is enabled, augment the base plan template with these changes.

## 1. Add `Batches` section after `Metadata`

```markdown
## Batches

Tasks grouped by dependency for parallel execution. Tasks within the same batch run concurrently; batches run in order.

| Batch | Tasks         | Depends On | Parallel Width |
| ----- | ------------- | ---------- | -------------- |
| B1    | 1.1, 1.2, 1.3 | —          | 3              |
| B2    | 2.1           | B1         | 1              |
| B3    | 3.1, 3.2      | B2         | 2              |

- **Total tasks**: [N]
- **Total batches**: [M]
- **Max parallel width**: [X]
```

## 2. Use hierarchical task IDs with `Depends on` annotations

```markdown
### Task 1.1: [Name] — Depends on [none]

- **BATCH**: B1
- **ACTION**: [What to do]
- **IMPLEMENT**: [Specific code/logic]
- **MIRROR**: [Pattern reference from Patterns to Mirror]
- **IMPORTS**: [Required imports]
- **GOTCHA**: [Known pitfall]
- **VALIDATE**: [How to verify this task]

### Task 2.1: [Name] — Depends on [1.1, 1.2]

- **BATCH**: B2
- **ACTION**: ...
```

## 3. Batch Construction Rules

- Tasks with no dependencies go in **Batch 1**
- A task joins the **earliest batch** where all its dependencies are already in prior batches
- **Tasks modifying the same file MUST be in different batches** (no concurrent writes)
- Cross-cutting changes (shared types, global config) go in **Batch 1**
- Prefer **wide-shallow** graphs over **narrow-deep** chains

## 4. Safety Checks Before Finalizing

- [ ] Every task has exactly one `BATCH` assignment
- [ ] Every `Depends on` reference points to a real prior task
- [ ] No two tasks in the same batch touch the same file
- [ ] The dependency graph has no cycles
- [ ] The `Batches` table matches the task assignments exactly
