#!/usr/bin/env python3
"""Workflow-specific OpenCode V2 dispatch and result contracts."""

from __future__ import annotations

import re

_IMPLEMENT_PLAN_DISPATCH = """### Path A — Standalone Sub-Agent Batches (default)

Read `~/.config/opencode/shared/references/standalone-dispatch.md` before the
first batch. Dispatch every implementor through OpenCode V2's native foreground
tool call:

```text
subagent(agent="implementor", description="Implement [Task ID]: [Title]",
         prompt="<complete task prompt>", background=false)
```

Omit `sessionID` for a new child. Issue independent calls in one parallel tool
batch, with one call per ready task. Explicit `background=false` is required
because the next dependency batch needs each report. Do not use a resumed child
as a result lookup; a call carrying `sessionID` performs more work.

Each prompt must include the task's exact file ownership, working directory,
implementation requirements, validation commands, and final `STATUS:` format.

"""

_IMPLEMENT_PLAN_RESULT_POLICY = """#### Process Batch Results (Path A)

After each foreground batch returns:

1. Validate every nonempty report and require its final `STATUS:` line.
2. Inspect the working tree and every declared artifact independently. A host
   `succeeded` or `completed` state does not verify the deliverables.
3. Run the focused checks required for the files owned by that task.
4. If a completion has no report, mark it incomplete, record the child
   `sessionID`, and inspect the working tree before retrying because edits may
   already exist. Preserve valid edits and make at most one retry.
5. Mark the task complete only after its report, on-disk work, and checks agree.
   Keep failed tasks visible and continue only independent work.
6. Print `[done] Batch BN: K tasks — complete` only after every accepted task in
   the batch passes those checks.

"""

_FOREGROUND_REPORT_BLOCK = """> **OpenCode V2 standalone dispatch:** Issue the independent calls in one
> parallel tool batch and set `background=false` on every call. Each call waits
> for a candidate report. Require nonempty report text, validate the declared
> artifact or diff independently, and do not treat a terminal lifecycle state
> as proof of the deliverable. Apply the contentless-completion and bounded
> retry policy from
> [standalone-dispatch.md](~/.config/opencode/shared/references/standalone-dispatch.md).
"""

_CONTENTLESS_RESULT_POLICY = (
    "If a child report is empty or contentless, record its `sessionID`, inspect "
    "the declared artifact or working-tree edits, preserve valid work, and make "
    "at most one retry before reporting the child result incomplete. An artifact "
    "can preserve work but does not prove a child response. Follow "
    "`~/.config/opencode/shared/references/standalone-dispatch.md`."
)


def _project_foreground_result_contracts(text: str) -> str:
    """Replace Claude inline-return assumptions with explicit foreground semantics."""
    output = re.sub(
        r"> \*\*Standalone dispatch rule.*?\*\*:.*?(?=\n\n)",
        _FOREGROUND_REPORT_BLOCK,
        text,
        flags=re.DOTALL,
    )
    output = re.sub(
        r"In the normal case `(?:Task|subagent)` \*\*blocks\*\*:.*?"
        r"See `~/.config/opencode/shared/references/standalone-dispatch\.md` "
        r"for the full contract\.",
        (
            "Dispatch the researchers with explicit `background=false`. Each call "
            "waits for a candidate report. Require nonempty structured findings and "
            "validate the corresponding backstop file before accepting the result; "
            "a terminal lifecycle state alone is insufficient. Apply the "
            "contentless-completion and one-retry policy in "
            "`~/.config/opencode/shared/references/standalone-dispatch.md`."
        ),
        output,
        flags=re.DOTALL,
    )
    output = re.sub(
        r"(?:native )?`(?:Task|subagent)` calls block until each sub-agent "
        r"returns\. Completion is implicit when all parallel calls in the single "
        r"message return\.",
        "every native `subagent` call sets `background=false`. Process the batch "
        "after all calls return candidate reports, then validate each report and "
        "owned artifact before marking completion.",
        output,
    )
    output = output.replace(
        "(blocking, standalone dispatch — see `~/.config/opencode/shared/references/standalone-dispatch.md`)",
        "(foreground standalone dispatch with explicit `background=false`; see "
        "`~/.config/opencode/shared/references/standalone-dispatch.md`)",
    )
    output = output.replace(
        "findings return inline as the call result",
        "each call returns candidate findings for independent validation",
    )
    output = output.replace(
        "for the blocking `subagent` semantics this relies on",
        "for the foreground report and artifact validation contract",
    )
    output = re.sub(
        r"Each native `subagent` call blocks and returns[^.]*\.",
        (
            "Every call sets `background=false` and returns a candidate report "
            "that must be checked against its declared artifact."
        ),
        output,
    )
    output = output.replace(
        "depends on `PARALLEL_MODE` and ``:",
        "depends on `PARALLEL_MODE`:",
    )
    return output


