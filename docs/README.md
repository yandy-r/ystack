# `docs/` — Repository Documentation

Hand-maintained documentation for the `ystack` repository. The
top-level `README.md` covers user-facing plugin surfaces (skills, commands,
agents) and links to focused guides here for install details, implementation
plans, release notes, review artifacts, and ad-hoc recommendations.

The repository's canonical agent-runtime rules live in
[`../AGENTS.md`](../AGENTS.md); [`../CLAUDE.md`](../CLAUDE.md) imports it and adds
Claude-only notes, and path-specific Claude rules live under
[`../.claude/rules/`](../.claude/rules/). Per-skill documentation lives inline at
`../ycc/skills/<name>/SKILL.md`.

## Layout

| Path                           | Purpose                                                                          |
| ------------------------------ | -------------------------------------------------------------------------------- |
| `install/`                     | Runtime-specific install guides for Claude, Cursor, Codex, opencode, and OMP.    |
| `internal/`                    | Architecture notes, native-package records, and spike dossiers.                  |
| `plans/`                       | Multi-phase implementation plans — see below.                                    |
| `releases/`                    | One file per tagged release, drafted by `ycc:bundle-release`.                    |
| `prps/`                        | Product Requirements / Plans / Reviews — PRP-workflow artifacts.                 |
| `inventory.json`               | **Generated.** Skill/command/agent manifest. Regenerate via `./scripts/sync.sh`. |
| `pre-commit-recommendation.md` | Stand-alone note on pre-commit hook policy.                                      |

## Install Guides

Runtime-specific install instructions live under [`install/`](install/):

- [`install/README.md`](install/README.md) — the installer reference: intents, scope, automatic legacy cleanup, removal.
- [`install/claude.md`](install/claude.md) — Claude Code native plugins plus Claude Desktop MCP setup.
- [`install/codex.md`](install/codex.md) — Codex native plugins, custom agents, and Codex Desktop setup.
- [`install/cursor.md`](install/cursor.md) — Cursor native plugins (marketplace registration and `/plugins`) and CLI settings.
- [`install/opencode.md`](install/opencode.md) — opencode-native skills, agents, commands, config, and rules.
- [`install/agents.md`](install/agents.md) — cross-tool skills in `~/.agents/skills`.
- [`install/omp.md`](install/omp.md) — OMP (oh-my-pi) native packages, `install.sh install --target omp`, and platform limits.
- [`install/v6/README.md`](install/v6/README.md) — native package reference: package IDs, catalog shape, tested versions, evidence.

## Plans

Multi-phase implementation plans capture non-trivial changes that span
multiple commits. Scope-creep, dependency order, and risk notes belong here,
not in commit messages.

- [`plans/2026-04-07-consolidate-plugins-to-ycc.md`](plans/2026-04-07-consolidate-plugins-to-ycc.md)
  — the 2.0.0 collapse from 9 separate plugins into the unified `ycc`
  bundle.

New plans are named `YYYY-MM-DD-<kebab-case-summary>.md`. Commit them with
`docs(internal): …` so they stay out of release notes.

## Releases

One file per tagged release, drafted by the `/ycc:bundle-release` skill and
referenced by `gh release create --notes-file`. Structure is enforced by the
template in
[`../ycc/skills/bundle-release/references/release-notes-template.md`](../ycc/skills/bundle-release/references/release-notes-template.md).

Latest entries:

- [`releases/6.1.1.md`](releases/6.1.1.md) pins Node.js 22.23.4 and 24.22.1 and markdown-it 14.3.3. Plugin behavior is unchanged.
- [`releases/6.1.0.md`](releases/6.1.0.md) adds OMP packages (`omp >= 18.12.2`), `install.sh` item selection, and opencode restricted-agent permission fixes.
- [`releases/6.0.0.md`](releases/6.0.0.md) covers native packages in the Claude, Codex, and Cursor marketplaces, and the installer's migration onto them (automatic since v6.3.0).
- [`releases/5.3.0.md`](releases/5.3.0.md) covers per-runtime worktree roots, `AGENTS.md` from `ycc:init`, and retired command wrappers.

Older notes stay in [`releases/`](releases/).

## PRP artifacts

Outputs from the PRP (Product Requirements / Plan / Review) commands:

- `prps/reviews/` — review artifacts produced by `/ycc:code-review` and
  `/ycc:quick-review` in local mode.
- `prps/reviews/fixes/` — fix reports produced by `/ycc:review-fix` in local mode.

In linear mode (the default), reviews and fix reports cache under
`.ycc/artifacts/<slug>/reviews/` and save as Linear Documents on the reviewed
issue or feature Project; they are never committed. `/ycc:pr-autofix` reports
stay local in both modes (`docs/prps/reports/` locally,
`.ycc/artifacts/<slug>/reports/` in linear mode).

In local mode, PRP plans and specs are written to `docs/prps/plans/` and `docs/prps/specs/`
on demand; those subdirectories appear once the corresponding command has
been run. Local filenames are `docs/prps/prds/<slug>.prd.md`,
`docs/prps/specs/<slug>.spec.md`, and `docs/prps/plans/<slug>.plan.md`.

## Planning artifacts

Planning skills store artifacts in Linear by default. Opt out with
`--store=local` or `store: local` in a repo `.plans-config` or the global
`~/.config/ycc/config`; local mode writes those local paths and needs no Linear
MCP. `/ycc:init --artifact-store` writes a committed root `.plans-config`
(`store: local` or `store: linear`) and, for linear, a `.ycc/artifacts/`
gitignore rule. In linear mode, skills cache under `.ycc/artifacts/<slug>/` and
save documents to Linear.

`ycc:implement-plan` and `ycc:prp-implement` read that cache in linear mode and
move the parent tracking issue and task issues through `started` and
`completed` as batches run. `ycc:orchestrate` does that only when its input is
a Linear issue reference. Local mode makes no Linear calls. The contract is
[`../ycc/skills/_shared/references/artifact-store.md`](../ycc/skills/_shared/references/artifact-store.md).

## Other

- [`pre-commit-recommendation.md`](pre-commit-recommendation.md) — guidance
  on the pre-commit hook policy used by this repo.

## Generated vs. source-of-truth

- `inventory.json` and the generated regions in the top-level `README.md` are
  **generated**. Edit the inputs (`ycc/` tree and the generator templates), then
  run `./scripts/sync.sh`.
- Everything else in this directory is hand-edited.

See [`../CONTRIBUTING.md`](../CONTRIBUTING.md) for the scope policy and
[`../CLAUDE.md`](../CLAUDE.md) for conventional commit rules — notably the
`docs(internal): …` prefix for anything under `docs/plans/`,
`docs/research/`, or `docs/internal/`.
