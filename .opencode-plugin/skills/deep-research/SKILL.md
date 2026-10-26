---
name: deep-research
description: Conducts multi-perspective strategic research. Use when investigating
  complex topics, comparing competitors, or gathering strategic intelligence.
---

# Deep Research — Asymmetric Research Squad

> **OpenCode V2 compatibility:** `--team` is unsupported. If it is supplied, abort before setup or dispatch and ask the caller to rerun without it. This target uses native standalone `subagent` calls only.

You are the orchestrator: deploy eight distinct research personas, run a crucible
analysis, generate emergent insights, then synthesize actionable intelligence.
Preserve contradictions and uncertainty; do not replace missing research with guesses.

## Phase 0: Define and Set Up

Parse `$ARGUMENTS`: flags first. Parse and strip `--store=local|linear`, retain the exact override as `STORE_FLAG` (empty when absent), and reject invalid/conflicting overrides. Forward `${STORE_FLAG}` to every resolver call. Only the remaining text is the required research subject.

Default: standalone parallel sub-agents.

- `--output-dir "..."`: explicit working directory, overriding either store's default. Local mode defaults to `research/[sanitized-subject]`; linear mode resolves kind `deep-research`.
- `--dry-run`: display the plan without running checks, creating files, or dispatching.

Missing subject: abort with usage and an example:

```text
/deep-research --dry-run "AI model deployment strategies"
```

Require a focused topic. Sanitize the default directory name: lowercase, replace
spaces with hyphens, remove characters other than alphanumerics and hyphens.

Step 1: resolve and **print** the store with the executed helper; read `ARTIFACT_STORE=` from stdout:

```bash
bash "~/.config/opencode/shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --shell
```

Use the sanitized subject as `<slug>`; if empty, request a focused subject instead of choosing a directory. Without `--output-dir`, local mode keeps `research/<slug>`; linear mode obtains `OUTPUT_DIR` from the helper's `--kind=deep-research --slug=<slug>` (without `--ensure` during dry-run). Explicit `--output-dir` always wins for working files. Retain the absolute output path across tool calls; shell state does not persist. The entire working tree is local-only; in linear mode only the final report is saved as research lens `deep-research`.

### Dry run

Display the subject, output path, four phases (8 personas, 2 crucible agents,
4 strategic agents, report synthesis), and this artifact tree: `objective.md`,
`persona-findings/{historian,contrarian,analogist,systems-thinker,journalist,archaeologist,futurist,negative-space}.md`,
`synthesis/{crucible-analysis,contradiction-mapping,tension-mapping,pattern-recognition,negative-space,innovation}.md`,
`evidence/verification-log.md`, `report.md`.
**STOP**: do not run prerequisite scripts, dispatch agents, create directories, or write artifacts.

### Infrastructure and objective (not dry run)

Step 2: before any write in linear mode, apply the **Linear call gate** from `~/.config/opencode/shared/references/artifact-store.md`. Run the prerequisite script against the selected `OUTPUT_DIR` before creating it:

```bash
~/.config/opencode/skills/deep-research/scripts/check-prerequisites.sh "$OUTPUT_DIR"
```

Step 3: in linear mode without explicit `--output-dir`, resolve the working directory with `--ensure` after the gate:

```bash
OUTPUT_DIR="$(bash "~/.config/opencode/shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --ensure --kind=deep-research --slug=<slug>)"
```

Then create `"$OUTPUT_DIR/persona-findings"`, `"$OUTPUT_DIR/synthesis"`, and `"$OUTPUT_DIR/evidence"` in either mode. Do not redirect an explicit `--output-dir` to the cache.

Write `$OUTPUT_DIR/objective.md` with 3–5 research questions, success criteria,
evidence standards, perspectives to cover, and 2–3 subject-specific bias risks.
Use the phase checklist below as the success criteria. Give every agent the
absolute objective and output paths, subject, and any user scope constraints.

## References and Routing

