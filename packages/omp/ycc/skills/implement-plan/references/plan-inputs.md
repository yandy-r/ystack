# Parallel Plan Inputs

## Contents

- Usage block
- Task parser output
- Dependency graph
- Task list format
- Monorepo Support

## Usage block

Print when no input remains after stripping flags:

```
Usage: /implement-plan [--team] [--dry-run] [--worktree] [--no-worktree] [--store=local|linear] <feature-name | plan-path | Linear-reference>

Examples:
  /implement-plan user-authentication
    # default: create/reuse one feature worktree on feat/user-authentication

  /implement-plan --team user-authentication
    # agent-team dispatch (worktree still on by default)

  /implement-plan --dry-run payment-integration
  /implement-plan --team --dry-run payment-integration

  /implement-plan --no-worktree my-feature
    # opt out of worktree isolation; create/use feat/my-feature in the current checkout

  /implement-plan --team --no-worktree my-feature
    # agent-team dispatch on the current-checkout feature branch

  /implement-plan --store=local user-authentication
    # explicit local mode; existing paths and no Linear calls

  /implement-plan --store=linear user-authentication
  /implement-plan YAN-123
  /implement-plan https://linear.app/workspace/issue/YAN-123/feature
  /implement-plan https://linear.app/workspace/project/feature-slug
  /implement-plan --store=linear feature-project-slug
  /implement-plan https://linear.app/workspace/document/plan-document-id
  /implement-plan --store=linear <document-id>
  /implement-plan .ycc/artifacts/user-authentication/parallel-plan.md
    # issue, Project, Document, or cached plan; hydrate before prerequisites
```

### Store and input resolution

Read `skill://ycc-shared/references/artifact-store.md` **Implementation skills > Inputs**, **Resolve and hydrate**, and **Store resolution**; Inputs defines what counts as an issue key, a Linear reference and a linear plan path, and that an existing local `${PLANS_DIR}/<name>/` wins over reference parsing. Strip `--store=local|linear` into `STORE_FLAG` and forward it on every resolver call. A Linear reference or linear plan path sets `STORE_FLAG=--store=linear`; combined with explicit `--store=local`, abort with: `A Linear plan reference requires linear mode; drop --store=local.` Anything else (including feature names such as `oauth-2`) follows normal store resolution; default local behavior is unchanged. A bare Project slug or Document id is a reference only with `--store=linear`; it is resolved through Lookup, not guessed from a missing local file.

Resolve and print the mode, then in linear mode apply the Linear call gate and Lookup → Load for `parallel-plan` and available `shared`; use their absolute cache paths. Derive the feature slug from the selected Document/Project using the canonical contract. A missing `shared` Document warns; it does not block a plan. Rebuild a missing task map in memory from existing sub-issues; untracked tasks still run. Never create task issues during implementation. A dry run follows the contract's `--dry-run` rule (no `--ensure`, no cache write, no Linear writes). An explicit local plan path uses its absolute path and companion `shared.md`, retaining local behavior.

## Task parser output

`parse-dependencies.sh` emits optional header lines followed by per-task rows.

Header lines (only when the plan has a `## Worktree Setup` section):

- `WT_PARENT_PATH=<path>` — parent worktree path
- `WT_FEATURE_SLUG=<slug>` — the `<repo>-<feature>` directory suffix; split on `-` to get the feature component

Per-task rows (`TASK_ID|TASK_TITLE|DEPENDENCIES`):

- **Task ID**: e.g., 1.1, 2.3, 3.1 (or T0, T1, T2)
- **Task Title**: descriptive name
- **Dependencies**: list from `Depends on [...]` or `- **Dependencies**: ...`
- **Files to Read**: from "READ THESE BEFORE TASK" (parsed from the plan markdown directly)
- **Files to Create**: from "Files to Create"
- **Files to Modify**: from "Files to Modify"
- **Instructions**: implementation details

## Dependency graph

```
Independent Tasks (Depends on [none]):
  - Task 1.1
  - Task 1.3
  - Task 2.2

Dependent Tasks:
  - Task 1.2 → depends on [1.1]
  - Task 2.1 → depends on [1.1, 1.2]
  - Task 2.3 → depends on [2.1, 2.2]
  - Task 3.1 → depends on [2.1]
```

Keep this graph available for both Path A (ordering) and Path B (`addBlockedBy` wiring).

## Task list format

Register one item per task with `todo`:

- `subject`: "[Task ID] [Task Title]"
- `description`: full task specification, including dependency labels
- Capture each returned task ID (do not assign your own tool ID).
- Wire dependencies with `todo(taskId="<returned-id>", addBlockedBy=["<dependency-id>"])`.
- Set status via `todo`; inspect progress with `todo`.

```
todo: subject="1.1 Create user model", description="<full spec>; depends on none"
todo: subject="1.2 Add validation", description="<full spec>; depends on 1.1"
todo: taskId="<1.2 returned ID>", addBlockedBy=["<1.1 returned ID>"]
```

## Monorepo Support

In local mode, the skill detects and uses the correct plans directory in monorepo setups. Linear mode resolves `parallel-plan` and `shared` under `.ycc/artifacts/<slug>/` in the invoking checkout, independent of a package's local `docs/plans/`; see artifact-store.md **Worktrees**. The examples below retain local-mode behavior.

Default behavior:

- Plans are read from the git repository root in `docs/plans/`.
- Running the skill from any subdirectory (e.g., `packages/app1/`) still reads plans from the root.

Configuration — create a `.plans-config` file:

Repository root (centralized plans):

```yaml
# .plans-config at repo root
plans_dir: docs/plans
```

Package-level plans (optional):

```yaml
# .plans-config in packages/app1/
plans_dir: docs/plans
scope: local
```

With `scope: local`, plans are read from the local `docs/plans/` instead of the root.

Example monorepo structure:

```
monorepo/
  .plans-config          # plans_dir: docs/plans
  docs/plans/            # Centralized plans (default)
    feature-a/
      shared.md
      parallel-plan.md   # Read by this skill
  packages/
    app1/
    app2/
```

Running `/implement-plan feature-a` from anywhere executes `monorepo/docs/plans/feature-a/parallel-plan.md`.
