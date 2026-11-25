# Standalone Dispatch — OpenCode V2 `subagent` Contract

This is the generated OpenCode V2 contract for standalone child-agent work. It uses
the host's native vocabulary directly. OpenCode V2 does not expose Claude Code's
agent-team tools, and `--team` workflows must abort before dispatch.

## 1. Native call shape

A new child session uses all required fields and omits `sessionID`:

```text
subagent(agent="<agent>", description="<short title>",
         prompt="<complete task prompt>", background=false)
```

The fields mean:

- `agent`: the configured subagent ID.
- `description`: a short title for the child session.
- `prompt`: the complete task, context, ownership boundary, working directory, output
  contract, and artifact paths. A new child starts with fresh context.
- `background`: set it explicitly on every call. Never depend on a host or plugin
  default.

Only configured agents with `mode: subagent` or `mode: all` can be dispatched. The
default nesting depth is one, so a child normally cannot launch another child.

Independent calls may be issued in one parallel tool batch. Keep file ownership
disjoint when children share a working tree.

## 2. Foreground dispatch

Use foreground dispatch when the next step depends on the child's report:

```text
subagent(agent="<agent>", description="<short title>",
         prompt="<complete task prompt>", background=false)
```

Omit `sessionID` for a new child. Never pass a placeholder session ID.

The call waits for the child run and returns its response. Treat the response as a
candidate report, not proof that the requested work exists. Before accepting it:

1. Require nonempty report text in the requested format.
2. Validate every declared file, artifact, or working-tree change independently.
3. Run the required focused checks for the work.
4. Treat a host `succeeded` or `completed` lifecycle state only as evidence that the
   child run terminated; it does not verify the deliverables.

## 3. Background dispatch

Use background dispatch only when useful independent work remains or the workflow
explicitly supports deferred result retrieval:

```text
subagent(agent="<agent>", description="<short title>",
         prompt="<complete task prompt>", background=true)
```

Omit `sessionID` for a new child. Never pass a placeholder session ID.

The initial return is an acknowledgement containing a child `sessionID`, not the final
report. Record that ID immediately. Continue only non-overlapping work. If there is
nothing productive to do, end the turn so the native terminal notification can be
delivered.

Do not use shell sleeps or tight status loops. After a terminal notification, a host
plugin may advertise read-only lifecycle and result tools:

```text
task_status(sessionID="<child session ID>")
task_result(sessionID="<child session ID>")
```

Use `task_status` for one bounded inspection when the notification is ambiguous. Use
`task_result` to retrieve verified terminal report text. If either reports
`running`, `pending`, or `running (unconfirmed)`, stop checking and wait for the next
native notification. Do not loop.

These `task_*` tools are plugin extensions, not guaranteed OpenCode built-ins. When
they are absent, use foreground dispatch for work whose report is required. Never
invent a result-retrieval tool.

## 4. Resume is not result retrieval

Continue an existing child conversation only when more work or clarification is
required:

```text
subagent(agent="<agent>", description="<follow-up title>",
         prompt="<new follow-up instruction>",
         sessionID="<existing child session ID>", background=false)
```

Passing `sessionID` resumes the child and may run tools or change files again. Never
call `subagent` with `sessionID` merely to fetch a prior report. Use `task_result` when
it is advertised, or report that native result retrieval is unavailable.

## 5. Deliverable verification

The parent owns final verification. A child report and host lifecycle state are two
separate signals:

| Signal                     | What it proves                                        |
| -------------------------- | ----------------------------------------------------- |
| `succeeded` / `completed`  | The host observed a terminal child run.               |
| Nonempty structured report | The child described an outcome in the required shape. |
| Required files or diff     | The requested on-disk work exists.                    |
| Focused checks             | The produced work satisfies the requested validation. |

Do not mark parent work complete until every required signal for that task is present.
For code-writing children, inspect the working tree and validate the files they owned.
For research or review children, read the declared artifact as well as the report.

## 6. Contentless and failed outcomes

A contentless completion is incomplete even when the host reports success. Handle it
in this order:

1. Record and report the child `sessionID`.
2. Inspect the working tree and every declared artifact before retrying; the child may
   have made edits without returning a report.
3. Preserve valid existing edits and avoid duplicate work.
4. Retry at most once with the same child only when a follow-up report is safe, or with
   a new child when the original session cannot continue. State which form of one retry
   you chose.
5. If the retry is also contentless, report the task as incomplete. Do not synthesize a
   success report.

Treat explicit `failed`, `error`, `interrupted`, or `cancelled` outcomes as failures.
Surface the child ID and available error text. Continue only work that is independent
of the failed deliverable.

## 7. Artifact backstop

Content-producing children should write their result to a declared artifact path and
return the same material in their report. Code-writing children use their owned diff as
the artifact and finish with the required machine-readable status line.

When report text is missing:

1. Read the artifact or inspect the owned diff.
2. Validate it before using it.
3. Still report the missing child report as incomplete; an artifact can preserve useful
   work but does not turn a contentless run into a verified child response.

## 8. Unsupported team mode

OpenCode V2 standalone dispatch has no team-name argument, shared team roster, or Claude Code
team lifecycle. If a workflow receives `--team`, abort with a compatibility message and
instruct the caller to rerun the default standalone mode. Never translate team identity
into `sessionID`; a child-session resume ID is a different concept.