Resolve paths against `~/.config/opencode/skills/deep-research/`. Read only the
reference needed for the current phase; report any unreadable file.
**Do not read or paste all persona prompts into orchestrator context.** Each
persona agent reads its own file. The table gives exact paths and read conditions.

| Reference                                   | Read when                                                                                                                                    |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `references/persona-historical.md`          | Historian agent starts Phase 1: evolution, failures, forgotten alternatives.                                                                 |
| `references/persona-contrarian.md`          | Contrarian agent starts Phase 1: disconfirming evidence, critiques, failures.                                                                |
| `references/persona-analogical.md`          | Analogist agent starts Phase 1: structural parallels across domains.                                                                         |
| `references/persona-systems.md`             | Systems Thinker agent starts Phase 1: feedback, stakeholders, causal chains.                                                                 |
| `references/persona-journalistic.md`        | Journalist agent starts Phase 1: current state, players, dated developments.                                                                 |
| `references/persona-archaeological.md`      | Archaeologist agent starts Phase 1: obsolete solutions from 10–50 years ago.                                                                 |
| `references/persona-futurist.md`            | Futurist agent starts Phase 1: patents, speculative research, 2030+ forecasts.                                                               |
| `references/persona-negative-space.md`      | Negative Space Explorer agent starts Phase 1: omissions, barriers, gaps.                                                                     |
| `references/analysis-prompts.md`            | Crucible or strategic agents start Phases 2–3: use their named mandate.                                                                      |
| `references/verification-log-template.md`   | Orchestrator verifies critical claims after Phase 2: preserve claimants, sources, verification status, and competing claims with resolution. |
| `references/completion-summary-template.md` | Orchestrator reports completion after Phase 4: formatted summary with separate counts for all four strategic analyses.                       |
| `references/synthesis-template.md`          | Orchestrator starts Phase 4: report structure and writing checks.                                                                            |

## Dispatch Contract (All Batches)

### Standalone (default)

See `~/.config/opencode/shared/references/standalone-dispatch.md` for the
standalone-dispatch contract (Task vs Agent+team, anti-patterns, backstop policy).
Spawn each batch in one message. Each agent writes its declared artifact. When a
result comes back empty or cut short, re-read the matching artifact from disk and
treat it as authoritative before declaring that dispatch failed.
Record a single failure as a gap in its artifact; adapt later phases. If at least
half a batch fails, abort and report the gaps instead of fabricating results.

## Phase 1: Asymmetric Persona Deployment (Batch 1)

All eight use `research-specialist`. Output paths are relative to `$OUTPUT_DIR`.

| Persona                 | Sub-agent name             | Persona file                           | Output file                           |
| ----------------------- | ------------------------- | -------------------------------------- | ------------------------------------- |
| Historian               | `historian`               | `references/persona-historical.md`     | `persona-findings/historian.md`       |
| Contrarian              | `contrarian`              | `references/persona-contrarian.md`     | `persona-findings/contrarian.md`      |
| Analogist               | `analogist`               | `references/persona-analogical.md`     | `persona-findings/analogist.md`       |
| Systems Thinker         | `systems-thinker`         | `references/persona-systems.md`        | `persona-findings/systems-thinker.md` |
| Journalist              | `journalist`              | `references/persona-journalistic.md`   | `persona-findings/journalist.md`      |
| Archaeologist           | `archaeologist`           | `references/persona-archaeological.md` | `persona-findings/archaeologist.md`   |
| Futurist                | `futurist`                | `references/persona-futurist.md`       | `persona-findings/futurist.md`        |
| Negative Space Explorer | `negative-space-explorer` | `references/persona-negative-space.md` | `persona-findings/negative-space.md`  |

**CRITICAL**: Deploy all 8 persona agents in a **SINGLE message** with **MULTIPLE native `subagent` calls**. Every call sets `background=false`, uses the configured agent model, and follows the shared result policy below.


Even for a small topic, pass each resolved absolute persona file path, not its text.
Each prompt follows this shape, with concrete values:

```text
Read <absolute plugin root>/skills/deep-research/references/persona-<name>.md first.
RESEARCH_SUBJECT=<subject>
OUTPUT_DIR=<absolute output directory>
Read <output directory>/objective.md. Substitute these variables in your brief.
Use your distinct search strategy; cite evidence and confidence, record uncertainty.
Write <absolute output file> and return findings. User constraints: <constraints>.
```

Require 8–10 diverse queries per persona; brief findings do not mean skipping
personas. Track completion of each persona and its artifact. Wait for all eight
(or explicit failure records) before Phase 2.


## Phase 2: The Crucible (Batch 2)

Read all eight persona artifacts and objective.

**CRITICAL**: Deploy both analysis agents in a **SINGLE message** with **MULTIPLE native `subagent` calls**. Every call sets `background=false`, uses the configured agent model, and follows the shared result policy below.


Pass the `references/analysis-prompts.md` resolved path and the named mandate,
subject, output directory, and input artifact paths. Agents read their own section.

| Agent / sub-agent name                         | Subagent type               | Output                               |
| --------------------------------------------- | --------------------------- | ------------------------------------ |
| ACH Analyst / `ach-analyst`                   | `general-purpose`           | `synthesis/crucible-analysis.md`     |
| Contradiction Mapper / `contradiction-mapper` | `codebase-research-analyst` | `synthesis/contradiction-mapping.md` |

ACH: generate 5+ mutually exclusive hypotheses; weigh disconfirming evidence.
Contradiction Mapper: preserve disagreements, assess sources, identify patterns.
After completion, triangulate critical claims: fetch primary sources, document
confirmations, partial confirmations, confidence, competing evidence, and unresolved
contradictions in `$OUTPUT_DIR/evidence/verification-log.md`. Read
`references/verification-log-template.md` when writing this log and preserve its fields.
Claims repeated by
multiple personas still need verification, not a vote.


## Phase 3: Emergent Insights (Batch 3)

**CRITICAL**: Deploy all 4 strategic analysis agents in a **SINGLE message** with **MULTIPLE native `subagent` calls**. Every call sets `background=false`, uses the configured agent model, and follows the shared result policy below.


Give each the resolved `references/analysis-prompts.md`
path, named mandate, objective, all persona findings, both crucible outputs, and
verification log. Require the following artifacts:

| Agent / sub-agent name                             | Subagent type               | Output                             |
| ------------------------------------------------- | --------------------------- | ---------------------------------- |
| Tension Mapper / `tension-mapper`                 | `codebase-research-analyst` | `synthesis/tension-mapping.md`     |
| Pattern Recognizer / `pattern-recognizer`         | `general-purpose`           | `synthesis/pattern-recognition.md` |
| Negative Space Analyst / `negative-space-analyst` | `codebase-research-analyst` | `synthesis/negative-space.md`      |
| Innovation Agent / `innovation-agent`             | `general-purpose`           | `synthesis/innovation.md`          |

Keep `negative-space-analyst` distinct from Phase 1's `negative-space-explorer`.
Consume all four results (or gap records).


## Phase 4: Strategic Synthesis (Orchestrator Only)

Read all artifacts: eight personas, two crucible analyses, four strategic analyses,
and verification log. Read `references/synthesis-template.md` when composing the
final report. Write `$OUTPUT_DIR/report.md` using its structure.

### Synthesis rules

- Organize by insight/theme, not persona; combine related findings without losing
  distinct perspectives. Executive synthesis is information-dense, not a recap.
- Highlight contradictions; capture both claims, evidence, extra investigation,
  and which is better supported. Retain unresolved tensions and confidence ratings.
- Apply evidence hierarchy: primary (original research, official records, first-hand
  accounts) > secondary (expert/peer-reviewed analysis) > synthetic (aggregated media)
  > speculative (predictions, opinions, unverified claims).
- Separate facts, analogies, and forecasts. Preserve uncertainty and missing evidence.
- Focus on actionable implications: second/third-order effects, stakeholders,
  leverage points, and explicit further-research questions.

