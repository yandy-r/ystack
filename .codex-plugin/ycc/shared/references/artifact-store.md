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
- Gitignore
- Fresh clone
- Lookup
- Local mode
- Size and diagrams

Single source of truth for where planning artifacts live and how skills save, load, and sync them. The shell helper resolves config and paths only. Linear MCP calls live in skill bodies, never in the helper.

Shared script:

```bash
../scripts/resolve-artifact-store.sh
```

It sources `resolve-plans-dir.sh` from its own directory, so `PLANS_DIR` and `PLANS_ROOT` stay exactly what that helper already exports.

## Status

The helper and this reference ship unwired. Nothing user-visible changes until the follow-up issues consume them.

| Piece                                       | Issue    | State            |
| ------------------------------------------- | -------- | ---------------- |
| `resolve-artifact-store.sh`                 | YAN-1153 | Shipped, unwired |
| This reference                              | YAN-1152 | Shipped, unwired |
| Planning skills                             | YAN-1154 | Not migrated     |
| Implementation skills                       | YAN-1155 | Not migrated     |
| Review and report skills                    | YAN-1156 | Not migrated     |
| Generators, capability matrix, `init`   | YAN-1157 | Not migrated     |
| Existing `docs/plans` and `docs/prps` trees | YAN-1158 | Leave in place   |

## Kinds

| Kind                  | Linear object                                                                       | Cache file                      |
| --------------------- | ----------------------------------------------------------------------------------- | ------------------------------- |
| prd                   | Document on the feature Project                                                     | `prd.md`                        |
| feature-research spec | Document on the feature Project                                                     | `feature-spec.md`               |
| prp-spec              | Document on the feature Project                                                     | `spec.md`                       |
| research              | Document on the feature Project, one per lens                                       | `research/research-<lens>.md`   |
| shared-context        | Document on the feature Project                                                     | `shared.md`                     |
| plan-workflow plan    | Document, plus one Issue per task                                                   | `plan.md`                       |
| prp-plan              | Document, plus one Issue per task                                                   | `prp-plan.md`                   |
| parallel-plan         | Document, plus one Issue per task                                                   | `parallel-plan.md`              |
| review                | One Document per review, attached to the issue. The PR comment stays as it is today | `reviews/<review-id>-review.md` |
| report                | Project status update, plus a Document when the body is long                        | `report.md`                     |

Plan artifacts (`plan-workflow`, `prp-plan`, and `parallel-plan`) have sub-issues of one parent tracking issue, one Issue per task. A task that must finish before another `blocks` that later task, matching the plan's dependency batches. On those files, frontmatter `issue` is the parent, `document` is the Document id, and `tasks` maps each plan task id to its Linear issue id.

On re-save, update issues already in `tasks`, create Issues only for new task ids, and add their ids to the map. Cancel (never delete) an issue whose task id was removed from the plan. Preserve the dependency relations when task issues change.

Review cache paths are `reviews/<pr-N|local-<stamp>|quick-<stamp>>-review.md`: use `reviews/pr-<N>-review.md`, `reviews/local-<stamp>-review.md`, or `reviews/quick-<stamp>-review.md` as appropriate. Each review has its own Document; never combine reviews into one shared file. On a review, `issue` is the reviewed issue when one exists and `document` is that review's Document id.

On a report, `document` is set only when a long Document was also written. A status-update-only report leaves `document` empty. The frontmatter schema has no separate status-update id.

## Layout

Linear mode stores a gitignored cache:

```text
.ycc/artifacts/<feature-slug>/
├── prd.md
├── feature-spec.md
├── spec.md
├── plan.md
├── prp-plan.md
├── parallel-plan.md
├── shared.md
├── report.md
├── reviews/
│   ├── pr-<N>-review.md
│   ├── local-<stamp>-review.md
│   └── quick-<stamp>-review.md
└── research/
    ├── research-business.md
    ├── research-technical.md
    ├── research-ux.md
    ├── research-security.md
    ├── research-practices.md
    ├── research-external.md
    └── research-recommendations.md
```

The slug is the feature name skills already use for `docs/plans/<feature-name>/`. `get_feature_artifact_dir` accepts only `^[A-Za-z0-9][A-Za-z0-9._-]*$`; it rejects `/` and any `..` path part, rather than rejecting every occurrence of two dots.

For an artifact with no feature name, including a review or report, use lowercased `ARTIFACT_LINEAR_HINT` when it is set. Otherwise use the current branch name with every `/` replaced by `-`. If neither is available, ask the user for a slug. The resulting slug must pass the same helper validation.

