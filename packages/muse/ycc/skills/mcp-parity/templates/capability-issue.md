# Capability issue body

Fill `{…}`. Drop a section only when it has nothing true to say. Keep the Agent notes
lines exactly: lookup and rebuild parse them.

```markdown
Expose `{operation}` as an MCP {kind} so agents can {summary, lowercase verb phrase}.

## Contract

- Operation: `{operation}` ({surface})
- MCP name: `{suggested tool/resource name, snake_case, e.g. users_list}`
- Inputs: {normalized inputs, one bullet per parameter with type and optional marker}
- Output: {outputs}
- Auth: {auth} — {how the MCP caller's identity maps to the app's check}
- Side effects: {none | mutating | destructive: what is changed or lost}

## Done when

- [ ] The {kind} calls the same code path as `{operation}`; no duplicated business logic.
- [ ] Input schema matches the contract above, with descriptions agents can follow.
- [ ] Annotations set: read-only `{true|false}`, destructive `{true|false}`, idempotent `{true|false}`.
- [ ] App errors and pagination map to MCP results per the foundation conventions.
- [ ] A contract test covers success, validation error, and unauthorized access.
- [ ] The parity check passes with this capability mapped.

+++ Agent notes

Issue-Kind: {capability | update | removal}
Capability-ID: {id}
Fingerprint: {fingerprint}
Source: {source file:line}
Area: {area}
Related existing MCP code: {path or none}
Depends on: foundation issues for scaffold, auth, errors-pagination.

+++
```
