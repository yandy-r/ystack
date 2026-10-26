---
name: feature-research
description: Researches features with seven specialists and consolidates a feature
  spec. Use when investigating APIs, assessing feature risks, or researching UX before
  planning.
---

# Feature Research

> **OpenCode V2 compatibility:** `--team` is unsupported. If it is supplied, abort before setup or dispatch and ask the caller to rerun without it. This target uses native standalone `subagent` calls only.


**Operational context:** Dispatch api-researcher, business-analyzer, tech-designer, ux-researcher, security-researcher, practices-researcher, and recommendations-agent; write seven research-*.md files plus feature-spec.md at paths resolved through the artifact store, never docs/prps/. Local mode (default) keeps `docs/plans/[feature-name]/`; linear mode uses `.ycc/artifacts/[feature-name]/`. Use /prp-spec for lightweight single-pass PRP specs.

## Workflow Integration

```
feature-research  -->  plan-workflow  -->  implement-plan
(this skill)           (Step 2)            (Step 3)
Creates:               Uses:               Executes:
feature-spec.md        feature-spec.md     parallel-plan.md
```

**Key Distinctions — This skill vs. other planning/research skills**:

| Skill                     | Agents                            | Output Dir           | Output Files                          | Use When                                       |
| ------------------------- | --------------------------------- | -------------------- | ------------------------------------- | ---------------------------------------------- |
| `feature-research` (THIS) | 7 parallel agents                 | Resolved feature dir | 7 `research-*.md` + `feature-spec.md` | Deep multi-agent research before plan-workflow |
| `prp-spec`                | Single pass (optional researcher) | `docs/prps/specs/`   | `{name}.spec.md`                      | Lightweight spec for PRP workflow              |
| `prp-prd`                 | Interactive + researcher          | `docs/prps/prds/`    | `{name}.prd.md`                       | Full PRD with hypothesis-driven questioning    |
| `prp-plan`                | Single pass + researcher          | `docs/prps/plans/`   | `{name}.plan.md`                      | Implementation plan from PRD or description    |

**This skill ALWAYS**:

- Deploys all 7 researchers in parallel (never skips agents)
- Creates 7 `research-*.md` files + 1 `feature-spec.md`
- Outputs only to the artifact-store feature directory (`docs/plans/[feature-name]/` in local mode)
- Uses `research-<lens>` paths, including the linear `research/` subdirectory

**This skill NEVER**:

- Writes to `docs/prps/` (that is the PRP workflow directory)
- Generates a single-file spec without the research pipeline
- Skips the multi-agent research pipeline to produce output directly
- Acts as a lightweight spec generator

## Arguments

**Target**: `$ARGUMENTS`

Parse arguments (flags first, then the feature name):

- **--description "..."**: Brief description of the feature (guides research agents)
- **feature-name**: Required. Feature slug passed to the artifact-store resolver
- **--store=local|linear**: Optional artifact-store override. Forward it to every helper call. Local is the default; linear is opt-in.

If no feature name provided, abort with usage instructions:

```
Usage: /feature-research [--description "..."] [--dry-run] [--store=local|linear] [feature-name]

Examples:
  /feature-research plex-integration --description "Advanced Plex media library integration with filters and playlists"
  /feature-research payment-system --description "Stripe payment integration for subscriptions"
  /feature-research user-dashboard --dry-run
```

**Questions:** class `choose-path` (regenerate or enhance an existing spec); headless (no question tool or chat turn): enhance. See `~/.config/opencode/shared/references/question-policy.md`.

---

## Phase 0: Initialize

### Step 1: Parse Arguments

Extract from `$ARGUMENTS`:

2. **--description**: Quoted string after flag (optional but recommended)
3. **--dry-run**: Boolean flag. Set `DRY_RUN=true` if present, else `false`.
4. **feature-name**: First non-flag argument (required)
5. **--store=local|linear**: Parse and strip before selecting feature-name. Retain the exact override as `STORE_FLAG` (empty if absent), reject invalid/conflicting overrides, and pass it to every helper call and validator.

Validate the feature name: must be kebab-case, no special characters except hyphens.



