---
name: prp-plan
description: Creates self-contained PRP plans with codebase patterns. Use when planning
  from a PRD, writing a .plan.md artifact, or capturing patterns for prp-implement.
---

# PRP Plan

> **OpenCode V2 compatibility:** `--team` is unsupported. If it is supplied, abort before setup or dispatch and ask the caller to rerun without it. This target uses native standalone `subagent` calls only.

Create a detailed, self-contained implementation plan that captures all codebase patterns, conventions, and context needed to implement a feature in a single pass.

**Operational context:** Detect PRD versus free-form input, discover codebase patterns through prp-researcher with optional external research, and write the resolved `prp-plan` artifact for /prp-implement.

> Adapted from PRPs-agentic-eng by Wirasm. Part of the PRP workflow series.

**Core Philosophy**: A great plan contains everything needed to implement without asking further questions.

**Golden Rule**: If you would need to search the codebase during implementation, capture that knowledge NOW.

---

## Phase 0 — DETECT

### Flag Parsing

Extract flags from `$ARGUMENTS`:

| Flag                    | Effect                                                                                                                                                                                                                                                                                                                       |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--parallel`            | Fan out research into 3 **standalone sub-agent** researchers; emit tasks with batch/dependency annotations. Works in opencode, Cursor, and Codex.                                                                                                                                                                         |
| `--worktree`            | (legacy — now default; safe to omit) Worktree annotations are emitted by default. Accepted as a silent no-op so existing pipelines continue to work.                                                                                                                                                                         |
| `--no-worktree`         | Opt out of worktree annotations. The plan will not contain a `## Worktree Setup` section or per-task `**Worktree**:` annotations.                                                                                                                                                                                            |
| `--enhanced`            | Enhanced research mode: grow the research fan-out from 3 to 7 specialized researchers (api/business/tech/ux/security/practices/recommendations — same coverage as feature-research). Output is still a single PRP-compliant plan file. Composes with --parallel (default) (Claude Code only), and --no-worktree. |
| `--visual`              | Render the finished plan as an Agent-Native visual artifact (MDX) via `visual-plan`; local-files by default, hosted shareable link requires `--share`.                                                                                                                                                                   |
| `--store=local\|linear` | Artifact-store override; strip it before interpreting the feature description or input path and forward it to every resolver and visual-plan call.                                                                                                                                                                           |

Strip the flags. Set `PARALLEL_MODE=true|false`, ``, `DRY_RUN=true|false`. Default `WORKTREE_MODE=true`; set false for `--no-worktree`. `--worktree` is a legacy no-op. Parse and strip the store override as below; reject invalid `--store=` values or conflicting overrides rather than including them in the description. Only the remaining text is the feature description or PRD/spec path.

```bash
STORE_FLAG=
case " $ARGUMENTS " in
  *" --store=linear "*) STORE_FLAG=--store=linear ;;
  *" --store=local "*) STORE_FLAG=--store=local ;;
esac
if [ -n "$STORE_FLAG" ]; then ARGUMENTS="${ARGUMENTS//$STORE_FLAG/}"; fi
# Default ON; pass --no-worktree to opt out. --worktree accepted as legacy no-op.
WORKTREE_MODE=true
case " $ARGUMENTS " in
  *" --no-worktree "*) WORKTREE_MODE=false ;;
esac
ARGUMENTS="${ARGUMENTS//--no-worktree/}"
ARGUMENTS="${ARGUMENTS//--worktree/}"  # legacy no-op

ENHANCED_MODE=false
case " $ARGUMENTS " in
  *" --enhanced "*) ENHANCED_MODE=true ;;
esac
ARGUMENTS="${ARGUMENTS//--enhanced/}"

VISUAL_MODE=false
case " $ARGUMENTS " in
  *" --visual "*) VISUAL_MODE=true ;;
esac
ARGUMENTS="${ARGUMENTS//--visual/}"
```

**Validation**:

