# Artifact Store — Canonical Reference

## Contents

- Status
- Kinds
- Layout
- Frontmatter
- Sync
- Store resolution
- Helper API
- Repository mapping
- Worktrees
- Gitignore
- Fresh clone
- Lookup
- Local mode
- Size and diagrams

Single source of truth for where planning artifacts live and how skills save, load, and sync them. The shell helper resolves config and paths only. Linear MCP calls live in skill bodies, never in the helper.

Shared script:

```bash
~/.agents/ycc-shared/scripts/resolve-artifact-store.sh
```

It sources `resolve-plans-dir.sh` from its own directory. Sourcing resolves from the current directory; an explicit `resolve_artifact_store <dir>` re-exports `PLANS_DIR` and `PLANS_ROOT` for that directory as well as the `ARTIFACT_*` variables.

## Status

The helper and this reference ship unwired. Nothing user-visible changes until the follow-up issues consume them.

| Piece                                       | Issue    | State            |
| ------------------------------------------- | -------- | ---------------- |
| `resolve-artifact-store.sh`                 | YAN-1153 | Shipped, unwired |
| This reference                              | YAN-1152 | Shipped, unwired |
| Planning skills and validators              | YAN-1154 | Not migrated     |
| Implementation skills and validators        | YAN-1155 | Not migrated     |
| Review and report skills                    | YAN-1156 | Not migrated     |
| Generators, capability matrix, `init`   | YAN-1157 | Not migrated     |
| Existing `docs/plans` and `docs/prps` trees | YAN-1158 | Leave in place   |

## Kinds

| Kind                           | Linear object                                                     | Cache file                      |
| ------------------------------ | ----------------------------------------------------------------- | ------------------------------- |
| prd                            | Document on the feature Project                                   | `prd.md`                        |
| feature-research spec          | Document on the feature Project                                   | `feature-spec.md`               |
| prp-spec                       | Document on the feature Project                                   | `spec.md`                       |
| research                       | One Document per lens on the feature Project                      | `research/research-<lens>.md`   |
| shared-context                 | Document on the feature Project                                   | `shared.md`                     |
| plan-workflow / parallel-plan  | Document, plus one Issue per task                                 | `parallel-plan.md`              |
| prp-plan / `plan --visual` | Document, plus one Issue per task                                 | `prp-plan.md`                   |
| review                         | One Document per review, attached to the issue or feature Project | `reviews/<review-id>-review.md` |
| report                         | Project status update, plus a Document when long                  | `report.md`                     |
| analysis                       | Local-only scratch; never pushed                                  | `analysis-*.md`                 |
| prp-plan research backstop     | Local-only scratch; never pushed                                  | `.prp-research/<role>.md`       |

Document titles are `<slug> · <kind>`. `<kind>` is the cache filename stem, omitting the conventional `research/` and `reviews/` directories: `shared` → `shared.md`, `parallel-plan` → `parallel-plan.md`, `prp-plan` → `prp-plan.md`, `feature-spec` → `feature-spec.md`, `report` → `report.md`, `research-<lens>` → `research/research-<lens>.md`, and `<pr-N|local-<stamp>|quick-<stamp>>-review` → the matching `reviews/<review-id>-review.md`. `prd` and `spec` map to their same-named files. Load maps that title suffix back to the cache filename. Each split part uses `<basename>-part-N` as its kind and filename stem.

A review keeps its PR comment unchanged. With no reviewed issue, attach its Document to the feature Project; if no Project exists, keep the review local only.

`prp-implement` `{plan}-report.md` and `code-report` `report.md` both use the report kind. Store the status-update id in `linear.statusUpdate`; a long report also has `linear.document`.

### Plan task issues

- Plan tasks are sub-issues of one parent tracking issue. Use the verified branch-hint issue as parent when present; otherwise create one in the feature Project.
- `tasks` maps the literal task heading id (`1.1`, `Task 1`) to its Linear issue id. Warn that renumbering headings remaps ids and can associate issues with different tasks.
- The plan owns only each task issue's title, description, and `blocks` relations. Relations mirror dependency batches.
- Re-save updates mapped issues, creates only new task ids, and rebuilds a missing map from existing sub-issues by literal heading id before creating anything.
- Before updating a task issue, fetch its `updatedAt`. If it differs from the `updatedAt` recorded at the last plan/task sync (the value fetched for this save when none is recorded), skip that issue and report it instead of overwriting it. The plan Document's `syncedAt` does not replace this per-issue check.
- Never change issue state except to cancel an **open** issue whose task was removed. Never cancel a Done or already-cancelled issue, and never delete an issue.

