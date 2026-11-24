# Linear lookup and sync

## Contents

- Tools
- Names and markers
- Lookup
- Rebuild
- State refresh
- Write order
- Added and revived
- Changed
- Removed
- Status update
- Idempotency checks

## Tools

Linear MCP tool names differ by runtime (`mcp__linear__…`, `mcp__claude_ai_Linear__…`).
Use whichever is connected. Typical tools: `list_projects`, `get_project`,
`save_project`, `list_milestones`, `save_milestone`, `list_issues`, `get_issue`,
`save_issue`, `save_comment`, `list_documents`, `get_document`, `save_document`,
`list_issue_labels`, `create_issue_label`, `list_issue_statuses`,
`save_status_update`. Read each tool's schema before the first call. Paginate every
list call until `hasNextPage` is false. When a needed operation has no tool (for
example relations), report it in the summary instead of guessing.

## Names and markers

- Project: `{REPO_NAME} · MCP parity`. Its description's first line is
  `Repository: {REPO_SLUG}`, which Lookup checks.
- Manifest Document, attached to the Project: `{REPO_NAME} · mcp-parity-manifest`.
- Issue titles: `MCP {kind}: {id}` (capability), `Update MCP {kind}: {id}` (contract
  change after completion), `Remove MCP {kind}: {id}` (removal), and the foundation
  titles in `milestones-priority.md`.
- Every issue's Agent notes block has these lines, each on its own line:
  `Issue-Kind: capability|update|removal|foundation`, then `Capability-ID: {id}` and
  `Fingerprint: {fingerprint}`, or `Foundation-Key: {key}` for foundation issues.

Match marker lines exactly: the whole line, after trimming, equals
`Capability-ID: {id}`. A substring match confuses `users.get` with
`users.get.by-email`.

Linear rewrites some markdown on save, so never compare stored bodies byte for
byte:

- A `+++ Agent notes` collapsible comes back as `>>> Agent notes`; marker lines stay
  intact on their own lines.
- Issue keys in Document tables come back as `<issue … label="KEY" />` mentions. Only
  the fenced `json` block under `## Manifest data` is authoritative, and it
  round-trips unchanged.
- `list_issues` `query` search is fuzzy: it returns near matches (`note.create` for
  `note.update`). Always read each hit's description and apply the exact-line rule.

## Lookup

Stop at the first hit:

1. `--project REF`: fetch it. Missing → stop with the error.
2. Projects named exactly `{REPO_NAME} · MCP parity` or `{REPO_SLUG} · MCP parity`;
   in `ARTIFACT_LINEAR_TEAM` when set, otherwise in all teams. Keep only Projects
   whose description's `Repository:` line equals `REPO_SLUG` (case-insensitive).
3. List the team's Projects (all pages) and read each description's `Repository:`
   line; also Projects carrying `ARTIFACT_LINEAR_LABEL` that hold issues labeled
   `mcp-parity`. This finds renamed Projects.

Several hits → ask (class `clarify`). No hit → create mode. Name a new Project
`{REPO_NAME} · MCP parity`, or `{REPO_SLUG} · MCP parity` when a Project for another
repo already has the short name.

A manifest `repo` that differs from `REPO_SLUG` makes `diff` fail. When the user
confirms the repo was renamed or transferred, rerun `diff` and `apply` with
`--adopt-repo` and update the Project's `Repository:` line.

In sync mode, find the manifest Document by exact title in the Project. Save its
body as `$WORKDIR/manifest.md` and run
`capability_diff.py extract --doc "$WORKDIR/manifest.md"`. On success that file is
`MANIFEST_FILE`. A missing Document or a failed extract → Rebuild, and report why.

Linear team for create mode: `--owner-team`, else `ARTIFACT_LINEAR_TEAM`, else the sole team from
`list_teams`; several teams → ask.

## Rebuild

When the Project exists but the manifest is missing or unreadable:

1. List all of the Project's issues labeled `mcp-parity`, in every state.
2. For `Issue-Kind: capability` and `update`, take `Capability-ID` and `Fingerprint`.
   Map state type: completed → `done`; canceled → `declined`; otherwise `planned`.
   When an id has several issues, prefer the open one, then the newest.
3. A `removal` issue marks its id `removed`.
4. Collect `Foundation-Key` lines into `foundation`.
5. Write `$WORKDIR/manifest.json` (schema in `inventory-format.md`, with `repo` set to
   `REPO_SLUG`). Fingerprints without a stored `contract` are fine: a different
   fingerprint reports `changed`, which only patches open issues. That file is
   `MANIFEST_FILE`. Report "manifest rebuilt from N issues".

## State refresh