- `--no-worktree` is **orthogonal** to `--parallel` — it may be combined freely with either flag or used alone to suppress annotations.
- `--visual` is orthogonal — it composes with `--parallel`/`--enhanced`/`--no-worktree` and runs after the plan is written and validated. `--dry-run` short-circuits it (prints intent only).


**Questions:** class `clarify` (Ambiguity Gate): headless (no question tool or chat turn), print the open questions and stop; a team retry offer prints the `--parallel` rerun and stops. See `~/.config/opencode/shared/references/question-policy.md`.

### Input Detection

| Input Pattern                                | Action                                                            |
| -------------------------------------------- | ----------------------------------------------------------------- |
| Path ending in `.prd.md` or named `prd.md`   | Parse PRD, find next pending phase                                |
| Path ending in `.spec.md` or named `spec.md` | Read spec, extract requirements and technical approach as context |
| Path to `.md` with phases                    | Parse phases, find next pending                                   |
| Path to other file                           | Read for context, treat as free-form                              |
| Free-form text                               | Proceed to Phase 1                                                |
| Empty                                        | Ask user what feature to plan                                     |

### PRD Parsing (when input is a PRD)

1. Read the PRD, parse **Implementation Phases**
2. Find next eligible `pending` phase (check dependency chains)
3. Extract phase name, description, acceptance criteria, dependencies
4. Use the phase description as the feature to plan

If no pending phases remain, report all phases complete.

---

## Phase 1 — PARSE

Extract from the input:

- **What** is being built, **Why** it matters, **Who** uses it, **Where** it fits

Format a user story: `As a [user], I want [capability], so that [benefit].`

Assess complexity: Small (1-3 files) | Medium (3-10 files) | Large (10+ files) | XL (20+ files, consider splitting)

### Ambiguity Gate

If the core deliverable is vague, success criteria undefined, multiple valid interpretations exist, or there are major technical unknowns — **STOP and ask the user**. Do NOT guess.

### Resolve artifact paths

Derive `<slug>` from the feature name (kebab-case), not the cache filename `prp-plan.md`. If the input is a linear cache `prd.md` or `spec.md`, reuse its parent directory name as `<slug>` so the plan shares its source's feature Project. Retain the parsed `STORE_FLAG` and pass it to every resolver call.

1. Resolve and print the mode, then read `ARTIFACT_STORE=` from stdout:

   ```bash
   bash "${HOME}/.config/opencode/shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --shell
   OUT="$(bash "${HOME}/.config/opencode/shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --kind=prp-plan --slug=<slug>)"
   RESEARCH_DIR="$(bash "${HOME}/.config/opencode/shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --kind=prp-research --slug=<slug>)"
   ```

   These calls resolve only; do not run `--ensure`, `mkdir`, Load, or any other write before the C.2 dry-run exit. Dry runs write nothing and require no Linear gate.

2. For a real linear run, apply the **Linear call gate** from `~/.config/opencode/shared/references/artifact-store.md` before any write, including a cache pull or research backstop.
3. At the first permitted write, run the resolver with `${STORE_FLAG} --ensure --kind=<kind> --slug=<slug>` for that destination. Plan output is ensured only at Phase 6. Before loading a linear PRD/spec, ensure its source kind and slug, then apply Load; skip identity frontmatter when reading its body. Before research dispatch that writes backstops, ensure `prp-research`, then `mkdir -p "$RESEARCH_DIR"`; default sequential research creates no scratch directory.

Local mode (default) keeps `docs/prps/plans/<slug>.plan.md` and `docs/prps/plans/.prp-research/<slug>/` under the current checkout's git toplevel, with no identity frontmatter. Linear research backstops remain local-only. Follow artifact-store.md **Planning skills** for identity Lookup/Load before writing and Save, including task sub-issues. Shell state does not persist across tool calls: retain the printed mode, absolute `OUT` and `RESEARCH_DIR`, and substitute them in all later commands and prompts.

---

## Phase 2 — EXPLORE

Gather codebase intelligence across 8 categories and 5 traces.

