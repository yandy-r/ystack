# Research agents

## Contents

- Shared rules
- 1. Surface inventory
- 2. Architecture and existing MCP
- 3. MCP practice
- Large repositories

Dispatch these with the `Agent` tool in one message so they run in parallel. Use the
Claude agent types shown; on runtimes without them, use the closest read-only
researcher. Each prompt below is a template: fill the `{…}` values.

## Shared rules

Put these lines in every prompt:

```text
You are read-only. Do not edit files, run builds, or call any tracker or Linear tool.
Inventory root: {ROOT}. Ignore generated bundles, vendored code, build output, and
test fixtures unless they are the only definition of a capability.
Return your result in the exact format requested; the parent parses it.
If something is ambiguous, return the options and your recommendation; do not ask.
```

## 1. Surface inventory

Agent type: `codebase-research-analyst`.

```text
Goal: list every capability a client can invoke in this app, so an MCP server can
mirror it one-to-one.

Surface hints from a scanner (verify, do not trust):
{surface.tsv}

{On sync runs:} Existing capability ids and stored contracts from the last run.
Reuse an id when it is the same capability, even if it moved or was renamed, and
copy the stored spelling of unchanged inputs/outputs so fingerprints stay stable:
{id → contract list}

{When a spec-first inventory exists:} A deterministic inventory was generated from
{spec path}: {N} operations, ids {id list}. Do not re-list them. Verify a sample
against the code, then return only capabilities the spec misses (CLI commands,
GraphQL/RPC surfaces, undocumented routes) and spec ids that are not real client
capabilities (internal, dead, or feature-flagged off), with reasons.

Steps:
1. Prefer contracts: OpenAPI, GraphQL schema, proto files, tRPC routers. Read code
   only where no contract exists or the contract is stale versus the code.
2. Read route registration, controllers, resolvers, RPC services, and CLI command
   definitions. Follow mounted routers and prefixes to full paths.
3. For each capability, record the fields in the inventory schema below, including
   normalized inputs (sorted keys, `?` for optional), outputs, mutating,
   destructive, and auth.
4. Apply the exclusion list. Report what you excluded and why.

Inventory schema and id rules: {paste inventory-format.md > Inventory and Capability ids}

Return:
- A JSON block: {"schema": 1, "capabilities": [...]}
- A short list of exclusions.
- Open questions (ambiguous ownership, dead routes, feature-flagged routes).
```

## 2. Architecture and existing MCP

Agent type: `code-explorer`.

```text
Goal: tell the planner how an MCP server fits this repository.

Answer with evidence (file:line):
1. Language, framework, runtime, package manager, and test framework.
2. Is there an MCP server already (SDK imports, .mcp.json, server.json)? If yes:
   which tools/resources/prompts it exposes, each mapped to the app operation it
   calls, and whether its inputs match that operation.
3. How the app authenticates callers (sessions, API keys, OAuth, service tokens)
   and how authorization is checked. Which layer should an MCP server call: the HTTP
   API, an internal service layer, or an SDK/client package?
4. Error model (error types, status codes) and pagination model.
5. Where a server should live: new package, existing service, or separate repo
   folder, following repo conventions.
6. How CI runs tests, for the parity guardrail.

Return:
- A JSON block: {"covered": [{"operation": "...", "mcpName": "...", "inputsMatch": true}]}
  where `operation` uses the same handle format as the inventory (`GET /v1/users`).
- A short architecture brief covering 1-6.
```

## 3. MCP practice

Agent type: `research-specialist` (web access), or `library-docs-writer`
when context7 is available.

```text
Goal: current, sourced guidance for building an MCP server in {LANGUAGE}/{FRAMEWORK}.

Find, with links and dates:
1. The latest MCP specification revision and any changes that matter for servers.
2. The official SDK for {LANGUAGE} and its current stable version.
3. Transport choice: stdio for local use versus Streamable HTTP for remote use, and
   when each fits {deployment from agent 2 if known}.
4. Authorization for remote servers (the spec's OAuth-based flow) and how to reuse
   the app's existing auth.
5. Tool design: naming, input schemas, tool annotations (read-only, destructive,
   idempotent, open-world hints), output and structured content, pagination, and
   error reporting.
6. Testing tools (MCP Inspector or SDK test clients).

Return a brief of at most 40 lines, every claim with a source link. Mark anything
you could not verify.
```

## Large repositories

When `surface.tsv` lists more than about 40 route files or several services, split
researcher 1 by area or service: one agent per group, each with the same prompt and
only its files. Merge their JSON, then de-duplicate ids. Keep the total at 6 agents
or fewer.
