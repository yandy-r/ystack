# PRP Agent-Team Dry-Run Output

C.2: if `DRY_RUN=true`, print:

```
Team name:    prpi-<sanitized-plan-basename>
Total tasks:  <N>  (across <M> batches, max parallel width <X>)
Dependencies: <K edges>  (from plan's `Depends on` annotations)

Batch 1: <comma-separated task IDs>
Batch 2: <comma-separated task IDs>  (depends on Batch 1)
...
Batch M: <comma-separated task IDs>  (depends on Batch M-1)

Per-batch teammate roster:
  Batch 1:
    - <task-id-1>  subagent_type=ycc:implementor  task=<short>
    - <task-id-2>  subagent_type=ycc:implementor  task=<short>
  ...
```

Do **not** call any team/task/agent tools. Exit the skill.
Linear mode: a dry run follows the artifact-store.md Implementation skills `--dry-run` rule: no `--ensure`, no cache write, no Linear writes. It may run Lookup and read an existing cache file.