### Step 2: Resolve Artifact Paths and Create Directories

**CRITICAL**: Write only to paths returned by the artifact-store resolver — NEVER to `docs/prps/` or another directory, regardless of the current working directory. Local mode (default) preserves `docs/plans/[feature-name]/`; linear mode resolves under `.ycc/artifacts/[feature-name]/`.

1. Print the mode and read `ARTIFACT_STORE=` from stdout; resolve paths without writes:

   ```bash
   bash "~/.config/opencode/shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --shell
   feature_dir="$(bash "~/.config/opencode/shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --kind=feature-dir --slug="[feature-name]")"
   research_dir="$(bash "~/.config/opencode/shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --kind=research-dir --slug="[feature-name]")"
   spec_file="$(bash "~/.config/opencode/shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --kind=feature-spec --slug="[feature-name]")"
   ```

2. For a non-dry linear run only, apply the **Linear call gate** from `~/.config/opencode/shared/references/artifact-store.md` before any write or pull.
3. Once writing is permitted, establish the safe cache and gitignore rule before Lookup/Load:

   ```bash
   feature_dir="$(bash "~/.config/opencode/shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --ensure --kind=feature-dir --slug="[feature-name]")"
   mkdir -p "$feature_dir" "$research_dir"
   ```

Dry runs only resolve paths, never ensure or Load. In local mode `research_dir` equals `feature_dir`. In a real linear run, populate missing inputs via Lookup/Load before checking research. For every research/spec document to be written, if `linear.document` identity is missing, follow artifact-store.md **Planning skills** Lookup steps 3–6 and Load any hit before dispatch/writing; preserve identity and use Conflict for replacement, then Save. Retain the printed mode and absolute paths across tool calls.

### Step 3: Check Existing Research

List any existing files. If `${spec_file}` exists, read it and ask user if they want to regenerate or enhance.

### Step 4: Handle Dry Run

If `--dry-run` is present:

Display:

```markdown
# Dry Run: Feature Research for [feature-name]

## Research Pipeline

Dispatch Mode: [standalone sub-agents]
Researchers: 7 (api-researcher, business-analyzer, tech-designer, ux-researcher, security-researcher, practices-researcher, recommendations-agent)

1. api-researcher - External APIs, libraries, integration patterns
2. business-analyzer - Requirements, user stories, business rules
3. tech-designer - Architecture, data models, API design
4. ux-researcher - User experience, workflows, best practices
5. security-researcher - Security analysis, dependency risks, secure coding (severity-leveled)
6. practices-researcher - Modularity, code reuse, KISS, engineering best practices
7. recommendations-agent - Ideas, improvements, risks

## Files That Would Be Created

- ${research_dir}/research-external.md
- ${research_dir}/research-business.md
- ${research_dir}/research-technical.md
- ${research_dir}/research-ux.md
- ${research_dir}/research-security.md
- ${research_dir}/research-practices.md
- ${research_dir}/research-recommendations.md
- ${spec_file}

## Execution Model

- Default (`STANDALONE_MODE=true`): deploy 7 researchers as standalone sub-agents in a single message with multiple native `subagent` calls. No team coordination; each sub-agent writes its assigned `research-*.md`. Orchestrator validates and synthesizes `feature-spec.md`.
```



Do **not** call `track the task`, `subagent`, or `re-dispatch the affected sub-agent with the needed guidance` in dry-run mode.

**STOP** without creating files or deploying agents.

---

## Phase 1: Research Pipeline

### Step 7: Read Research Prompts

Read the research prompts template:

```bash
cat ~/.config/opencode/skills/feature-research/templates/research-agents.md
```

### Step 8: Deploy the 7 Researchers

