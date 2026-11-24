---
paths:
  - 'scripts/generate_*'
  - 'scripts/generate-*'
  - 'scripts/validate_*'
  - 'scripts/validate-*'
  - 'scripts/sync.sh'
  - 'scripts/validate.sh'
---

# Compatibility generators and validators

Prefer `./scripts/sync.sh` and `./scripts/validate.sh`. Both support scoped
`--only <targets>` runs for iteration; consult `--help` for their supported target
sets (they differ). Do not change generated files independently of source.

| Target      | Targeted generation entrypoints                                                                                              | Targeted validation entrypoints                                                                                              |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Codex       | `generate-codex-skills.sh`, `generate-codex-agents.sh`, `generate-codex-plugin.sh`                                           | `validate-codex-skills.sh`, `validate-codex-agents.sh`, `validate-codex-plugin.sh`                                           |
| Cursor      | `generate-cursor-skills.sh`, `generate-cursor-agents.sh`, `generate-cursor-rules.sh`                                         | `validate-cursor-skills.sh`, `validate-cursor-agents.sh`, `validate-cursor-rules.sh`                                         |
| opencode    | `generate-opencode-skills.sh`, `generate-opencode-agents.sh`, `generate-opencode-commands.sh`, `generate-opencode-plugin.sh` | `validate-opencode-skills.sh`, `validate-opencode-agents.sh`, `validate-opencode-commands.sh`, `validate-opencode-plugin.sh` |
| Antigravity | `generate-antigravity-packages.sh`                                                                                           | `validate-antigravity-packages.sh`                                                                                           |
| OMP         | `generate-omp-skills.sh`                                                                                                     | `validate-omp-skills.sh`                                                                                                     |

All entrypoints above live under `scripts/`. See `scripts/sync.sh --help` for the
cross-tool `agents` target and inventory generation.

- Codex source skill plugin-root paths are rewritten to `~/.codex/plugins/ycc/`.
  Its native target installs skills plus TOML custom agents, not custom slash commands.
- opencode's thin native commands load public skills through the skill tool; never
  implement command recursion. Its bundle rules come from
  `ycc/settings/rules/CLAUDE.md`, not root `CLAUDE.md` or `AGENTS.md`.
- Agent additions/renames/removals must update `ycc/settings/models.json` under
  `targets.opencode.agents`; preserve `provider/model` references and validate the
  policy. A missing entry must remain a fail-fast generator error.
- `scripts/validate_practices.py` imports description budgets from
  `scripts/description_budget.py`. Keep that shared source of truth; do not
  reintroduce independent skill-description limits.