Cache names keep today's feature-scoped basenames where possible (`shared.md`, `parallel-plan.md`, `plan.md`, `report.md`, `research-*.md`). Distinct sources do not collide: plan-workflow uses `plan.md`, prp-plan uses `prp-plan.md`, feature-research uses `feature-spec.md`, and prp-spec uses `spec.md`. Standard research lenses are the seven `feature-research` writes. Any other `research-*.md` basename is stored under `research/` unchanged.

| Cache file (linear)                                     | Today's path (local)                        |
| ------------------------------------------------------- | ------------------------------------------- |
| `.ycc/artifacts/<slug>/prd.md`                          | `docs/prps/prds/<name>.prd.md`              |
| `.ycc/artifacts/<slug>/feature-spec.md`                 | `docs/plans/<slug>/feature-spec.md`         |
| `.ycc/artifacts/<slug>/spec.md`                         | `docs/prps/specs/<name>.spec.md`            |
| `.ycc/artifacts/<slug>/plan.md`                         | `docs/plans/<slug>/plan.md`                 |
| `.ycc/artifacts/<slug>/prp-plan.md`                     | `docs/prps/plans/<name>.plan.md`            |
| `.ycc/artifacts/<slug>/parallel-plan.md`                | `docs/plans/<slug>/parallel-plan.md`        |
| `.ycc/artifacts/<slug>/shared.md`                       | `docs/plans/<slug>/shared.md`               |
| `.ycc/artifacts/<slug>/research/research-<lens>.md`     | `docs/plans/<slug>/research-<lens>.md`      |
| `.ycc/artifacts/<slug>/reviews/pr-<N>-review.md`        | `docs/prps/reviews/pr-<N>-review.md`        |
| `.ycc/artifacts/<slug>/reviews/local-<stamp>-review.md` | `docs/prps/reviews/local-<stamp>-review.md` |
| `.ycc/artifacts/<slug>/reviews/quick-<stamp>-review.md` | `docs/prps/reviews/quick-<stamp>-review.md` |
| `.ycc/artifacts/<slug>/report.md`                       | `docs/plans/<slug>/report.md`               |

`<slug>` in the cache paths is the feature slug or the fallback slug above. `<name>`, `<N>`, and `<stamp>` are the names those skills write today.

## Frontmatter

Every cached artifact carries identity frontmatter. Values in the example show shape only.

| Field              | Meaning                                                                                                        |
| ------------------ | -------------------------------------------------------------------------------------------------------------- |
| `linear.workspace` | Linear workspace slug                                                                                          |
| `linear.team`      | Team key, for example `YAN`                                                                                    |
| `linear.project`   | Feature project id or slug                                                                                     |
| `linear.document`  | Document id, empty when the artifact has no Document                                                           |
| `linear.issue`     | Issue id. Parent tracking issue for plan artifacts; reviewed issue for review when one exists; empty otherwise |
| `tasks`            | Plan task id → Linear issue id. Present on `plan.md`, `prp-plan.md`, and `parallel-plan.md`; omitted elsewhere |
| `syncedAt`         | ISO-8601 timestamp. The Linear `updatedAt` observed at the last successful sync                                |
| `contentHash`      | Lowercase hex SHA-256 of the body at the last successful sync (push or pull)                                   |
| `pending`          | `true` when the last save could not reach Linear. Omit or `false` when the push landed                         |

The body is the file after the closing frontmatter delimiter. A file with no frontmatter is hashed whole. Stamping frontmatter does not change `contentHash`.

```yaml
---
linear:
  workspace: yandy-r
  team: YAN
  project: artifact-store
  document: 7b1e3c0a-0000-4000-8000-000000000000
  issue: YAN-1152
tasks:
  '1.1': YAN-1153
  '1.2': YAN-1154
syncedAt: '2026-10-26T00:00:00Z'
contentHash: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
pending: false
---
```

## Sync

Skills run these procedures. The helper does not call Linear.

### Save

1. Resolve the store. Sourcing the helper already calls `resolve_artifact_store` with no arguments; check `${ARTIFACT_STORE:-}` before proceeding.
2. In linear mode, call `ensure_artifact_dir` so the first save creates the cache directory and the gitignore entry.
3. Write the file. Linear mode writes the cache path from Layout. Local mode writes today's path from the same table.
4. If the Linear object already exists, fetch its `updatedAt`. When it is later than `syncedAt`, run Conflict and do not push until the user answers.
5. Push from the skill: create or update the Linear object in the Kinds table. For plan artifacts, apply the task map: update existing task issues, create only new tasks, and cancel issues for removed tasks; never delete an issue.
6. Stamp frontmatter from the push response. `syncedAt` is that object's `updatedAt`. `contentHash` is the SHA-256 of the body at this successful sync. Record new issue ids in `tasks` and clear `pending`.

