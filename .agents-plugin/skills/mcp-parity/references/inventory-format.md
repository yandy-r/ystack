# Inventory, manifest, and issue map formats

## Contents

- Inventory
- Capability ids
- Coverage merge
- Fingerprint
- Manifest
- Issue map
- Meta

`capability_diff.py` reads and writes these files. All are JSON in `$WORKDIR`.

## Inventory

`inventory.json` is what the app can do now:

```json
{
  "schema": 1,
  "capabilities": [
    {
      "id": "users.list",
      "kind": "tool",
      "operation": "GET /v1/users",
      "summary": "List users with filters and pagination.",
      "area": "users",
      "inputs": { "query": { "role": "string?", "cursor": "string?", "limit": "integer?" } },
      "outputs": "Page<User>",
      "mutating": false,
      "destructive": false,
      "auth": "user",
      "surface": "rest",
      "source": "src/routes/users.ts:42",
      "mcpCovered": false
    }
  ]
}
```

Required: `id`, `kind` (`tool`, `resource`, or `prompt`), a non-empty `operation`, and
boolean `mutating` and `destructive`. Everything else is strongly recommended because it drives milestone, priority, and
the issue body.

| Field         | Meaning                                                                                       |
| ------------- | --------------------------------------------------------------------------------------------- |
| `operation`   | The app's own handle: `METHOD /path`, `Query.users`, `rpc UserService.List`, `cli users list` |
| `inputs`      | Normalized parameter shape: names, types, optional marker `?`. Sort keys.                     |
| `outputs`     | Return type name or shape.                                                                    |
| `mutating`    | Changes state.                                                                                |
| `destructive` | Deletes data, irreversible, or affects billing/security.                                      |
| `auth`        | `public`, `user`, `admin`, `service`, or the app's own scope name.                            |
| `surface`     | `rest`, `graphql`, `grpc`, `trpc`, `cli`, `sdk`, `webhook`, `job`.                            |
| `area`        | Resource or domain group, used for labels and grouping.                                       |
| `mcpCovered`  | An MCP tool/resource already exposes it with matching inputs.                                 |

**Kind choice.** Read-only lookups of a stable, addressable entity (a document, a
config, a file) may be a `resource`. Anything with filters, side effects, or
computation is a `tool`. Reusable user-facing workflows the app documents may be a
`prompt`. When unsure, use `tool`.

**Exclude:** health checks, metrics endpoints, auth handshake routes (login, token
refresh, OAuth callbacks), static asset routes, internal admin debug routes, and
webhooks the app receives (they are inputs, not capabilities). List exclusions in the
researcher report so the user can see them.

## Capability ids

Pattern `^[a-z0-9][a-z0-9._-]{0,127}$`, unique. Use `<area>.<verb>` with these verbs:
`list`, `get`, `search`, `create`, `update`, `delete`, or the domain verb (`invoice.send`,
`order.refund`). Nested resources use dots: `projects.members.add`. Ids must not encode
the HTTP method or version so a route move keeps the id.

## Coverage merge

Save researcher 2's `covered` array as `$WORKDIR/covered.json`, then let the script
match operations (method case, `{id}`/`:id`/`<id>` path parameters, and trailing
slashes are normalized):

```bash
python3 "${HOME}/.agents/skills/mcp-parity/scripts/capability_diff.py" cover \
  --inventory "$WORKDIR/inventory.raw.json" --covered "$WORKDIR/covered.json" \
  > "$WORKDIR/inventory.json"
```

A match sets `mcpCovered` to `inputsMatch`; everything else gets `false`. The output's
`mcpOnly` list holds MCP tools with no app capability: list them in the summary as
"MCP-only, review".

## Fingerprint

The 16-hex SHA-256 over the normalized contract: `kind`, `operation`, `inputs`,
`outputs`, `mutating`, `destructive`, and `auth`. Normalization collapses
whitespace, sorts keys, and defaults missing `inputs` to `{}`, `outputs` to `""`,
and `auth` to `unspecified`. A fingerprint change means the MCP contract
must change. `summary`, `area`, `source`, `surface`, and `mcpCovered` never change a
fingerprint, so line moves and doc edits do not create churn. Normalize `inputs` the
same way every run (same type spelling) or the diff reports noise; on sync runs,
researcher 1 receives each stored `contract` to copy its spellings.

## Manifest

Stored in the Project's manifest Document as the first fenced `json` block after the
`## Manifest data` heading (a visible heading, because tracker markdown may drop HTML
comments). `capability_diff.py apply --format markdown` renders the whole
Document body.

```json
{
  "schema": 1,
  "project": "acme-api · MCP parity",
  "repo": "acme/acme-api",
  "commit": "1a2b3c4",
  "generatedAt": "2026-11-09T12:00:00Z",
  "foundation": { "scaffold": "ABC-10", "transport": "ABC-11" },
  "capabilities": {
    "users.list": {
      "area": "users",
      "contract": {
        "kind": "tool",
        "operation": "GET /v1/users",
        "inputs": {},
        "outputs": "Page<User>",
        "mutating": false,
        "destructive": false,
        "auth": "user"
      },
      "fingerprint": "3f1c0d9a7b2e4c11",
      "history": ["ABC-3"],
      "issue": "ABC-12",
      "milestone": "M2 Read parity",
      "operation": "GET /v1/users",
      "priority": 2,
      "status": "planned"
    }
  }
}
```

`status`: `planned` (issue open), `done` (issue completed), `covered` (exposed before
this skill tracked it, no issue), `removed` (capability gone from the app), `declined` (a person canceled the issue;
the skill does not recreate it).

## Issue map

`issues.json` records this run's results, keyed by capability id. Allowed fields:
`issue`, `milestone`, `priority`, `status`, `applied`. Unknown ids or fields fail.
`status` may also be `unlinked` (the issue was deleted or archived).

```json
{
  "users.list": { "issue": "ABC-12", "milestone": "M2 Read parity", "priority": 2 },
  "users.update": { "applied": true },
  "users.get": { "status": "done" },
  "legacy.export": { "issue": "ABC-30" },
  "_foundation": { "scaffold": "ABC-10", "parity-guardrail": "ABC-15" }
}
```

- `issue`: a create succeeded. A replaced key moves to the entry's `history`.
- `"applied": true`: a non-create action succeeded (patch, cancel, covered re-check,
  declined acknowledgement). Changed contracts and removals commit to the manifest
  only with `issue` or `applied`; anything else is retried on the next run.
- `status`: a State refresh result. It never commits a contract change.

Write each entry immediately after its Linear call succeeds.

## Meta

`meta.json`: `{"project": "...", "repo": "...", "commit": "...", "generatedAt": "<ISO-8601 UTC>"}`.
