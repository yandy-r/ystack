# Milestones, priority, and labels

## Contents

- Milestones
- Milestone assignment
- Priority
- Labels
- Foundation issues

## Milestones

Every parity Project has the same five milestones, created once and reused by name.
Never rename or delete them; on sync, create only the missing ones.

| Milestone                | Holds                                                                    |
| ------------------------ | ------------------------------------------------------------------------ |
| `M1 Foundation`          | Server scaffold, transport, auth, error/pagination mapping, test harness |
| `M2 Read parity`         | Non-mutating tools and all resources                                     |
| `M3 Write parity`        | Mutating, non-destructive tools                                          |
| `M4 Destructive & admin` | Destructive tools, `admin`/`service` auth tools, prompts                 |
| `M5 Parity guardrails`   | CI parity check, docs, release and distribution                          |

Milestone descriptions: one sentence from the table plus "Managed by ycc:mcp-parity."
Do not set target dates; people own scheduling.

## Milestone assignment

Apply the first matching rule:

1. Foundation work → `M1 Foundation`; guardrails, docs, release → `M5 Parity guardrails`.
2. `destructive: true`, or `auth` is `admin` or `service`, or `kind: prompt` →
   `M4 Destructive & admin`.
3. `mutating: true` → `M3 Write parity`.
4. Everything else → `M2 Read parity`.

A capability found on a sync run uses the same rules, even when its milestone's
other issues are done. Parity is the goal, not the milestone date.

## Priority

Linear priority values: 1 Urgent, 2 High, 3 Medium, 4 Low.

| Work                                                                       | Priority |
| -------------------------------------------------------------------------- | -------- |
| Server scaffold, transport, auth                                           | 1 Urgent |
| Error/pagination mapping, test harness, parity guardrail                   | 2 High   |
| Read tools/resources on the app's core entities                            | 2 High   |
| Write tools on core entities; changed-contract updates for done issues     | 3 Medium |
| Other read and write tools                                                 | 3 Medium |
| Destructive and admin tools, prompts, docs, release                        | 4 Low    |
| Removal of an MCP tool whose capability is gone (live tool lies to agents) | 2 High   |

**Core entities** are the 3-5 areas with the most capabilities, or the ones the
README and API docs lead with. Name them in the plan output so the user can disagree.
Set priority only on create. On sync, never change the priority of an existing issue.

## Labels

Ensure these team issue labels exist (create missing ones; never rename or delete):

- `mcp-parity`: on every issue this skill creates. Lookup uses it.
- `mcp:tool`, `mcp:resource`, `mcp:prompt`: the capability kind.
- `mcp:foundation`: foundation and guardrail issues.
- `ARTIFACT_LINEAR_LABEL` (for example `repo:acme-api`) when set; also apply it to
  the Project.

Pass labels by name. Use `addLabels` when editing an existing issue so labels people
added survive.

## Foundation issues

Create the ones that apply, skipping anything the existing MCP server already
provides. Body template: `templates/foundation-issue.md`.

| Key                 | Title                                                          | Milestone | Priority |
| ------------------- | -------------------------------------------------------------- | --------- | -------- |
| `scaffold`          | Scaffold the MCP server package with the official SDK          | M1        | 1        |
| `transport`         | Support the chosen transport(s) (stdio and/or Streamable HTTP) | M1        | 1        |
| `auth`              | Authenticate MCP clients and reuse the app's authorization     | M1        | 1        |
| `errors-pagination` | Map app errors and pagination to MCP results                   | M1        | 2        |
| `test-harness`      | Add an MCP contract test harness                               | M1        | 2        |
| `parity-guardrail`  | Fail CI when an API capability has no MCP counterpart          | M5        | 2        |
| `docs-release`      | Document and ship the MCP server                               | M5        | 4        |

`scaffold` blocks `transport`, `auth`, and `test-harness`. To keep the graph
readable, `auth` and `errors-pagination` each block only the highest-priority issue
of M2, M3, and M4 (one relation per milestone), not every capability issue. The
`parity-guardrail` issue body must describe the check concretely for this repo: the
source of truth for capabilities (spec file or route registry), the MCP tool list,
and the id mapping in the manifest.