## Layout

Linear mode stores a gitignored cache:

```text
.ycc/artifacts/<feature-slug>/
├── prd.md
├── feature-spec.md
├── spec.md
├── prp-plan.md
├── parallel-plan.md
├── shared.md
├── report.md
├── analysis-*.md
├── reviews/
│   ├── pr-<N>-review.md
│   ├── local-<stamp>-review.md
│   └── quick-<stamp>-review.md
├── research/
│   ├── research-business.md
│   ├── research-technical.md
│   ├── research-ux.md
│   ├── research-security.md
│   ├── research-practices.md
│   ├── research-external.md
│   └── research-recommendations.md
└── .prp-research/
    └── <role>.md
```

`plan-workflow` and `parallel-plan` both write `parallel-plan.md`; there is no plan-workflow `plan.md`. `prp-plan` and the forced file from `plan --visual` use `prp-plan.md`. Feature-research and PRP specs remain distinct. Analysis files and PRP research backstops keep their current basenames under the slug directory but are never pushed.

| Cache file (linear)                                     | Today's path (local)                                                  |
| ------------------------------------------------------- | --------------------------------------------------------------------- |
| `.ycc/artifacts/<slug>/prd.md`                          | `docs/prps/prds/<name>.prd.md`                                        |
| `.ycc/artifacts/<slug>/feature-spec.md`                 | `docs/plans/<slug>/feature-spec.md`                                   |
| `.ycc/artifacts/<slug>/spec.md`                         | `docs/prps/specs/<name>.spec.md`                                      |
| `.ycc/artifacts/<slug>/prp-plan.md`                     | `docs/prps/plans/<name>.plan.md`                                      |
| `.ycc/artifacts/<slug>/parallel-plan.md`                | `docs/plans/<slug>/parallel-plan.md`                                  |
| `.ycc/artifacts/<slug>/shared.md`                       | `docs/plans/<slug>/shared.md`                                         |
| `.ycc/artifacts/<slug>/research/research-<lens>.md`     | `docs/plans/<slug>/research-<lens>.md`                                |
| `.ycc/artifacts/<slug>/reviews/pr-<N>-review.md`        | `docs/prps/reviews/pr-<N>-review.md`                                  |
| `.ycc/artifacts/<slug>/reviews/local-<stamp>-review.md` | `docs/prps/reviews/local-<stamp>-review.md`                           |
| `.ycc/artifacts/<slug>/reviews/quick-<stamp>-review.md` | `docs/prps/reviews/quick-<stamp>-review.md`                           |
| `.ycc/artifacts/<slug>/report.md`                       | `docs/plans/<slug>/report.md` or `docs/prps/reports/<plan>-report.md` |
| `.ycc/artifacts/<slug>/analysis-*.md`                   | `docs/plans/<slug>/analysis-*.md`                                     |
| `.ycc/artifacts/<slug>/.prp-research/<role>.md`         | `docs/prps/plans/.prp-research/<slug>/<role>.md`                      |

### Slugs

1. Use the skill's feature name when it has one. In particular, `code-report` uses its supplied feature name.
2. For an artifact with no feature name, verify `ARTIFACT_LINEAR_HINT` when set and first look for an existing cache directory whose frontmatter `linear.project` matches that issue's Project. Reuse its slug.
3. Otherwise use lowercased `ARTIFACT_LINEAR_HINT` when set.
4. Otherwise sanitize the branch name: lowercase it, replace `/` and every character outside `[a-z0-9._-]` with `-`, collapse repeated `-`, and trim leading/trailing separators.
5. If no valid slug remains, ask the user.

`get_feature_artifact_dir` accepts only `^[A-Za-z0-9][A-Za-z0-9._-]*$` and rejects `/` and any `..` path part. This is stricter than `get_feature_plan_dir`; see Local mode for legacy names.

## Frontmatter