def _project_research_workflow_contracts(text: str, source_path: str) -> str:
    """Preserve research stages while projecting dispatch and result guarantees."""
    if not source_path.endswith(("plan-workflow/SKILL.md", "feature-research/SKILL.md", "deep-research/SKILL.md")):
        return text

    output: list[str] = []
    for line in text.splitlines(keepends=True):
        if "**Model Assignment**" in line:
            continue
        if re.search(r"\bmodel:\s*[\"'`](?:sonnet|haiku|opus)[\"'`]", line, re.IGNORECASE):
            continue
        line = re.sub(r"\|\s*(?:sonnet|haiku|opus|Default)\s*\|", "| configured |", line)
        line = line.replace(
            "uses the `agent` and `model` from the table above",
            "uses the `agent` from the table above and inherits its configured model",
        )
        line = line.replace(
            "uses the `agent` and `model` from the relevant table above",
            "uses the `agent` from the relevant table and inherits its configured model",
        )
        if "**CRITICAL**: Deploy" in line and (
            "native `subagent` calls" in line or "parallel subagent invocations" in line
        ):
            prefix = re.split(
                r"(?:native `subagent` calls|parallel subagent invocations)\*\*",
                line,
                maxsplit=1,
            )[0]
            line = (
                f"{prefix}native `subagent` calls**. Every call sets "
                "`background=false`, uses the configured "
                "agent model, and follows the shared result policy below.\n"
            )
        if "Path A (standalone, default)" in line and "spawn all 5 unified agents" in line:
            line = (
                "- **Path A (standalone, default)**: spawn all 5 unified agents in "
                "one parallel batch; every native `subagent` call sets "
                "`background=false` and inherits the configured agent model.\n"
            )
        if (
            "inline return is empty" in line
            or "return value plus the artifact check" in line
            or "return values; each sub-agent writes" in line
            or "source of truth before treating it as a failure" in line
        ):
            line = f"{_CONTENTLESS_RESULT_POLICY}\n"
        output.append(line)

    projected = "".join(output)
    projected = re.sub(
        r"```\nTeam name:.*?```\n",
        "",
        projected,
        flags=re.DOTALL,
    )
    projected = re.sub(r"^[-*]\s*$\n?", "", projected, flags=re.MULTILINE)
    if "native `subagent` calls" in projected and _CONTENTLESS_RESULT_POLICY not in projected:
        projected += f"\n{_CONTENTLESS_RESULT_POLICY}\n"
    return projected


def _project_implement_plan(text: str) -> str:
    """Replace the standalone dispatch and result gates without losing task details."""
    output = re.sub(
        r"^### Path A — Standalone Sub-Agent Batches \(default\)\n.*?" r"(?=^\*\*When `WORKTREE_ACTIVE=true`\*\*)",
        _IMPLEMENT_PLAN_DISPATCH,
        text,
        count=1,
        flags=re.MULTILINE | re.DOTALL,
    )
    output = re.sub(
        r"^#### Process Batch Results \(Path A\)\n.*?" r"(?=^#### Repeat Until Complete \(Path A\))",
        _IMPLEMENT_PLAN_RESULT_POLICY,
        output,
        count=1,
        flags=re.MULTILINE | re.DOTALL,
    )
    return "".join(
        line
        for line in output.splitlines(keepends=True)
        if "Path B" not in line and "Sub-agent team" not in line and "sub-agent roster" not in line.lower()
    )