**8 categories**: Similar Implementations, Naming Conventions, Error Handling, Logging Patterns, Type Definitions, Test Patterns, Configuration, Dependencies

**5 traces**: Entry Points, Data Flow, State Changes, Contracts, Patterns


### Path A — Sequential (default)

Dispatch a single `prp-researcher` agent via the `subagent` tool, in codebase mode, to cover all 8 categories and 5 traces. Use the discovery table for the plan's Patterns to Mirror section.

**IMPORTANT — Researcher prompt constraints**: Tell the researcher to keep code snippets to **5 lines max** per finding and limit the total response to the discovery table format only — no prose summaries.

By default (`WORKTREE_MODE=true`), append the following directive to the researcher prompt. Omit when `--no-worktree` was passed (`WORKTREE_MODE=false`):

> **WORKTREE MODE:** The plan you are helping to build will include worktree annotations. In the emitted plan, include a `## Worktree Setup` section with a single `**Parent**:` line naming the feature worktree; no `**Children**:` list; no per-task `**Worktree**:` annotations. All tasks (parallel and sequential) share this one feature worktree path. Follow `~/.config/opencode/shared/references/worktree-strategy.md` for the naming scheme and annotation format.

### Path B — Three standalone researchers (`PARALLEL_MODE=true`)

Dispatch `patterns-research`, `quality-research`, and `infra-research` in one parallel foreground batch. Each call uses `agent="prp-researcher"`, the role name in `description`, a complete role prompt, and `background=false`. Validate every candidate report against its declared backstop artifact and apply the canonical contentless-result policy before synthesis.

#### Path B (enhanced) — when `ENHANCED_MODE=true`

- Replace the 3-row researcher table above with the 7-row roster from `~/.config/opencode/skills/prp-plan/references/enhanced-researchers.md`.
- Before dispatch, ensure `prp-research` after the Linear gate when applicable, then create `$RESEARCH_DIR` with `mkdir -p`. Dispatch in a **SINGLE message** with **SEVEN native `subagent` calls** (standalone — no `name`). Wait for all researcher results, whether returned directly or delivered asynchronously, before synthesis.
- Each call uses `@prp-researcher` with `description` set to the role name (`api-researcher`, `business-analyzer`, `tech-designer`, `ux-researcher`, `security-researcher`, `practices-researcher`, `recommendations-agent`) and the role-specific prompt from `enhanced-researchers.md`. Substitute `{{RESEARCH_DIR}}` with the resolved absolute directory in every prompt. Each role writes `${RESEARCH_DIR}/<role-name>.md` in addition to returning the same content inline.
- The 5-line snippet cap and discovery-table-only constraints used in the 3-researcher path apply unchanged.

## Phase 3 — RESEARCH

If the feature involves external libraries/APIs, dispatch `prp-researcher` in external mode. Keep findings to KEY_INSIGHT / APPLIES_TO / GOTCHA / SOURCE format.

If only internal patterns are used, skip: "No external research needed."

---

## Phase 4 — DESIGN

If the feature has UX changes, document before/after user experience and interaction changes.

If purely backend/internal: "Internal change — no user-facing UX transformation."

---

## Phase 5 — ARCHITECT

Define:

- **Approach**: High-level strategy
- **Alternatives Considered**: What was rejected and why
- **Scope**: What WILL be built
- **NOT Building**: What is OUT OF SCOPE

---

## Phase 6 — GENERATE

**CRITICAL: Write the plan progressively in chunks to avoid timeouts.**

Now that the dry-run exit is past, in linear mode apply the Linear call gate before ensuring the plan destination:

```bash
OUT="$(bash "${HOME}/.config/opencode/shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --ensure --kind=prp-plan --slug=<slug>)"
mkdir -p "$(dirname "$OUT")"
```

Before writing in linear mode, follow artifact-store.md **Planning skills**: if document or task identity is missing, run Lookup steps 3–6 and Load any hit, preserving identity and using Conflict for replacement. Write progressively to this same absolute `$OUT`; use it throughout validation, visualization, and handoff, never a second destination.

### Step 1: Read the template