In linear mode, merge identity keys into existing frontmatter; do not replace other keys or add a `ycc:` namespace. Local mode writes no identity frontmatter.

| Field                 | Meaning                                                                                                |
| --------------------- | ------------------------------------------------------------------------------------------------------ |
| `linear.workspace`    | Linear workspace slug                                                                                  |
| `linear.team`         | Team key, for example `YAN`                                                                            |
| `linear.project`      | Feature Project id or slug                                                                             |
| `linear.document`     | Document id, empty when there is no Document                                                           |
| `linear.issue`        | Parent tracking issue, reviewed issue when present, otherwise empty                                    |
| `linear.statusUpdate` | Report status-update id, empty for other kinds                                                         |
| `tasks`               | Literal plan task id → Linear issue id; only on `parallel-plan.md` and `prp-plan.md`                   |
| `syncedAt`            | Linear `updatedAt` observed at the last sync, stored verbatim in its ISO-8601 form                     |
| `contentHash`         | Lowercase hex SHA-256 from the procedure below at the last successful push or pull                     |
| `pending`             | `true` when a reachable Linear configuration is temporarily unreachable; otherwise omit or set `false` |

Compare `updatedAt` with `syncedAt` using **differs from**, not chronological ordering or timestamp normalization.

```yaml
---
title: Artifact store implementation plan
linear:
  workspace: yandy-r
  team: YAN
  project: artifact-store
  document: 7b1e3c0a-0000-4000-8000-000000000000
  issue: YAN-1152
  statusUpdate:
tasks:
  '1.1': YAN-1153
  'Task 2': YAN-1154
syncedAt: '2026-10-26T00:00:00.000Z'
contentHash: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
pending: false
---
```

### Body, hash, and push bytes

1. Frontmatter exists only as a block starting with `---` at byte 0 and closed by a later `---` line. A `---` anywhere else is body content; without that opening and closing block, the whole file is body.
2. Start with the exact file bytes. Remove only the complete top-level `linear`, `syncedAt`, `contentHash`, `pending`, and `tasks` entries from that block. Do not re-serialize YAML or remove other keys.
3. Normalize CRLF and CR line endings to LF. Do not trim the result or add/remove its trailing newline; preserve every other byte, including non-identity frontmatter.
4. SHA-256 those bytes for `contentHash`. Push the same identity-stripped content to Linear: identity values are never pushed, while non-identity frontmatter remains in the pushed and hashed body. Apply the same procedure after pulls.

Validators that inspect headings or body structure must skip frontmatter; that migration is part of YAN-1154/YAN-1155.

## Sync

Skills run these procedures; the helper never calls Linear.

### Linear call gate

- Before any local write in linear mode, ensure a Linear MCP is installed and authorized. If not, stop and suggest `store: local`; do not create a cache, `.gitignore`, or perpetual pending file.
- Before any Linear call, confirm the connected workspace equals `ARTIFACT_LINEAR_WORKSPACE` when set. On mismatch, ask the user before proceeding.
- Only temporary unreachability of an installed, authorized MCP follows Offline.

### Save

1. Resolve the store and check `${ARTIFACT_STORE:-}`.
2. In linear mode, apply the Linear call gate, then call `ensure_artifact_dir` and read any cached identity. If the cache file is absent, run Lookup steps 3–6 to find an existing object before creating one; reuse its Document, status update, parent, and task issues rather than duplicating them.
3. Write the new body. Local mode writes today's path without identity frontmatter and **stops here**. Linear mode preserves existing identity frontmatter, including `tasks`, and all non-identity keys; only the body is replaced.
4. Before updating an existing object, fetch its `updatedAt`. If it differs from `syncedAt`, run Conflict and do not push until answered. A discovered existing object with no prior `syncedAt` also requires Conflict before its body is replaced.
5. Create or update the object using the Kinds and naming rules. For plans, apply the task-issue rules above. On creation, record all returned ids.
6. After a successful push, stamp `syncedAt` verbatim from the response, recompute `contentHash`, update `tasks` and `linear.statusUpdate` as applicable, and clear `pending`.

If the MCP fails during step 4 or 5, keep the local file and follow Offline.

### Load