| Name / Sub-agent role  | Subagent Type               | Output File                   | Model   | Focus                                                                 |
| ----------------------- | --------------------------- | ----------------------------- | ------- | --------------------------------------------------------------------- |
| `api-researcher`        | `research-specialist`       | `research-external.md`        | configured | External APIs, libraries, documentation, integration patterns         |
| `business-analyzer`     | `codebase-research-analyst` | `research-business.md`        | configured | Requirements, user stories, business rules, domain logic              |
| `tech-designer`         | `codebase-research-analyst` | `research-technical.md`       | configured | Architecture, data models, API design, system constraints             |
| `ux-researcher`         | `research-specialist`       | `research-ux.md`              | configured | User experience, workflows, best practices, accessibility             |
| `security-researcher`   | `research-specialist`       | `research-security.md`        | configured | Security analysis, dependency risks, secure coding (severity-leveled) |
| `practices-researcher`  | `codebase-research-analyst` | `research-practices.md`       | configured | Modularity, code reuse, KISS, engineering best practices              |
| `recommendations-agent` | `codebase-research-analyst` | `research-recommendations.md` | configured | Ideas, improvements, related features, risks                          |


Use the prompts from `research-agents.md` with variables substituted:

- `{{FEATURE_NAME}}` - The feature directory name
- `{{FEATURE_DIR}}` - Resolved feature directory (`${feature_dir}`)
- `{{RESEARCH_<LENS>_FILE}}` - Absolute path from the executed resolver with kind `research-<lens>` and the same store override; in local mode these are `${feature_dir}/research-<lens>.md`, in linear mode `${feature_dir}/research/research-<lens>.md`
- `{{FEATURE_DESCRIPTION}}` - The description provided (or feature name if none)

#### Path A — Standalone sub-agents (`STANDALONE_MODE=true`, default)

**CRITICAL**: Deploy all 7 researchers in a **SINGLE message** with **MULTIPLE native `subagent` calls**. Every call sets `background=false`, uses the configured agent model, and follows the shared result policy below.

If a child report is empty or contentless, record its `sessionID`, inspect the declared artifact or working-tree edits, preserve valid work, and make at most one retry before reporting the child result incomplete. An artifact can preserve work but does not prove a child response. Follow `~/.config/opencode/shared/references/standalone-dispatch.md`.

### Step 9: Monitor Research Progress

Wait for all 7 researchers to complete their work.

If a child report is empty or contentless, record its `sessionID`, inspect the declared artifact or working-tree edits, preserve valid work, and make at most one retry before reporting the child result incomplete. An artifact can preserve work but does not prove a child response. Follow `~/.config/opencode/shared/references/standalone-dispatch.md`.
  - `api-researcher` tells `tech-designer` about discovered API endpoints and auth patterns
  - `api-researcher` tells `security-researcher` about dependency versions and auth methods
  - `api-researcher` tells `practices-researcher` about discovered libraries for build-vs-depend analysis
  - `tech-designer` tells `business-analyzer` about data model constraints
  - `tech-designer` tells `security-researcher` about proposed architecture for review
  - `tech-designer` tells `practices-researcher` about proposed component structure for modularity review
  - `ux-researcher` tells `business-analyzer` about user workflow requirements
  - `security-researcher` tells `tech-designer` about security constraints (with severity levels)
  - `security-researcher` tells `recommendations-agent` about full risk summary by severity
  - `practices-researcher` tells `tech-designer` about reusable code discoveries and simplification opportunities
  - `practices-researcher` tells `recommendations-agent` about modularity and reuse findings
  - `recommendations-agent` synthesizes insights from all sub-agents including security and practices findings

  If a sub-agent gets stuck, send them guidance via `re-dispatch the affected sub-agent with the needed guidance`.

**Failure policy for Path B** (mirrors deep-research):

- **Single sub-agent failure**: record the gap in the corresponding `research-*.md` (stub note) and continue — downstream synthesis will adapt.
- **Mid-run user abort**: `re-dispatch the affected sub-agent with the needed guidance(shutdown)` to every active sub-agent, then confirm all sub-agents have shut down. Never exit with sub-agents still live.

---

## Phase 2: Consolidate Research

### Step 10: Validate Research Artifacts

After all 7 sub-agents complete, validate all `research-*.md` files:

```bash
~/.config/opencode/skills/feature-research/scripts/validate-research.sh "${feature_dir}" ${STORE_FLAG}
```

If validation fails: message the relevant sub-agent to fix their output, wait for correction, rerun validation until pass.

In linear mode, after validation and fixes, follow artifact-store.md section **Planning skills** to Save each of the seven `research-<lens>` documents.