def _project_required_workflow_surfaces(text: str, source_path: str) -> str:
    """Preserve supported flags and alias contracts after team-mode removal."""
    output = text
    if source_path.endswith("shared-context/SKILL.md"):
        output = re.sub(
            r"- Supported:.*",
            "- Supported: the feature name, `--dry-run`.",
            output,
            count=1,
        )
        output = re.sub(
            r"Usage: /shared-context.*",
            "Usage: /shared-context [feature-name] [--dry-run]",
            output,
            count=1,
        )
        output = re.sub(
            r"<feature-name> --research-only --no-checkpoint.*",
            "<feature-name> --research-only --no-checkpoint [--dry-run]",
            output,
            count=1,
        )
        output = output.replace(
            "(`--team` / `--dry-run` only if the user passed them;",
            "(`--dry-run` only if the user passed it;",
        )
    elif source_path.endswith("parallel-plan/SKILL.md"):
        output = re.sub(
            r"- Supported:.*",
            "- Supported: the feature name, `--dry-run`, `--no-worktree`, `--visual`.",
            output,
            count=1,
        )
        output = re.sub(
            r"Usage: /parallel-plan.*",
            "Usage: /parallel-plan [--no-worktree] [--visual] [feature-name] [--dry-run]",
            output,
            count=1,
        )
        output = re.sub(
            r"<feature-name> --plan-only --no-checkpoint.*",
            "<feature-name> --plan-only --no-checkpoint [--dry-run] [--no-worktree] [--visual]",
            output,
            count=1,
        )
    elif source_path.endswith("code-review/SKILL.md"):
        output = re.sub(
            r"Strip these from `\$ARGUMENTS` and set .*?The remaining text is the "
            r"mode selector \(PR number/URL or blank for local\)\.",
            (
                "Strip the supported flags from `$ARGUMENTS` and set "
                "`QUICK_MODE=true|false`, `PARALLEL_MODE=true|false`, "
                "`NO_WORKTREE_MODE=true|false`, `KEEP_DRAFT=true|false`, and "
                "`KEEP_WORKTREE=true|false`. Keep `--store=local|linear` verbatim "
                "as `STORE_FLAG` (empty when absent) and forward it to every "
                "resolver call. Compute `WORKTREE_MODE=true` unless "
                "`--no-worktree` is present. The remaining text is the mode selector "
                "(PR number/URL or blank for local)."
            ),
            output,
            count=1,
        )
        output = "".join(
            line
            for line in output.splitlines(keepends=True)
            if not (line.lstrip().startswith("-") and "--team" in line)
        )
        output = output.replace(
            "Compatible with `--parallel` and `--team`.",
            "Compatible with `--parallel`.",
        )
        output = re.sub(r" `--team` still requires opencode[^.]*\.", "", output)
    elif source_path.endswith("review-fix/SKILL.md"):
        output = re.sub(
            r"Strip these flags from `\$ARGUMENTS` and set .*?The remaining text is " r"the input selector\.",
            (
                "Strip the supported flags from `$ARGUMENTS` and set "
                "`PARALLEL_MODE`, `MIN_SEVERITY`, `DRY_RUN`, and "
                "`WORKTREE_MODE=true` unless `--no-worktree` is present. Keep "
                "`--store=local|linear` verbatim as `STORE_FLAG` (empty when "
                "absent) and forward it to every resolver call. The "
                "remaining text is the input selector."
            ),
            output,
            count=1,
        )
        output = output.replace(
            "If `DRY_RUN=true` and `STANDALONE_MODE=true`, stop here.",
            "If `DRY_RUN=true`, stop here.",
        )
        output = output.replace(" [--parallel | --team]", " [--parallel]")
        output = re.sub(r"\s*\| Agent team \(N batches, max width W\)", "", output)
        output = re.sub(
            r"\| `--dry-run`[^\n]*",
            "| `--dry-run` | Print the fix plan and stop. Do not dispatch fixers or modify files. |",
            output,
            count=1,
        )
        output = re.sub(
            r"Dry run complete\. To apply fixes, re-run without --dry-run:.*?```",
            (
                "Dry run complete. To apply fixes, re-run without --dry-run:\n"
                "  /review-fix ${STORE_FLAG} $REVIEW_SELECTOR [--parallel] [--severity <level>]\n```"
            ),
            output,
            count=1,
            flags=re.DOTALL,
        )
        output = output.replace("regardless of Path A / B / C", "for both Path A and Path B")
        output = output.replace(
            "(N batches, max width W)**Severity",
            "(N batches, max width W)\n**Severity",
        )
        if "| `--dry-run`" not in output:
            output = re.sub(
                r"(\| `--severity <level>`[^\n]*\n)",
                (r"\1| `--dry-run` | Print the fix plan and stop. Do not " "dispatch fixers or modify files. |\n"),
                output,
                count=1,
            )
        output = re.sub(
            r"Branch based on `PARALLEL_MODE` and ``:.*?" r"(?=### Worktree-mode lifecycle)",
            ("Use Path B when `PARALLEL_MODE=true`; otherwise use sequential Path A.\n\n"),
            output,
            count=1,
            flags=re.DOTALL,
        )
    elif source_path.endswith("implement-plan/SKILL.md"):
        output = re.sub(
            r"Strip the flags from `\$ARGUMENTS` and set .*?The remaining " r"non-flag token is the feature name\.",
            (
                "Strip the supported flags from `$ARGUMENTS` and set "
                "`DRY_RUN=true|false`, `WORKTREE_MODE=true|false`, and "
                "`WORKTREE_FLAG_PRESENT=true|false`. The remaining non-flag token "
                "is the feature name."
            ),
            output,
            count=1,
        )
        output = re.sub(
            r"Usage: /implement-plan.*",
            "Usage: /implement-plan [--dry-run] [--worktree] [--no-worktree] <feature-name>",
            output,
            count=1,
        )
        output = re.sub(
            r"```\nTeam name:.*?```\n",
            "",
            output,
            count=1,
            flags=re.DOTALL,
        )
        output = "".join(line for line in output.splitlines(keepends=True) if "agent-team dispatch" not in line.lower())
        output = output.replace(
            "### Step 8: Branch on ``\n\n"
            "- `STANDALONE_MODE=true` → **Path A — Standalone sub-agent "
            "batches** (default).",
            "### Step 8: Execute standalone batches",
        )
    elif source_path.endswith("orchestrate/SKILL.md"):
        output = re.sub(
            r"\*\*2\. Spawn ALL batch agents.*?\n",
            (
                "**2. Spawn ALL batch agents in a SINGLE message** using multiple "
                "native `subagent` calls with `background=false`. Use only `agent`, "
                "`description`, and the complete `prompt`; validate every candidate "
                "report and owned artifact before accepting it.\n"
            ),
            output,
            count=1,
        )
        output = output.replace(
            "No `re-dispatch the affected sub-agent with the needed guidance` "
            "shutdown needed in Path A — there are no sub-agents to shut down.",
            "Foreground child calls require no separate shutdown; every child has "
            "already returned its candidate report.",
        )
        output = output.replace(
            "the full `subagent`-vs-`subagent` dispatch contract and anti-patterns",
            "the full native standalone dispatch, result, and failure contract",
        )
        output = re.sub(r"Branch on ``:\n\n", "Use standalone execution:\n\n", output)
        output = re.sub(
            r"```\nTeam name:.*?```\n",
            "",
            output,
            flags=re.DOTALL,
        )
    elif source_path.endswith("prp-plan/SKILL.md"):
        output = re.sub(
            r"Structural validation is enforced by `validate-prp-plan\.sh` in "
            r"Phase 6\.5\..*?(?=The `validate-prp-plan\.sh` script)",
            (
                "Structural validation is enforced by `validate-prp-plan.sh` in "
                "Phase 6.5. The validator operates on the written plan file; "
                "standalone dispatch details do not change the plan format.\n\n"
            ),
            output,
            count=1,
            flags=re.DOTALL,
        )
        output = output.replace(
            "The `validate-prp-plan.sh` script The script checks:",
            "The `validate-prp-plan.sh` script checks:",
        )
    elif source_path.endswith(("code-review/SKILL.md", "quick-review/SKILL.md")):
        output = output.replace(
            "The shape of this phase depends on `PARALLEL_MODE` and ``:",
            "The shape of this phase depends on `PARALLEL_MODE`:",
        )
    elif source_path.endswith("plan-workflow/SKILL.md"):
        output = output.replace("[standalone sub-agents]]", "[standalone sub-agents]")
        output = re.sub(
            r"If validation fails: in Path B, message the relevant sub-agent to fix "
            r"their output; in Path A, re-dispatch the failing sub-agent via "
            r"`subagent`\.",
            "If validation fails, re-dispatch the failing sub-agent via `subagent` with the validation error.",
            output,
        )
        output = re.sub(
            r"If validation fails → in Path B, message the relevant sub-agent; in "
            r"Path A, re-dispatch the failing sub-agent via `subagent`\.",
            "If validation fails, re-dispatch the failing sub-agent via `subagent`.",
            output,
        )
        output = output.replace(
            "6. If validation fails, the orchestrator MUST message the failing "
            "sub-agent (Path B) or re-dispatch the sub-agent (Path A)",
            "6. If validation fails, the orchestrator MUST re-dispatch the failing sub-agent with the validation error",
        )
        output = "".join(
            line
            for line in output.splitlines(keepends=True)
            if "Message on failure (Path B)" not in line and "Inter-agent sharing:" not in line
        )
    output = output.replace(
        "depends on `PARALLEL_MODE` and ``:",
        "depends on `PARALLEL_MODE`:",
    )
    return output


