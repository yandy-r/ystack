# Planner Prompts and Output Shape

## Contents

- Sequential prompt (`PARALLEL_MODE=false` — default)
- Parallel prompt (`PARALLEL_MODE=true`)

Use the Agent tool with `subagent_type: "planner"`. In the prompt, include:

- The user's original request (verbatim)
- Any file paths or context they referenced
- A note that the agent should follow its Plan Format and end with `**WAITING FOR CONFIRMATION**: Proceed with this plan? (yes / no / modify)`
- **If `PARALLEL_MODE=true`**: append the parallel output directives (see below)

### Sequential prompt (`PARALLEL_MODE=false` — default)

```
The user asked: "<user's request>"

Related context they pointed to: <files, URLs, or "none">

Produce a full implementation plan following your Plan Format. Use the
Read/Grep/Glob tools to analyze the codebase and include concrete file
paths. End with your standard confirmation prompt.
```

### Parallel prompt (`PARALLEL_MODE=true`)

Append these directives to the sequential prompt:

```
PARALLEL OUTPUT MODE:

In addition to your standard Plan Format, shape the output for parallel
execution:

1. **Use hierarchical step IDs** — Number steps as `1.1`, `1.2`, `2.1`,
   `2.2`, etc. where the first digit is the batch and the second is the
   task within the batch.

2. **Populate the Dependencies field on every step** — Use the hierarchical
   IDs (e.g., `Depends on [1.1, 1.2]` or `Depends on [none]`). Never leave
   the field as "None / Requires step X" — always use the explicit format.

3. **Add a `## Batches` section immediately after `## Architecture Changes`
   and before `## Implementation Steps`**. Format:

   ## Batches

   Steps grouped by dependency for parallel execution. Steps within the
   same batch run concurrently; batches run in order.

   | Batch | Steps         | Depends On | Parallel Width |
   | ----- | ------------- | ---------- | -------------- |
   | B1    | 1.1, 1.2, 1.3 | —          | 3              |
   | B2    | 2.1           | B1         | 1              |
   | B3    | 3.1, 3.2      | B2         | 2              |

   - **Total steps**: N
   - **Total batches**: M
   - **Max parallel width**: X

4. Batch construction follows standalone-dispatch section 9; append its planner batch directives when parallel output is requested.

5. Still end with `**WAITING FOR CONFIRMATION**: Proceed with this plan? (yes / no / modify)`
```

When WORKTREE_MODE=true, append standalone-dispatch section 8's planner annotation directive; omit it for --no-worktree.
