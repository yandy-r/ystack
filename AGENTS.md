# ystack — Agent Rules

This repository ships the `ycc` development-workflow bundle: planning, implementation,
git, research, docs, and orchestration. The Claude-facing `ycc/` tree is the source;
other runtime bundles are generated from it. Keep the plugin name `ycc` stable.

## Canonical policy

- This file is the canonical, tool-neutral repository policy. Claude imports it through
  `CLAUDE.md`; Codex and opencode read `AGENTS.md` natively, and Cursor reads it
  when available; Cursor user rules are settings-configured.
- Keep this file ≤150 lines and `CLAUDE.md` ≤40 lines. Put only Claude-specific notes in
  `CLAUDE.md`, and path-specific Claude guidance in `.claude/rules/` with `paths:` frontmatter.
- Use HTML block comments (`<!-- -->`) for maintainer notes, not injected instructions.
- Prefer a fitting MCP server; read its tool schema before calling it.
- Follow [CONTRIBUTING.md](CONTRIBUTING.md) for scope/guardrails and contributor details.

## Source and generated targets

- Add workflow logic under `ycc/`, not generated bundles. Do not hand-edit generated
  `.codex-plugin/`, `.opencode-plugin/`, `.omp-plugin/`, `.agents-plugin/`, `packages/claude/`,
  `packages/cursor/`, or `packages/omp/` files; change their source/generator, then regenerate.
- Do not add top-level workflow plugins. Extend `ycc` or use the sibling-repo decision
  gate in `CONTRIBUTING.md`. Claude-only mods are the documented exception in `CLAUDE.md`.
- Skills use `kebab-case` directories under `ycc/skills/`; agents use `kebab-case.md`
  under `ycc/agents/`. Keep shared helpers in `ycc/skills/_shared/scripts/`.
- When adding, renaming, or removing an agent, update `ycc/settings/models.json` under
  `targets.opencode.agents`. Assign an appropriate capability/cost tier using a full
  `provider/model` reference; sample model IDs are placeholders, not provider guarantees.
  The opencode generator fails fast on missing agents; validate the model policy too.
- Shell helpers use `kebab-case.sh`, Bash with strict error handling and input guards;
  Python public APIs need type hints. Detailed script guidance is in `.claude/rules/scripts.md`.

The capability contract is `ycc/skills/_shared/references/target-capability-matrix.md`;
this table records install ownership, not a claim of runtime feature parity:

| Target                 | Generated / managed surface                                                                        | User install destination                                                                         |
| ---------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Cursor file copy       | `packages/cursor/`: `ycc/{skills,agents,commands}`, `ycc-rules/rules`, `installer-fallback/config` | `~/.cursor/` via unchanged installer                                                             |
| Codex                  | `.codex-plugin/ycc/`; `.codex-plugin/agents/`                                                      | `~/.codex/plugins/ycc`; custom agents under `~/.codex/agents/`                                   |
| Codex marketplace      | User marketplace managed by Codex target                                                           | `~/.agents/plugins/marketplace.json`                                                             |
| opencode               | `.opencode-plugin/skills/`, `agents/`, `commands/`                                                 | Matching directories under `~/.config/opencode/`                                                 |
| opencode settings      | `.opencode-plugin/opencode.json`, `AGENTS.md`                                                      | `~/.config/opencode/` via `install.sh install --target opencode --settings --global`             |
| Cross-tool `agents`    | `.agents-plugin/skills/`, `ycc-shared/`                                                            | `~/.agents/skills/`, `~/.agents/ycc-shared/`                                                     |
| Claude native add-ons  | `packages/claude/` MCP, hooks, dependency bundle                                                   | Listed in root `.claude-plugin/marketplace.json`; `install.sh migrate` dedupes                   |
| Cursor native packages | `packages/cursor/{ycc,ycc-rules,ycc-mcp,ycc-hooks}/`                                               | Listed in root `.cursor-plugin/marketplace.json`; file-copy installer remains                    |
| OMP native packages    | `packages/omp/{ycc,ycc-mcp,ycc-rules}/`; listed in root `.omp-plugin/marketplace.json`             | `omp plugin install <pkg>@ycc`, or `install.sh install --target omp` (user or `--project` scope) |

- The `agents` target is skills-only; never write `~/.agents/plugins/` (owned by Codex).
- Project rules here are not user-global plugin rules. opencode's generated `AGENTS.md`
  comes from `ycc/settings/rules/CLAUDE.md`, never this repository's root rules.

## Testing Changes

- After changing `ycc/skills/` or `ycc/agents/`, run both before declaring done:
  `./scripts/sync.sh` (regenerate all bundles) and `./scripts/validate.sh` (CI validators).
- For other generated sources/generators, regenerate their affected targets and validate
  them; scoped runs are for iteration, not a substitute for required final checks.