Read the plan template from `~/.config/opencode/skills/prp-plan/references/plan-template.md`.


For parallel or enhanced research, verify every expected backstop file. If a report is empty, record its `sessionID`, inspect the artifact, preserve valid work, retry at most once, and still report the child response incomplete; an artifact preserves work but does not prove a response.


If `ENHANCED_MODE=true`, also read `~/.config/opencode/skills/prp-plan/references/synthesis-map.md` and use it to route each researcher's findings into the correct plan section. The plan template is unchanged. Enhanced mode produces a richer plan because each section gets dedicated researcher input, not because new sections are added. Avoid section bloat — if a researcher returns no findings for a section, leave the existing N/A language in place or omit fully optional sections.

### Step 2: Write the plan in chunks

**Do NOT generate the entire plan in a single Write call.** Instead:

1. **Write** the initial file with: header through Metadata (+ Batches section if parallel), UX Design, and Mandatory Reading sections
   - By default (`WORKTREE_MODE=true`), include the `## Worktree Setup` section immediately after the Metadata / Batches block and before the first implementation section (see worktree annotation rules below). The section contains a single `**Parent**:` line only. When `--no-worktree` was passed (`WORKTREE_MODE=false`), omit this section.
2. **Edit/append** the Patterns to Mirror section (populated from researcher discovery tables)
3. **Edit/append** the Files to Change + NOT Building sections
4. **Edit/append** the Step-by-Step Tasks section (this is usually the largest — keep each task description concise)
   - All tasks (parallel and sequential) share the single feature worktree. Do NOT add per-task `- **Worktree**: ...` annotation lines.
5. **Edit/append** the Testing Strategy, Validation Commands, Acceptance Criteria, Completion Checklist, Risks, and Notes sections

Each chunk should be a separate Write or Edit call. This prevents any single generation from being too large.

### Worktree annotations (default — `WORKTREE_MODE=true`; skipped when `--no-worktree`)

Use the feature slug resolved in Phase 1 for `<feature-slug>` (never derive it from the linear cache filename). Derive `<repo>` from `git rev-parse --show-toplevel` basename.

**`## Worktree Setup` section** (top-level, before Batches/implementation):

```markdown
## Worktree Setup

- **Parent**: <repo-root>/.opencode/worktrees/<repo>-<feature-slug>/ (branch: feat/<feature-slug>)
```

All tasks — parallel and sequential — share this one feature worktree path. No `**Children**:` list and no per-task `**Worktree**:` annotation lines are emitted.

> **Plan-file handoff**: in local mode, leave `$OUT` in the current checkout; the implementor (`prp-implement`) will **move** it into the feature worktree once created — do not pre-write or copy it there (see `worktree-strategy.md` §7). In linear mode, never move the cache; the implementor loads the plan from it via `/prp-implement --store=linear {resolved cached plan path or Linear Document URL}`.

Follow `~/.config/opencode/shared/references/worktree-strategy.md` for the full naming scheme and annotation contract.

### Writing guidelines

- **Keep task descriptions concise** — ACTION and VALIDATE are required; IMPLEMENT should be 2-3 sentences max, not full code blocks
- **Patterns to Mirror snippets**: Use the researcher's snippets directly, max 5 lines each
- **Omit sections that don't apply** rather than writing "N/A" for every sub-field
- **Validation commands**: Use actual project commands discovered during exploration

---

## Phase 6.5 — VALIDATE

After writing the plan file, run the structural validator:

```bash
~/.config/opencode/skills/prp-plan/scripts/validate-prp-plan.sh "$OUT"
```

### On errors (exit 1)

Review the error output. For each error:

- **Missing section**: Edit the plan file to add the section with appropriate content from the research phases
- **Missing task fields**: Edit affected tasks to add ACTION and VALIDATE at minimum
- **Invalid file paths**: Verify the path using Glob, then fix the path in the plan
- **Placeholder text**: Replace with actual content from codebase exploration

Re-run the validator **once** after fixes. If it still fails, include the validation output in the report to the user so they are aware of remaining issues.

