# Label Taxonomy

Complete label scheme for issues created by the research-to-issues skill. Create labels with `--force` to avoid errors on duplicates.

## Core Labels

| Label Pattern     | Color                   | Description               |
| ----------------- | ----------------------- | ------------------------- |
| `tracking`        | `0075ca` (blue)         | Tracking/epic issue       |
| `phase:*`         | `6f42c1` (purple)       | Development phase         |
| `batch:*`         | `6f42c1` (purple)       | PRP parallel batch        |
| `feat:*`          | `1d76db` (medium blue)  | Feature area (kebab-case) |
| `priority:high`   | `d73a4a` (red)          | High priority             |
| `priority:medium` | `fbca04` (yellow)       | Medium priority           |
| `priority:low`    | `0e8a16` (green)        | Low priority              |
| `under-review`    | `e4e669` (light yellow) | Needs decision            |
| `deferred`        | `d4c5f9` (light purple) | Explicitly deferred       |
| `research-gap`    | `f9d0c4` (light orange) | Research gap              |

## Source Provenance Labels

Applied automatically based on detected source type:

| Label                  | Color                 | Description                  |
| ---------------------- | --------------------- | ---------------------------- |
| `source:deep-research` | `bfd4f2` (light blue) | From deep-research output    |
| `source:feature-spec`  | `bfd4f2` (light blue) | From feature-research output |
| `source:parallel-plan` | `bfd4f2` (light blue) | From parallel-plan output    |
| `source:prp-plan`      | `bfd4f2` (light blue) | From PRP plan output         |
| `source:prd`           | `bfd4f2` (light blue) | From PRD output              |

## Type Labels

| Label            | Color                   | Description                        |
| ---------------- | ----------------------- | ---------------------------------- |
| `type:task`      | `c2e0c6` (light green)  | Implementation task (plan-sourced) |
| `type:feature`   | `c2e0c6` (light green)  | Feature item (research/spec)       |
| `needs-decision` | `fef2c0` (light yellow) | Decision needed before proceeding  |

## Priority Assignment by Source Type

| Source Type   | High Priority Signal             | Medium Priority Signal  | Low Priority Signal        |
| ------------- | -------------------------------- | ----------------------- | -------------------------- |
| deep-research | High confidence (7-8/8 personas) | Medium (5-6/8 personas) | Low confidence, anti-scope |
| feature-spec  | Phase 1 tasks, critical risks    | Phase 2 tasks           | Phase 3+, decisions needed |
| parallel-plan | Phase 1 tasks, no dependencies   | Middle phase tasks      | Final phase, polish tasks  |
| prp-plan      | Batch 1 / early tasks            | Middle tasks            | Late tasks, testing tasks  |
| prd           | Phase 1, Must capabilities       | Phase 2, Should caps    | Phase 3+, Could caps       |
