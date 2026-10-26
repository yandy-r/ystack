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

- [`install/README.md`](install/README.md) — shared installer concepts and target matrix.
- [`install/claude.md`](install/claude.md) — Claude Code plus Claude Desktop MCP setup.
- [`install/codex.md`](install/codex.md) — Codex plugin, custom agents, and Codex Desktop setup.
- [`install/cursor.md`](install/cursor.md) — Cursor-native bundle sync and MCP setup.
- [`install/opencode.md`](install/opencode.md) — opencode-native skills, agents, commands, config, and rules.
- [`install/omp.md`](install/omp.md) — OMP (oh-my-pi) native packages, `install.sh --target omp`, and platform limits.

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
- [`releases/6.0.0.md`](releases/6.0.0.md) covers native packages in the Claude, Codex, and Cursor marketplaces, and `install.sh migrate`.
- [`releases/5.3.0.md`](releases/5.3.0.md) covers per-runtime worktree roots, `AGENTS.md` from `ycc:init`, and retired command wrappers.

Older notes stay in [`releases/`](releases/).

## PRP artifacts

Outputs from the PRP (Product Requirements / Plan / Review) commands:

- `prps/reviews/` — review artifacts produced by `/ycc:code-review`.
- `prps/reviews/fixes/` — fix reports produced by `/ycc:review-fix`.

PRP plans and specs are written to `docs/prps/plans/` and `docs/prps/specs/`
on demand; those subdirectories appear once the corresponding command has
been run.

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