### Load

1. An explicit path, URL, or id uses that object and skips Lookup.
2. Otherwise follow Lookup.
3. Local file missing: pull, write the file, stamp frontmatter from the pull.
4. Local file present: hash the body and read `syncedAt`.
5. Linear `updatedAt` is later than `syncedAt` and the local hash equals `contentHash`: pull and replace the file. Linear wins. The cache was clean.
6. Linear is newer and the local hash differs from `contentHash`: run Conflict.
7. Linear is not newer: keep the local file, including unpushed edits.

### Conflict

1. Ask the user to keep the local body, take the Linear body, or show a diff.
2. Keep local: push the local body immediately against the acknowledged remote state, then stamp `syncedAt` and `contentHash` from the successful push. Do not prompt again for the same remote change.
3. Take Linear: replace the body, then stamp `syncedAt` and `contentHash` from the successful pull.
4. Do not overwrite or drop either side before the user answers.

### Offline

1. When the Linear MCP cannot be reached, warn once.
2. Keep reading and writing the local file.
3. Set `pending: true`.
4. On the next run that reaches Linear, push a pending file whose remote object did not change, then clear `pending`.
5. When the remote object also changed, run Conflict. Do not push over it and do not pull over the pending body.

## Store resolution

`resolve_artifact_store` is pure: it exports variables and writes nothing. First hit wins. The only accepted values are `linear` and `local`. Any other value at the winning level writes an error to stderr and returns 1. The helper does not fall through to the next source.

1. `--store=` argument. `ARTIFACT_STORE_SOURCE=flag`.
2. Nearest `.plans-config`, walking up from the start directory, that defines `store:`. `ARTIFACT_STORE_SOURCE=config`. A closer file that omits `store:` does not hide a higher in-scope file that sets it.
3. `${XDG_CONFIG_HOME:-$HOME/.config}/ycc/config`, key `store:`. `ARTIFACT_STORE_SOURCE=global`.
4. Default `linear`. `ARTIFACT_STORE_SOURCE=default`.

Config lines use the same `key: value` or `key=value` parser as `resolve-plans-dir.sh`. The global file is consulted for `store:` only. The walk for `store` and every `linear_*` key stops after checking the start directory's Git toplevel, or `PLANS_ROOT` when no Git toplevel exists. Ancestor configs beyond that boundary are ignored.

Each Linear hint is read on its own, from the nearest in-scope `.plans-config` that defines that key. A closer file that sets `store:` and omits `linear_team` does not block a higher in-scope `linear_team`. Unset keys export as the empty string.

| Config key         | Exported variable           |
| ------------------ | --------------------------- |
| `linear_workspace` | `ARTIFACT_LINEAR_WORKSPACE` |
| `linear_team`      | `ARTIFACT_LINEAR_TEAM`      |
| `linear_project`   | `ARTIFACT_LINEAR_PROJECT`   |
| `linear_label`     | `ARTIFACT_LINEAR_LABEL`     |

The start directory defaults to the current working directory. In linear mode, `ARTIFACT_ROOT` is `PLANS_ROOT` unless `PLANS_ROOT` lies outside the start directory's Git toplevel. In that case (for example, a worktree nested under a checkout whose higher `.plans-config` wins), `ARTIFACT_ROOT` is the Git toplevel, keeping the cache in the current worktree. `ARTIFACT_DIR` is `${ARTIFACT_ROOT}/.ycc/artifacts` when the store is linear, and `$PLANS_DIR` when the store is local.

### Branch hint

`ARTIFACT_LINEAR_HINT` is an issue key parsed from `git -C <start-dir> branch --show-current`. It is empty when the start directory is not a git checkout or HEAD is detached. It is a hint. The skill verifies it with the Linear MCP before treating it as the feature issue.

- When `ARTIFACT_LINEAR_TEAM` is set, match only `<TEAM>-<digits>`, case-insensitively.
- The team key must start at the beginning of the branch name, or immediately after `/`, `_`, or `-`.
- The match must end at the end of the branch name, or at `-`, `_`, or `/`.
- When the team is unset, the same boundaries apply and the prefix is `[A-Za-z][A-Za-z0-9]{1,9}`.
- Use the first match. Export it uppercased.