### On warnings only (exit 0)

Include a brief note in the report: "Plan validated with N warning(s) — see validator output for details."

**Do NOT loop more than once.** One fix pass maximum.

After the validation/fix pass, Save the final `$OUT` in linear mode through artifact-store.md **Planning skills**, including its task sub-issues and dependency relations. Preserve existing identity frontmatter while editing. Local mode stops after the file write and validation.

---

## Phase 7 — VISUALIZE (optional)


- If `VISUAL_MODE=true` and `--dry-run` is NOT set, invoke `visual-plan ${STORE_FLAG} <plan-path>` — passing the resolved absolute `$OUT` and the retained override — and capture its printed link.
- If `--dry-run` is set, print `visual generation would run` and skip the invocation.

---

## Visual mode

This skill exposes the shared `--visual` decorator. The canonical contract lives at `~/.config/opencode/shared/references/visual-mode.md` — follow it for composition, timing, and hand-off rules.

When `VISUAL_MODE` is set and `--dry-run` is NOT, invoke `visual-plan ${STORE_FLAG} <absolute-plan-path>` after Phase 6.5 with the resolved absolute `$OUT`. It resolves the store-specific `visual/` output directory and prints the link; surface it in the Report block. When `--dry-run` is set, print `visual generation would run` and skip — no visual artifacts, directories, or links are produced.

---

## Output

### Update PRD (if input was a PRD)

Update the phase status from `pending` to `in-progress` and add the actual resolved plan path. In linear mode preserve the source PRD's identity and Save that updated `prd` artifact through artifact-store.md **Planning skills**.

### Report to User

```
## Plan Created

- **File**: {resolved absolute OUT path}
- **Source PRD**: [path or "N/A"]
- **Phase**: [phase name or "standalone"]
- **Complexity**: [level]
- **Scope**: [N files, M tasks]
- **Key Patterns**: [top 3 discovered patterns]
- **External Research**: [topics or "none needed"]
- **Risks**: [top risk or "none identified"]
- **Confidence Score**: [1-10]
- **Research Dispatch**: [Sequential | Parallel sub-agents| Enhanced (7 researchers)]
- **Execution Mode**: [Sequential | Parallel (N batches, max width X)]
- **Worktree Mode**: [Enabled (default) — plan includes ## Worktree Setup (single feature worktree — **Parent**: line only) | Disabled via --no-worktree]
- **Visual Artifact**: [Generated via visual-plan | n/a (--visual not set)]
- **Visual Link**: [hosted URL | http://127.0.0.1:PORT/... | local files only | n/a (--visual not set)]

> Next step (local mode only): Run `/prp-implement {resolved absolute OUT path}` to execute this plan.
> In linear mode replace that command with: Run `/prp-implement --store=linear {resolved cached plan path or Linear Document URL}` to execute this plan.
```

---

## Verification

Structural validation is enforced by `validate-prp-plan.sh` in Phase 6.5. The validator operates on the written plan file; standalone dispatch details do not change the plan format.

The `validate-prp-plan.sh` script checks:

- Required and recommended sections from the PRP plan template
- Task field completeness (ACTION, VALIDATE required; MIRROR, IMPLEMENT recommended)
- File path existence for Files to Change and Mandatory Reading
- Parallel-mode integrity (if Batches section present)
- Placeholder text detection
- Self-containment heuristic (percentage of tasks with all 4 core fields)

---

## Next Steps

- Local mode: run `/prp-implement <plan-path>` to execute this plan. Linear mode: run `/prp-implement --store=linear <cached plan path or Linear Document URL>`.
- Run `/plan` for quick conversational planning without artifacts
- Run `/plan-workflow` for the heavyweight parallel-agent planning track

**Entry points into this skill** — `prp-spec` and `prp-prd` are parallel paths, not sequential:

- Run `/prp-spec` for a lightweight single-pass spec when the problem is clear
- Run `/prp-prd` for interactive hypothesis-driven discovery when the problem is unclear