1. An explicit path, URL, or id selects that object; otherwise run Lookup.
2. If the local file is missing, pull it, write the cache file, and stamp identity frontmatter.
3. If it exists, compute its current body hash and read `syncedAt`.
4. If Linear `updatedAt` differs from `syncedAt` and the current hash equals `contentHash` with no pending edit, pull; Linear wins because the cache is clean.
5. If Linear differs and the local hash differs from `contentHash` or `pending` is true, run Conflict; both sides changed.
6. If Linear matches `syncedAt`, keep the local file. When `pending` is true or its hash differs from `contentHash`, run Save from step 4 to push it.

### Conflict

1. Ask the user to keep local, take Linear, or show a diff. After showing a diff, ask again until the user chooses keep or take.
2. Keep local: push immediately against the acknowledged remote state, then stamp `syncedAt` and `contentHash` from the successful push. Do not prompt again for the same remote change.
3. Take Linear: replace the body, then stamp `syncedAt` and `contentHash` from the successful pull.
4. Never silently discard either side.

### Offline

1. For temporary MCP unreachability, warn once and continue locally.
2. Keep the local body and set `pending: true`.
3. On the next Load or Save that reaches Linear, push through the normal remote checks and clear `pending` after success.
4. If the remote also differs, run Conflict; never push or pull over the other side silently.

## Store resolution

`resolve_artifact_store` exports variables without writing files. First hit wins; accepted values are only `linear` and `local`.

1. `--store=` argument → `ARTIFACT_STORE_SOURCE=flag`.
2. Nearest in-scope `.plans-config` defining `store:` → `config`.
3. `${XDG_CONFIG_HOME:-$HOME/.config}/ycc/config`, key `store:` → `global`.
4. Default `linear` → `default`.

An invalid value at the selected level does not fall through. An explicit resolve prints an error and returns 1; sourced auto-resolution prints `WARNING`, unsets every `ARTIFACT_*` variable, and does not fail the caller.

The `store` and `linear_*` walks compare physical paths (`pwd -P`) and stop after the start directory's physical Git toplevel, or physical `PLANS_ROOT` without Git. Symlinked paths therefore cannot escape the boundary. The original start directory still goes to `resolve_plans_dir`, whose upward/topmost `PLANS_*` behavior is unchanged.

Each hint inherits independently from the nearest in-scope `.plans-config` defining that key. Unset keys export as empty strings. The global file is consulted only for `store:`.

| Config key         | Exported variable           |
| ------------------ | --------------------------- |
| `linear_workspace` | `ARTIFACT_LINEAR_WORKSPACE` |
| `linear_team`      | `ARTIFACT_LINEAR_TEAM`      |
| `linear_project`   | `ARTIFACT_LINEAR_PROJECT`   |
| `linear_label`     | `ARTIFACT_LINEAR_LABEL`     |

In linear mode, `ARTIFACT_ROOT` is `PLANS_ROOT` unless `PLANS_ROOT` lies outside the start directory's Git toplevel; then it is that Git toplevel, keeping a nested worktree's cache in the worktree. In local mode, `ARTIFACT_ROOT` is `PLANS_ROOT` and `ARTIFACT_DIR` is `$PLANS_DIR`. In linear mode, `ARTIFACT_DIR` is `${ARTIFACT_ROOT}/.ycc/artifacts`.

### Branch hint

`ARTIFACT_LINEAR_HINT` comes from `git -C <start-dir> branch --show-current`; it is empty for detached HEAD or no Git checkout. Skills verify the hint in Linear before using it.

- With a team, match only `<TEAM>-<digits>` case-insensitively. After uppercasing, the team must match `^[A-Z0-9]+$`; otherwise return an empty hint.
- Without a team, use prefix `[A-Za-z][A-Za-z0-9]{1,9}` with the same rules.
- The key must begin at the branch start or after `/`, `_`, or `-`, and end at `-`, `_`, `/`, or end of string.
- Use the first match and export it uppercased. `yramirez/yan-1152-foo` and `feat/YAN-1152-x` both yield `YAN-1152`.

## Helper API