`yramirez/yan-1152-foo` resolves to `YAN-1152`. `feat/YAN-1152-x` resolves to `YAN-1152`.

## Helper API

| Variable                    | Value                                                                                         |
| --------------------------- | --------------------------------------------------------------------------------------------- |
| `ARTIFACT_STORE`            | `linear` or `local`                                                                           |
| `ARTIFACT_STORE_SOURCE`     | `flag`, `config`, `global`, or `default`                                                      |
| `ARTIFACT_ROOT`             | Linear: `PLANS_ROOT`, or the start directory's Git toplevel when `PLANS_ROOT` lies outside it |
| `ARTIFACT_DIR`              | `${ARTIFACT_ROOT}/.ycc/artifacts` (linear) or `$PLANS_DIR` (local)                            |
| `ARTIFACT_LINEAR_WORKSPACE` | `linear_workspace`, or empty                                                                  |
| `ARTIFACT_LINEAR_TEAM`      | `linear_team`, for example `YAN`, or empty                                                    |
| `ARTIFACT_LINEAR_PROJECT`   | `linear_project`, project id or slug, or empty                                                |
| `ARTIFACT_LINEAR_LABEL`     | `linear_label`, for example `repo:ystack`, or empty                                           |
| `ARTIFACT_LINEAR_HINT`      | Issue key from the current branch, or empty                                                   |

| Function                                                     | Behavior                                                                                                                                                                                                                                                       |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `resolve_artifact_store [--store=linear\|local] [start-dir]` | Resolve and export every variable above. No filesystem writes. Returns 1 on an invalid store value.                                                                                                                                                            |
| `get_feature_artifact_dir <slug>`                            | Print `${ARTIFACT_DIR}/<slug>`. Accept only `^[A-Za-z0-9][A-Za-z0-9._-]*$`; reject `/` and any `..` path part. Do not create the directory.                                                                                                                    |
| `ensure_artifact_gitignore`                                  | Linear: idempotently ignore `.ycc/artifacts/` in `${ARTIFACT_ROOT}/.gitignore`. Local: return 0 and write nothing. Linear writes require a Git work tree.                                                                                                      |
| `ensure_artifact_dir`                                        | `mkdir -p` `ARTIFACT_DIR`, then `ensure_artifact_gitignore`. This is the write-on-first-save entry point. Linear mode refuses with an error when `ARTIFACT_ROOT` is outside a Git work tree; local mode only creates `ARTIFACT_DIR` and performs no Git write. |

Executed form. The default print is `ARTIFACT_DIR` only:

```bash
bash "../scripts/resolve-artifact-store.sh" [--store=linear|local] [--debug] [--shell] [start-dir]
```

- `--shell` prints `KEY=<shell-quoted value>` for every exported `ARTIFACT_*` variable using Bash `printf %q`. Evaluate the output in Bash; it is not POSIX-shell syntax.
- `--help` prints usage.
- `--debug` and `PLANS_DEBUG=1` turn on debug output, the same switch `resolve-plans-dir.sh` uses.

Sourcing runs resolution with no arguments. It does not `exit` the caller and does not enable `set -e`. An invalid store never fails the sourcing caller: the helper prints a warning and leaves every `ARTIFACT_*` variable unset. Callers must check `${ARTIFACT_STORE:-}` and may call `resolve_artifact_store` explicitly; the explicit call returns 1 on an invalid store. The caller is otherwise left with the options `resolve-plans-dir.sh` already applies (`set -uo pipefail`):

```bash
# shellcheck source=/dev/null
source "../scripts/resolve-artifact-store.sh"
```

Call `resolve_artifact_store --store=local "$start"` after sourcing when the skill must pass a flag or a start directory.

## Repository mapping

Default: one Linear project per feature. Find it inside `ARTIFACT_LINEAR_TEAM` by the repo label `ARTIFACT_LINEAR_LABEL` (for example `repo:ystack` on team `YAN`).

Alternative: set `linear_project` to a fixed project id or slug when the repo keeps one project and uses milestones for features. Lookup step 5 then opens that project and does not search by label.

## Gitignore

Ignore `.ycc/artifacts/` only. Do not ignore `.ycc/` itself. A committed pointer may live there later.

In linear mode, both `ensure_*` functions refuse with an error when `ARTIFACT_ROOT` is outside a Git work tree; they never create a cache or `.gitignore` outside a repository. `ensure_artifact_gitignore` returns 0 without writing in local mode, while `ensure_artifact_dir` creates the local plans directory without touching Git. In linear mode the gitignore check also returns without editing when either check is already true:

- `git check-ignore` reports `.ycc/artifacts/probe` as ignored, and the reported source is a `.gitignore` inside this repository. A global excludes file or `.git/info/exclude` does not count, because teammates will not have it; use `git check-ignore -v --no-index` and verify its source, or
- `${ARTIFACT_ROOT}/.gitignore` already contains `.ycc/artifacts/`, `/.ycc/artifacts/`, `.ycc/artifacts`, or `/.ycc/artifacts`.

Otherwise append `.ycc/artifacts/`. Create `${ARTIFACT_ROOT}/.gitignore` when it is missing. When the file exists and does not end in a newline, write that newline before the new line.

Skills call `ensure_artifact_dir` on the first save. `init` writes the ignore entry up front (YAN-1157).

## Fresh clone

A fresh clone finds Linear from the committed `.plans-config`. The plans resolver already walks up to it, bounded as described in Store resolution. Example for this repo (no `scope: local` is needed):

```text
plans_dir: docs/plans
store: linear
linear_workspace: yandy-r
linear_team: YAN
linear_label: repo:ystack
```

A repo that pins one project uses `linear_project: <id-or-slug>` instead of `linear_label`. A worktree resolves its cache to its own Git toplevel under the ARTIFACT_ROOT rule above; it does not inherit a main checkout's cache merely because a higher `.plans-config` supplies `PLANS_ROOT`.

`AGENTS.md` and `AGENTS.md` carry this line:

```text
Planning artifacts live in Linear (see `.plans-config`); `.ycc/artifacts/` is a gitignored local cache. If it's missing, pull from Linear.
```

`init` owns adding that line and the gitignore entry (YAN-1157). Those files are unchanged in this change.

A user-level store override uses the same key format and is read only for `store:`:

```text
# ${XDG_CONFIG_HOME:-$HOME/.config}/ycc/config
store: local
```

## Lookup

In linear mode, follow this order and stop at the first hit:

1. Explicit path, URL, or Linear id argument. Use it and stop.
2. Local cache: `.ycc/artifacts/<slug>/` and the filename from Layout.
3. `ARTIFACT_LINEAR_HINT` from the branch. Verify that issue with the Linear MCP, then open its project and documents.
4. Open PR for the current branch (`gh pr view --json body` or the GitHub MCP). Parse `(Closes|Fixes|Resolves) <TEAM>-<n>` from the body, verify that issue in Linear, then open its project and documents.
5. `ARTIFACT_LINEAR_PROJECT` when set. Otherwise, open projects in `ARTIFACT_LINEAR_TEAM` that carry `ARTIFACT_LINEAR_LABEL`, filtered by the slug.
6. Linear document search by slug and by title.
7. Ask the user for a path, URL, or id, listing everything tried and any step skipped because its key was empty.

Steps 3 and 4 do not trust a parsed issue key alone; the skill confirms the issue through Linear. Never conclude "no plan" without querying Linear and then asking the user. If Linear is unreachable, say the lookup is unverified and ask the user; never report not-found.

Local mode skips this lookup and makes no Linear calls. See Local mode.

## Local mode

`store: local` is today's `docs/*` behavior, byte for byte.

- `ARTIFACT_DIR` equals `PLANS_DIR`.
- `get_feature_artifact_dir <slug>` prints `${PLANS_DIR}/<slug>` (`docs/plans/<slug>/` with the default plans dir).
- Files that today live under `docs/prps/` stay on those paths. The function does not move them under `docs/plans/`.
- Filenames stay on the "Today's path" column of the layout table, including `feature-spec.md` and `pr-<N>-review.md`.
- Skills do not call Linear.
- `ensure_artifact_gitignore` returns 0 without writing.
- `ensure_artifact_dir` only creates `ARTIFACT_DIR` with `mkdir -p`.

## Size and diagrams

- Keep Mermaid diagrams in fenced code blocks. Linear renders Mermaid.
- Split a document over about 100 KB into `<basename>-part-N.md` in the same directory (`prd-part-1.md`, `prd-part-2.md`). Under that size, keep the unsuffixed name from Layout.
- Visual-plan HTML stays on disk. It is the `visual/` sibling of the plan file (see `visual-mode.md`) and the plan references it by name. It is not uploaded.

Migration of the existing `docs/plans` and `docs/prps` trees is YAN-1158. Leave those files where they are.