Sync runs only, before the diff. For each manifest capability with an `issue` and
status `planned`, `done`, or `declined`, read the issue (`get_issue`):

- not found, deleted, or archived → record `{"status": "unlinked"}`. The key is
  forgotten (kept in `history`) and the capability is planned as new.
- completed → record `{"status": "done"}` unless already `done`.
- canceled, and its Agent notes say `Issue-Kind: capability` or `update` → record
  `{"status": "declined"}`. A person canceled it; this skill never recreates it.
- any open state → record `{"status": "planned"}` when the manifest says `done` or
  `declined` (someone reopened it).

Pass `--issues "$WORKDIR/issues.json"` to `diff` so these statuses shape the
classification: each diff item's `status` is the effective one. Status entries never
commit contract changes; only `issue` and `"applied": true` do.

## Write order

1. Labels (`milestones-priority.md` > Labels).
2. Project (create mode): `save_project` with name, team, description (first line
   `Repository: {REPO_SLUG}`, then purpose and "Managed by the mcp-parity skill. Edit
   issues freely; keep the Agent notes marker lines."), and labels. Set
   `meta.json` `project`.
3. Milestones: `list_milestones`, then `save_milestone` for missing names only.
4. Foundation issues, then Added and revived, Changed, Removed.
5. Relations (`milestones-priority.md` > Foundation issues). Before adding one,
   check that it does not already exist.
6. Manifest Document, then the Project status update.

Run the matching Idempotency check before every create.

## Added and revived

`save_issue` with team, project, milestone, title, priority, labels, and the body
from `templates/capability-issue.md`. Revived issues add a `relatedTo` link to the
previous issue. Record `{"issue": KEY, "milestone": …, "priority": …}`.

## Changed

The diff item gives `issue`, `oldContract`, and `newContract`; branch on the
effective status. Summarize the field-level differences between the two contracts (when
`oldContract` is missing after a rebuild, read the issue's Contract section). Then:

- **status `covered`** (no issue): the existing MCP tool still matches (a mismatch
  would have cleared `mcpCovered` and made it `added`). Record `{"applied": true}`.
- **status `declined`**: record `{"applied": true}`; nothing in Linear.
- **status `done`** (issue completed): the shipped MCP tool has the old contract.
  Create `Update MCP {kind}: {id}` in the original milestone, priority 3, labels
  `mcp-parity` and the kind label, `relatedTo` the original. Record the new `issue`
  and `"status": "planned"`. The old key moves to `history` automatically.
- **status `planned`** (issue open): update only the description's `## Contract`
  section and the `Fingerprint:` line (`patch` when the tool supports it; otherwise
  fetch, edit those parts, and send the whole body). Add one comment:
  `API contract changed at {COMMIT}: {summary}`. Keep title, priority, assignee,
  state, and labels. Record `{"applied": true}`.

## Removed

The diff item gives `issue`; branch on the effective status:

- **planned, issue unstarted** (backlog, unstarted, triage): comment
  `Capability no longer exists in the app at {COMMIT}`, then move it to the team's
  canceled state (the state type `canceled` named "Canceled", else the first
  `canceled` type that is not "Duplicate"). Record `{"applied": true}`.
- **planned, issue started**: someone is working on it. Leave the state and list it
  in the summary for a person to decide. Post the same comment only when
  `list_comments` shows none with that text yet. Record nothing, so the next run
  re-checks it without commenting again.
- **done**: the MCP server still exposes a dead capability. Create
  `Remove MCP {kind}: {id}`, priority 2, in `M5 Parity guardrails`, `relatedTo` the
  original. Record the new `issue`.
- **covered**: when researcher 2 shows the existing MCP server exposes it, create the
  removal issue as above. Otherwise record `{"applied": true}`.
- **declined**: record `{"applied": true}`.

## Status update

One `save_status_update` on the Project per non-dry run, health `onTrack`, or
`atRisk` when any write failed:

```text
Parity sync at {COMMIT}: +{added} new, {changed} changed, {removed} removed,
{covered} covered, {declined} declined, {unchanged} unchanged. Parity {exposed}/{tracked}.
```

## Idempotency checks

- Before creating an issue, search the Project's `mcp-parity` issues in every state
  for one with the same `Issue-Kind` and an exact `Capability-ID` (or
  `Foundation-Key`) line, and a matching title prefix. An open hit → reuse it, record
  its key, and skip the create. This covers a crashed run whose manifest was never
  saved. Completed or canceled hits do not count; they are history.
- Milestones and labels are created only when no item with that exact name exists.
- The manifest Document is updated in place; create it only when Lookup found none.
- A second run with no repository changes makes zero issue creates and zero issue
  edits: only the manifest Document refresh and one status update.