### Step 12: Read Research Results

Read all 7 research files from `${research_dir}/`.

### Step 13: Read Spec Template

```bash
cat ~/.config/opencode/skills/feature-research/templates/spec-structure.md
```

### Step 14: Generate feature-spec.md

Create `${spec_file}` following the template. In linear mode use `./research/research-<lens>.md` research links; in local mode use `./research-<lens>.md`. When replacing an existing spec, preserve its identity frontmatter in linear mode and replace only the body; local mode writes the body without frontmatter.

**Key Consolidation Principles**:

1. Organize by section, not by agent - Synthesize related findings
2. Be information-dense - Every sentence should add value
3. Include actionable details - Links, code examples, specific APIs
4. Highlight decisions needed - Call out areas requiring user input
5. Preserve source references - Link to original research files for details
6. Surface security findings by severity - CRITICAL items must appear in Risk Assessment; WARNING items in relevant technical sections; ADVISORY items in Recommendations

---

## Phase 3: Validate and Complete

### Step 15: Validate Spec

Run after Step 14 creates `feature-spec.md`:

```bash
~/.config/opencode/skills/feature-research/scripts/validate-spec.sh "${spec_file}" ${STORE_FLAG}
```

Fix any issues reported (missing sections, empty content, formatting).

In linear mode, follow artifact-store.md section **Planning skills** to Save the validated `feature-spec` document. Local mode writes no identity frontmatter and makes no Linear calls.

### Step 17: Display Summary

Provide completion summary with: feature name, description, dispatch mode (standalone sub-agents), files created, research summary counts, key findings, decisions needed, and next steps (review spec, proceed to `/plan-workflow`, or add requirements).

---

## Quality Standards

### feature-spec.md Quality Checklist

- Executive summary is information-dense (3-5 sentences)
- External dependencies include documentation links
- Business requirements are specific and testable
- Technical specs include data models/schemas
- UX considerations address error states
- Recommendations are actionable
- Task breakdown preview is realistic

### Research Quality Checklist

Each research file should: focus on its specific domain, include concrete examples and links, identify gaps and uncertainties, provide actionable recommendations, and avoid duplication with other research files.

## Anti-patterns — Do NOT Do These

1. **Do NOT skip the multi-agent pipeline**: Never generate `feature-spec.md` directly without first deploying all 7 researchers (standalone sub-agents) and collecting their `research-*.md` files. The spec is a synthesis of research, not a standalone generation. If about to write `feature-spec.md` without the 7 research files already on disk, STOP — the pipeline is off-rails.

2. **Do NOT output to `docs/prps/`**: Write only to the resolved feature directory (`docs/plans/[feature-name]/` in local mode, `.ycc/artifacts/[feature-name]/` in linear mode). The `docs/prps/` tree belongs to the PRP workflow (`prp-prd`, `prp-spec`, `prp-plan`, `prp-implement`). Even if the user's working directory is `docs/prps/` or any subdirectory, always use the resolver-selected output path.

3. **Do NOT generate a single file**: The minimum correct output is 8 files (7 research + 1 spec). If about to write only one file, STOP — the user likely wants the lightweight PRP spec skill. Redirect them to `/prp-spec`.

4. **Do NOT conflate with PRP spec generation**: If the user wants a lightweight single-pass spec without the 7-researcher pipeline, they want `/prp-spec`, not this skill. This skill is the heavyweight multi-agent research track regardless of dispatch mode.

## Important Notes

- **You are the research orchestrator** — coordinate the 7 researchers and synthesize the spec
- **Spawn in parallel** — a single message with 7 native `subagent` calls (Path A) or 7 native `subagent` calls with `description` plus the role-specific `prompt` (Path B)
- **Single-owner research files** — each researcher writes only its assigned artifact
- **Gate synthesis with validation** — do not generate `feature-spec.md` before validator pass
- **Use web search** — external APIs require current documentation
- **Be thorough but focused** — quality over quantity
- **Enable plan-workflow** — this spec is the foundation for implementation planning
- **Preserve uncertainty** — mark areas needing clarification rather than guessing
