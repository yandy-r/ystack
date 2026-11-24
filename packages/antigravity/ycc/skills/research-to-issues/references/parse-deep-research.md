# Parse Deep-Research Output

Extraction instructions for deep-research documents produced by `deep-research`.

## Expected Source Structure

A directory containing:

| Document                                          | What to Extract                                                  |
| ------------------------------------------------- | ---------------------------------------------------------------- |
| `RESEARCH-REPORT.md` or `deep-research-report.md` | Research date, project name, key findings with confidence levels |
| `synthesis/strategic-recommendations.md`          | MVP features (section 4), anti-scope items (section 7)           |
| `synthesis/implementation-roadmap.md`             | Phase definitions, deliverables per phase, success criteria      |
| `analysis/convergence.md`                         | Confidence levels for cross-cutting concerns                     |
| `analysis/gaps-and-risks.md`                      | Research gaps with severity                                      |

Read each file and extract the structured data. Not all files may exist -- adapt to whatever is present.

## Step 1: Extract Features and Deliverables

For each phase found in the implementation roadmap, extract:

- **Phase metadata**: name, duration, team size, risk level, prerequisites, objective
- **Deliverables**: name, description, effort estimate
- **Success criteria**: the definition-of-done checklist

For each feature in strategic recommendations (section 4 "Must-Have Features for MVP" or equivalent), extract:

- **Feature name** and kebab-case slug
- **User story** (if present)
- **Acceptance criteria** (if present)
- **Technical complexity**
- **Dependencies**

Cross-reference features with convergence analysis to determine confidence levels.

## Step 2: Extract Anti-Scope and Research Gaps

Unless `--skip-anti-scope` is specified, extract from strategic recommendations (section 7 or "What NOT to Build"):

- **Item name**
- **Why deferred** (reasoning)
- **When to revisit** (timeline/conditions)

Unless `--skip-gaps` is specified, extract from gaps-and-risks analysis (section 1 "Research Gaps"):

- **Gap name**
- **Severity**
- **What was missed**
- **What needs further research**

## Step 3: Classify Priority

Apply priority mapping based on confidence:

| Confidence                       | Priority Label    | Extra Labels                   |
| -------------------------------- | ----------------- | ------------------------------ |
| High (7-8/8 personas, or "High") | `priority:high`   | --                             |
| Medium-High (5-6/8 personas)     | `priority:medium` | --                             |
| Medium or lower                  | `priority:low`    | `under-review`                 |
| Anti-scope items                 | `priority:low`    | `under-review`, `deferred`     |
| Research gaps                    | `priority:medium` | `under-review`, `research-gap` |

## Issue Mapping

| Source Element           | Issue Type                                  | Template                                |
| ------------------------ | ------------------------------------------- | --------------------------------------- |
| Each phase from roadmap  | 1 tracking issue                            | `tracking-issue.md`                     |
| Each feature/deliverable | 1 child issue under its phase               | `feature-issue.md`                      |
| Each anti-scope item     | 1 child issue under "Deferred" tracker      | `feature-issue.md` (anti-scope variant) |
| Each research gap        | 1 child issue under "Research Gaps" tracker | `feature-issue.md` (gap variant)        |

## Agentic Context Fields

For each child issue, populate these fields from research documents:

- **Summary**: Synthesized feature description from strategic recommendations
- **User Story**: From strategic recommendations feature table
- **Acceptance Criteria**: From strategic recommendations or success criteria
- **Technical Details**: Complexity, dependencies, confidence level from convergence analysis
- **Research Context**: Source document path and research date from RESEARCH-REPORT.md
- **Additional Context**: Relevant architecture notes, risk notes from other research docs

## Source-Specific Labels

All issues from this source type receive `source:deep-research`.
