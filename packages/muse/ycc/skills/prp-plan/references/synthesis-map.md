# Synthesis Map (--enhanced researcher → PRP plan section)

> **Contract**: When `ENHANCED_MODE=true`, the Phase 6 synthesizer routes each researcher's structured findings into the target plan section(s) below. Each section has a primary owner; secondary owners contribute supporting bullets only when their primary section is N/A. The PRP plan template (`plan-template.md`) is unchanged — no new sections.

## Mapping

| Researcher (name)     | Source subagent_type | Primary Plan Section(s)                                  | Secondary Section(s)                                                                                | Output Format                                               |
| --------------------- | -------------------- | -------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| api-researcher        | prp-researcher   | External Documentation                                   | Patterns to Mirror (REPOSITORY_PATTERN if API client exists); Files to Change (new client wrappers) | rows for the External Documentation table; IMPORTS in tasks |
| business-analyzer     | prp-researcher   | User Story; Problem → Solution; Acceptance Criteria      | —                                                                                                   | one user story line + acceptance bullets                    |
| tech-designer         | prp-researcher   | Files to Change; Step-by-Step Tasks (ACTION + IMPLEMENT) | Patterns to Mirror (SERVICE_PATTERN, REPOSITORY_PATTERN)                                            | direct task generation                                      |
| ux-researcher         | prp-researcher   | UX Design (Before / After / Interaction Changes)         | — (omit section if internal change)                                                                 | UX transformation table                                     |
| security-researcher   | prp-researcher   | Risks                                                    | Patterns to Mirror (ERROR_HANDLING); Acceptance Criteria gotchas                                    | severity-leveled rows fold into Risks                       |
| practices-researcher  | prp-researcher   | Patterns to Mirror (NAMING_CONVENTION, TEST_STRUCTURE)   | Step-by-Step Tasks (MIRROR field source); NOT Building (over-engineering callouts)                  | seeds MIRROR field on tasks                                 |
| recommendations-agent | prp-researcher   | Notes; Completion Checklist                              | NOT Building; Risks (cross-cutting)                                                                 | seeds Notes paragraph and confidence score                  |

> **Note**: `subagent_type` is `prp-researcher` for every row. The `description` and role-specific `prompt` on the Agent call differentiate one researcher role from another — all 7 enhanced roles dispatch the same agent type.

## Synthesis Rules

1. Each plan section has exactly ONE primary owner. The synthesizer renders the primary owner's findings first.
2. Secondary owners only contribute when (a) the primary owner returned empty/N/A, OR (b) the secondary owner's findings explicitly extend (not contradict) the primary's.
3. If a researcher returns no findings for ANY section it owns (primary or secondary), leave the existing template language in place — usually "N/A — internal change" — or, for fully optional sections, omit them.
4. The plan template is unchanged. Enhanced mode produces a richer plan because each section gets dedicated researcher input, not because new sections are added.
5. If the same finding is returned by multiple researchers (e.g., security-researcher and practices-researcher both flag the same input-validation gap), the synthesizer renders it once under the section owned by the higher-priority researcher (security > practices for risk-class findings).
