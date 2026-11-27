# Label Taxonomy

## Contents

- `type:` — Change category
- `area:` — Subsystem (stubs — customise per project)
- `priority:` — Urgency
- `status:` — Workflow state
- Standalone labels
- Applying the Taxonomy

Suggested GitHub label families. Prune per-project to what's actually relevant.

---

## `type:` — Change category

| Label            | Purpose                                     |
| ---------------- | ------------------------------------------- |
| `type:bug`       | Something is broken                         |
| `type:feature`   | New capability requested                    |
| `type:docs`      | Documentation improvement                   |
| `type:refactor`  | Code restructuring without behaviour change |
| `type:perf`      | Performance improvement                     |
| `type:test`      | Test coverage or test infrastructure        |
| `type:build`     | Build system, toolchain, dependencies       |
| `type:ci`        | CI/CD pipeline changes                      |
| `type:chore`     | Housekeeping, maintenance                   |
| `type:migration` | Data or API migration                       |
| `type:security`  | Security fix or hardening                   |

---

## `area:` — Subsystem (stubs — customise per project)

| Label           | Purpose                        |
| --------------- | ------------------------------ |
| `area:build`    | Build pipeline or tooling      |
| `area:ui`       | User interface / frontend      |
| `area:cli`      | Command-line interface         |
| `area:api`      | Public or internal API surface |
| `area:database` | Data layer / migrations        |
| `area:infra`    | Infrastructure / deployment    |

Replace or extend with subsystems relevant to the project.

---

## `priority:` — Urgency

| Label               | Meaning                              |
| ------------------- | ------------------------------------ |
| `priority:critical` | Blocks a release or causes data loss |
| `priority:high`     | Should land in the next iteration    |
| `priority:medium`   | Normal queue                         |
| `priority:low`      | Nice to have; revisit later          |

---

## `status:` — Workflow state

| Label                 | Meaning                                    |
| --------------------- | ------------------------------------------ |
| `status:needs-triage` | Received; not yet reviewed                 |
| `status:in-progress`  | Actively being worked on                   |
| `status:blocked`      | Waiting on external dependency or decision |
| `status:needs-info`   | Needs more information from the reporter   |

---

## Standalone labels

| Label              | Purpose                                          |
| ------------------ | ------------------------------------------------ |
| `good first issue` | Suitable for newcomers                           |
| `help wanted`      | Extra hands welcome                              |
| `duplicate`        | Duplicate of another open issue or PR            |
| `wontfix`          | Intentionally not addressed                      |
| `regression`       | Feature that previously worked and is now broken |

---

## Applying the Taxonomy

Copy-pasteable `gh label create` block. Adjust hex colours to your palette.

```sh
# type:
gh label create "type:bug"        --color "d73a4a" --description "Something is broken"
gh label create "type:feature"    --color "0075ca" --description "New capability"
gh label create "type:docs"       --color "0052cc" --description "Documentation"
gh label create "type:refactor"   --color "e4e669" --description "Code restructuring"
gh label create "type:security"   --color "ee0701" --description "Security fix"

# priority:
gh label create "priority:critical" --color "b60205" --description "Blocks release"
gh label create "priority:high"     --color "e11d48" --description "Next iteration"
gh label create "priority:medium"   --color "f97316" --description "Normal queue"
gh label create "priority:low"      --color "fbbf24" --description "Nice to have"

# status:
gh label create "status:needs-triage" --color "ededed" --description "Not yet reviewed"
gh label create "status:in-progress"  --color "0e8a16" --description "Actively worked on"
gh label create "status:blocked"      --color "d93f0b" --description "Waiting on dependency"
gh label create "status:needs-info"   --color "d4c5f9" --description "Needs more info"

# standalone:
gh label create "good first issue" --color "7057ff" --description "Good for newcomers"
gh label create "help wanted"      --color "008672" --description "Extra attention needed"
```

> These are suggestions. Generated `labels.md` under `--templates` lists one-liner
> commands tailored to the detected project. Remove any labels your project won't use.

---