- For `ycc/` changes, validate `.claude-plugin/marketplace.json` and
  `ycc/.claude-plugin/plugin.json` with `python3 -m json.tool`, check plugin-root references
  resolve, and ensure shell helpers remain executable. Test changed skills/agents live in
  the relevant runtime when permitted; report skipped runtime checks honestly.
- There is no `npm test` or npm build target. Validation lives in `scripts/validate.sh`;
  run the relevant `scripts/test_*` / `scripts/test-*` suites for changed behavior.

| Command                                                       | Purpose                                                             |
| ------------------------------------------------------------- | ------------------------------------------------------------------- |
| `./scripts/sync.sh`                                           | Regenerate compatibility bundles and inventory                      |
| `./scripts/validate.sh`                                       | Run every validate.sh target. CI runs it after `npm run lint`.      |
| `./scripts/sync.sh --only claude`                             | Regenerate native Claude packages                                   |
| `./scripts/validate.sh --only claude,claude-native,packages`  | Generator, native policy, parity, optional CLI validation           |
| `./scripts/sync.sh --only cursor`                             | Regenerate native Cursor packages and file-copy inputs              |
| `./scripts/validate.sh --only cursor,cursor-native,packages`  | Cursor content, generator, native policy fixtures, parity           |
| `./scripts/validate.sh --only codex,codex-native,packages`    | Codex content, native export, policy fixtures, parity               |
| `./scripts/sync.sh --only omp`                                | Regenerate OMP skills, agents, commands, manifests (`packages/omp`) |
| `./scripts/validate.sh --only omp`                            | OMP drift, policy, catalog/lockstep/closure, golden tests           |
| `./scripts/validate.sh --only practices`                      | Authoring ratchet, including `.claude/rules` `paths` frontmatter    |
| `./scripts/validate.sh --only types`                          | `mypy --strict` over pyproject.toml `[tool.mypy]` files             |
| `python3 scripts/test_validate_practices.py`                  | Authoring-validator regression tests                                |
| `./scripts/install-shellcheck.sh`                             | Install the pinned ShellCheck matching CI                           |
| `npm run lint` / `npm run lint:modified` / `npm run lint:fix` | Python, shell, and Markdown lint / changed files / fixes            |
| `npm run format` / `npm run format:modified`                  | Python + docs formatting / changed files                            |

## MUST / MUST NOT

- **Secrets**: Never commit `.env`, `.env.encrypted`, tokens, or API keys.
- **Issues**: Use YAML form templates under `.github/ISSUE_TEMPLATE/` when present.
  Never create title-only or template-bypass issues. If CLI forms fail, mirror the
  form fields via tooling/API and apply the correct taxonomy labels.
- **Pull requests**: Follow `.github/pull_request_template.md`, link the issue
  (`Closes #…`), and label using `.github/labels.md` (`type:`, `area:`, `priority:`,
  `status:`). Never invent ad-hoc labels.
- **Commits**: Use Conventional Commits 1.0.0 (`feat|fix|docs|refactor|perf|test|build|ci|chore(scope): …`).
  Files under `docs/plans`, `docs/research`, or `docs/internal` must use `docs(internal): …`.
  Prefer `chore(…): …` for other non-user-facing churn.
- **Modularity & reuse**: Decompose into small, cohesive units with minimal cross-module
  coupling. Avoid copy-paste duplication; extract shared logic into `ycc/skills/_shared/`.

## Worktrees

- Default to a git worktree for non-trivial work.
- Every runtime creates worktrees inside the repository, under its own root
  (details in `ycc/skills/_shared/references/worktree-strategy.md`):

  | Agent    | Worktree root                      |
  | -------- | ---------------------------------- |
  | Claude   | `<repo-root>/.claude/worktrees/`   |
  | opencode | `<repo-root>/.opencode/worktrees/` |
  | Codex    | `<repo-root>/.codex/worktrees/`    |
  | Cursor   | `<repo-root>/.cursor/worktrees/`   |
  | OMP      | `<repo-root>/.omp/worktrees/`      |

- Each worktree is named `<repo>-<branch-or-feature>/`; the out-of-repo
  `~/.claude-worktrees/` rule is retired (legacy worktrees are left in place).
- `YCC_WORKTREE_ROOT` overrides the root; keep the active root gitignored.

## Branching & releases

[`RELEASING.md`](RELEASING.md) is the source of truth for branches and releases. Branch
off `main` and PR back into it; every release is tagged from `main`. Never merge one
long-lived branch into another to sync it.

- Decide the target release before branching. Preserve the machine-readable release
  state and its generated table; update them with the release-state helper, not by hand.
- Only maintainers cut releases; agents never tag. Follow the release preparation and
  publication workflow in `RELEASING.md`.