Run `scripts/validate-research.sh` when report and artifacts are ready:

```bash
~/.config/opencode/skills/deep-research/scripts/validate-research.sh "$OUTPUT_DIR"
```

Fix missing/empty artifacts, weak citation coverage, and format issues. Report
actual validation result and any remaining gaps; do not call a failed run complete.

After validation, local mode keeps `FINAL_REPORT="$OUTPUT_DIR/report.md"` with no identity frontmatter or Linear calls. In linear mode, resolve the published report separately:

```bash
OUT="$(bash "~/.config/opencode/shared/scripts/resolve-artifact-store.sh" ${STORE_FLAG} --ensure --kind=research-deep-research --slug=<slug>)"
mkdir -p "$(dirname "$OUT")"
```

Before writing `$OUT`, follow artifact-store.md **Planning skills**: if `linear.document` identity is missing, run Lookup steps 3–6 and Load any hit; preserve its identity and use Conflict before replacement, then Save the validated report (Document `<slug> · research-deep-research`). Set `FINAL_REPORT` to this path. Keep `$OUTPUT_DIR/report.md` and all intermediate findings local-only, including with explicit `--output-dir`. Report the working directory and final saved report path.
Read `references/completion-summary-template.md` when presenting the formatted
completion summary. Preserve its per-persona counts and separate Phase 3 counts:
tensions, patterns, research gaps, and novel hypotheses. Report actual counts,
discoveries, unresolved disagreements, evidence quality, and artifact paths;
do not collapse the four strategic analyses into a generic emergent-insights count.

## Method and Phase Checklist

### Query variation: SCAMPER

Substitute X with Y; Combine X and Y; Adapt another domain; Modify scale/scope;
Put to other uses; Eliminate X; Reverse assumptions. Use 8–10 well-crafted,
diverse queries rather than generic volume. Keep each persona's mandate distinct.

Cover past (10–50 years), recent past (1–10 years), present, near future (1–5 years),
and far future (5+ years). Sources must be authoritative and dated/current where relevant.

### Phase 1

- [ ] All 8 personas deployed with distinct search strategies
- [ ] 8–10 queries per persona executed.
- [ ] Findings cite primary sources, confidence, uncertainties, and contradictions.
- [ ] Historical, cross-domain, systemic, present, future, and missing perspectives covered.

### Phase 2

- [ ] ACH has 5+ mutually exclusive hypotheses and actively seeks disconfirmation.
- [ ] Cross-persona contradictions and patterns mapped, not smoothed over.
- [ ] Primary-source verification log maintained; major claims have citations.

### Phase 3

- [ ] Tension mapping identifies maximum disagreement.
- [ ] Pattern recognition finds unexpected connections.
- [ ] Negative space documents unanswered questions.
- [ ] Innovation combines perspectives into novel, evidence-rated hypotheses.

### Phase 4

- [ ] Executive synthesis is dense intelligence, not a persona-by-persona summary.
- [ ] Evidence portfolio includes confidence and preserves distinct viewpoints.
- [ ] Strategic implications cover second/third-order effects and temporal range.
- [ ] Research gaps and validation result explicitly reported.
- [ ] Sub-agent shutdown completed via re-dispatch the affected sub-agent with the needed guidance if applicable.

## Corrective Actions

Similar findings: revisit individual mandates and SCAMPER strategies. Speculation
outweighing evidence: fetch primary sources. Shallow research: inspect query logs.
Missing contradictions: seek disconfirming evidence rather than smoothing tensions.
Summary-only report: reread artifacts and synthesize insights. Missing gaps: revisit
both negative-space roles. Never silently invent evidence to fill a failed artifact.

If a child report is empty or contentless, record its `sessionID`, inspect the declared artifact or working-tree edits, preserve valid work, and make at most one retry before reporting the child result incomplete. An artifact can preserve work but does not prove a child response. Follow `~/.config/opencode/shared/references/standalone-dispatch.md`.