def _project_operational_team_clauses(text: str, source_path: str) -> str:
    """Remove remaining team-only clauses after standalone invariants are restored."""
    output = text
    output = output.replace(" and `--team`", "")
    output = output.replace(" or `--team`", "")
    output = output.replace(" / `--team`", "")
    output = output.replace("`--parallel --team --visual`", "`--parallel --visual`")
    output = output.replace(
        "(standalone sub-agents or sub-agents, depending on `--team`)",
        "(standalone sub-agents)",
    )
    output = output.replace("(both standalone Path A and `--team` Path B)", "(standalone Path A)")
    output = output.replace(
        "Path A (standalone) in default mode, Path B (Team Communication) only when `--team` is passed.",
        "Use the Path A standalone coordination block.",
    )
    if source_path.endswith("plan-workflow/SKILL.md"):
        output = re.sub(
            r"In the `--team` Path B additionally cross-reference.*?separate per-task paths\.\n",
            "",
            output,
            count=1,
            flags=re.DOTALL,
        )
        output = re.sub(
            r"2\. In Path B \(`--team`\).*?independently\.\n",
            ("2. Standalone sub-agents work independently; include all required context in each prompt.\n"),
            output,
            count=1,
        )
    if source_path.endswith("visual-mode.md"):
        output = re.sub(
            r"See \[worktree-strategy\.md\].*?that `--team` layers on top of planning\.\n",
            "See [worktree-strategy.md](./worktree-strategy.md) for where plan artifacts live.\n",
            output,
            count=1,
            flags=re.DOTALL,
        )
        output = re.sub(
            r"Because `--visual` is a terminal decorator, the combination\n"
            r"`--parallel --visual` \(etc\.\) means:.*?single `--visual` step on the result\.\n",
            (
                "Because `--visual` is a terminal decorator, `--parallel --visual` "
                "means: finish standalone planning, write and validate the plan, then "
                "run the single `--visual` step.\n"
            ),
            output,
            count=1,
            flags=re.DOTALL,
        )

    kept: list[str] = []
    for line in output.splitlines(keepends=True):
        if "--team" in line and "OpenCode V2 compatibility" not in line:
            continue
        kept.append(line)
    return "".join(kept)