| Variable                    | Value                                                                                                              |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `ARTIFACT_STORE`            | `linear` or `local`                                                                                                |
| `ARTIFACT_STORE_SOURCE`     | `flag`, `config`, `global`, or `default`                                                                           |
| `ARTIFACT_ROOT`             | Linear: `PLANS_ROOT`, or the start directory's Git toplevel when `PLANS_ROOT` lies outside it. Local: `PLANS_ROOT` |
| `ARTIFACT_DIR`              | Linear: `${ARTIFACT_ROOT}/.ycc/artifacts`. Local: `$PLANS_DIR`                                                     |
| `ARTIFACT_LINEAR_WORKSPACE` | `linear_workspace`, or empty                                                                                       |
| `ARTIFACT_LINEAR_TEAM`      | `linear_team`, or empty                                                                                            |
| `ARTIFACT_LINEAR_PROJECT`   | `linear_project`, or empty                                                                                         |
| `ARTIFACT_LINEAR_LABEL`     | `linear_label`, or empty                                                                                           |
| `ARTIFACT_LINEAR_HINT`      | Branch issue-key hint, or empty; skills must verify it in Linear                                                   |

| Function                                                     | Behavior                                                                                                                   |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| `resolve_artifact_store [--store=linear\|local] [start-dir]` | Export all variables and re-export `PLANS_DIR`/`PLANS_ROOT` for the start directory. No writes. Return 1 on invalid input. |
| `get_feature_artifact_dir <slug>`                            | Print `${ARTIFACT_DIR}/<slug>` after the slug validation above. Do not create it.                                          |
| `ensure_artifact_gitignore`                                  | Linear: ensure the repository gitignore rule. Local: return 0 without writing.                                             |
| `ensure_artifact_dir`                                        | Create `ARTIFACT_DIR`, then run `ensure_artifact_gitignore`; the write-on-first-save entry point.                          |

Executed form; default output is `ARTIFACT_DIR` only:

```bash
bash "${HOME}/.agents/ycc-shared/scripts/resolve-artifact-store.sh" [--store=linear|local] [--debug] [--shell] [start-dir]
```

- `--shell` prints every `ARTIFACT_*` variable using Bash `printf %q`; evaluate it in Bash, not a POSIX shell.
- `--help` prints usage. `--debug` or `PLANS_DEBUG=1` enables debug output.
- Sourcing auto-resolves without `exit` or enabling `set -e`; check `${ARTIFACT_STORE:-}` before use. Call `resolve_artifact_store` explicitly to pass a flag/start directory or receive invalid-input status.

```bash
# shellcheck source=/dev/null
source "${HOME}/.agents/ycc-shared/scripts/resolve-artifact-store.sh"
```

## Repository mapping

Default: one Linear Project per feature, named exactly `<slug>`, inside `ARTIFACT_LINEAR_TEAM`, with `ARTIFACT_LINEAR_LABEL` applied. Reuse a matching Project or create it on first save.

Alternative: set `linear_project` to a fixed Project id/slug for repos using one Project with milestones. Lookup step 5 then uses that Project instead of label discovery.

A plan's parent tracking issue is the verified hint issue when present; otherwise create one in the feature Project. The helper only supplies hints; skills perform all verification and creation.

## Worktrees

- Linear mode does not move plan files between worktrees. A worktree pulls from Linear instead of following the committed-docs move in `worktree-strategy.md`; local mode retains that existing behavior. Pushing from the main checkout does not refresh another worktree's clean cache: Load's differing-`updatedAt` rule pulls the new remote body there.
- Push every pending artifact before removing a worktree. Unpushed pending files block routine cleanup.
- Lookup step 2 checks both the current worktree cache and the main checkout cache, so per-worktree roots do not hide existing work.

## Gitignore

Ignore `.ycc/artifacts/` only, never all of `.ycc/`; a committed pointer may live there later.

In linear mode, both `ensure_*` functions refuse when `ARTIFACT_ROOT` is outside a Git work tree. They also refuse symlinked `${ARTIFACT_ROOT}/.gitignore`, `${ARTIFACT_ROOT}/.ycc`, or `ARTIFACT_DIR` rather than writing through them. Local mode creates only the plans directory and never edits Git metadata.

The linear gitignore check returns without editing when either condition holds:

- `git check-ignore -v --no-index` ignores `.ycc/artifacts/probe` and the reported source is a `.gitignore` inside this repository. Global excludes and `.git/info/exclude` do not count.
- `${ARTIFACT_ROOT}/.gitignore` already contains `.ycc/artifacts/`, `/.ycc/artifacts/`, `.ycc/artifacts`, or `/.ycc/artifacts`.

Otherwise append `.ycc/artifacts/`, creating `.gitignore` if needed and adding a missing trailing newline before the entry. Skills call `ensure_artifact_dir` on first save; `init` handles setup up front (YAN-1157).

## Fresh clone

A fresh clone finds Linear from committed `.plans-config`. Only the `store`/`linear_*` lookup is bounded to the repository; `resolve-plans-dir.sh` retains its existing unbounded upward/topmost config behavior for `PLANS_*`.

```text
plans_dir: docs/plans
store: linear
linear_workspace: yandy-r
linear_team: YAN
linear_label: repo:ystack
```

A fixed-Project repo uses `linear_project: <id-or-slug>` instead of `linear_label`. No `scope: local` is needed: a nested worktree uses its own Git toplevel for the linear cache even when a higher config determines `PLANS_ROOT`.

`AGENTS.md` and `AGENTS.md` carry this line (owned by `init`, YAN-1157):

```text
Planning artifacts live in Linear (see `.plans-config`); `.ycc/artifacts/` is a gitignored local cache. If it's missing, pull from Linear.
```

A user-level store override uses the same key format:

```text
# ${XDG_CONFIG_HOME:-$HOME/.config}/ycc/config
store: local
```

## Lookup

In linear mode, stop at the first hit:

1. Explicit path, URL, or Linear id argument.
2. Current cache `.ycc/artifacts/<slug>/`, then the main checkout cache. Find the main root as the parent of `git rev-parse --git-common-dir` and check the same relative artifact path there.
3. `ARTIFACT_LINEAR_HINT`: verify the issue in Linear, then open its Project, Documents, and any report status update.
4. Open PR for the current branch (`gh pr view --json body` or GitHub MCP). Parse `(Closes|Fixes|Resolves) <TEAM>-<n>`, verify the issue in Linear, then open its Project and artifacts. Match keywords and keys case-insensitively. Without a configured team, accept the generic key prefix `[A-Za-z][A-Za-z0-9]{1,9}`.
5. `ARTIFACT_LINEAR_PROJECT` when set; otherwise Projects in `ARTIFACT_LINEAR_TEAM` carrying `ARTIFACT_LINEAR_LABEL`, filtered by slug.
6. Linear Document search by slug and title (`<slug> · <kind>`), plus the Project's report status updates.
7. Ask the user for a path, URL, or id, listing everything tried and any step skipped for missing configuration.

Never conclude "no plan" without querying Linear and asking the user. If Linear is unreachable, say the lookup is unverified and ask; never report not-found. Local mode uses today's local discovery only and makes no Linear calls.

## Local mode

`store: local` preserves today's paths and filenames, adds no identity frontmatter, and makes no Linear calls. Save stops after step 3 and Lookup uses today's local discovery only.

- `ARTIFACT_ROOT=PLANS_ROOT`, `ARTIFACT_DIR=PLANS_DIR`, and `get_feature_artifact_dir <slug>` prints `${PLANS_DIR}/<slug>`.
- Existing `docs/prps/` files stay there rather than moving under `docs/plans/`.
- `ensure_artifact_gitignore` is a no-op; `ensure_artifact_dir` only creates `ARTIFACT_DIR`.
- The new slug helper is stricter than `get_feature_plan_dir`. Existing names it rejects keep their existing paths rather than being silently renamed.

## Size and diagrams

- Keep Mermaid in fenced code blocks; Linear renders Mermaid.
- Split a document over about 100 KB into `<basename>-part-N.md`. Each part is its own Linear Document with its own title and identity frontmatter. When content shrinks, delete stale local part files and their Linear Documents.
- Visual-plan writes `plan.mdx` (and any additional visual surfaces) under `.ycc/artifacts/<slug>/visual/` in linear mode. These files stay local-only and are not uploaded; visual-plan does not edit the source plan to reference them. Local mode keeps the existing `<plan-dir>/visual/` behavior.

Migration of existing `docs/plans` and `docs/prps` trees is YAN-1158. Leave them in place.
