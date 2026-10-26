# Contributing

## Developer Setup

This repo uses [lefthook](https://github.com/evilmartians/lefthook) for git hooks and
[commitlint](https://commitlint.js.org/) to enforce Conventional Commits at
`commit-msg` time.

```bash
# One-time setup (installs lefthook + commitlint deps, wires .git/hooks/)
./scripts/install-lefthook.sh

# OR: let the npm 'prepare' script run lefthook install for you
npm install
```

What the hooks do:

| Stage        | Command                                                                                            | Purpose                                                          |
| ------------ | -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `pre-commit` | `scripts/lint.sh --staged --fix --python --shell` and `scripts/format.sh --staged --python --docs` | Lint staged Python and shell. Format staged Python and Markdown. |
| `pre-push`   | `scripts/validate.sh --changed`                                                                    | Validators the unpushed changes affect                           |
| `commit-msg` | `commitlint --edit`                                                                                | Reject non-conventional commit messages                          |

`--changed` maps the files changed since the branch's push destination to validate
targets (rules in `scripts/lib/validate-scope.sh`; unrecognised paths run everything),
so a docs-only push runs nothing and CI remains the full check. Run
`./scripts/validate.sh` for the complete local pass. CI runs `npm run lint` before
`./scripts/validate.sh`. `npm run lint` checks Python, shell, and Markdown with
markdownlint and prettier. The pre-commit hook formats Markdown with prettier and
does not run markdownlint.

Bypass a single operation with `git commit --no-verify` or `git push --no-verify`.
CI is exempt automatically (`CI=true`).

### Migrating from the old `pre-commit` framework

Earlier versions of this repo used the Python `pre-commit` framework via
`.pre-commit-config.yaml`. If your local clone still has it wired, clean up before
running `install-lefthook.sh`:

```bash
pre-commit uninstall
# then:
./scripts/install-lefthook.sh
```

### Claude hooks symlink

`~/.claude/settings.json` is already symlinked to `ycc/settings/settings.json` in this
repo. The `WorktreeCreate` hook registered in that file points to
`~/.claude/hooks/worktree-create.sh`, so you must also expose the hooks directory:

```bash
ln -s "$(pwd)/ycc/settings/hooks" ~/.claude/hooks
```

Run this once from the repo root. After that, Claude Code will invoke
`ycc/settings/hooks/worktree-create.sh` whenever it would otherwise create a worktree
under `<repo>/.claude/worktrees/`, keeping it in that harness-managed root.
Worktree creation requires the symlink above; without it, worktree creation
fails with no fallback to default creation.
See the Worktrees section of `ycc/settings/rules/CLAUDE.md` for placement policy.

## Repository Model

This repo ships the `ycc` Claude Code plugin — dev-focused workflows under `ycc/`,
cross-generated to Cursor, Codex, and opencode. New functionality goes into `ycc/`
as a new skill or agent. **New top-level plugins in this repo require
PRD approval** — see Scope & Guardrails below for the decision gate.

> **Related**: the consulting / systems-integration toolkit (`yci`) lives in the
> sibling repo [`yandy-r/claude-infra-plugins`](https://github.com/yandy-r/claude-infra-plugins).
> That split (2026-04) is the reference precedent for when scope belongs in a
> separate repo rather than accumulated here.

## Scope & Guardrails

New bundle additions are evaluated against written policy, not memory. These rules come from
`research/plugin-additions/report.md` and apply to every proposal for a new skill
or agent.

- **Do not add another wave of narrow expert skills.** The bundle already ships broad
  coverage; the current bottleneck is maintenance integrity (drift, inventory accuracy,
  generator sync), not missing subjects. Breadth additions without evidence are rejected.
- **Do not create a new top-level plugin without an approved PRD.** The Claude
  marketplace lists `ycc`, `ycc-mcp`, `ycc-hooks`, and `ycc-all`. A plugin outside
  that set requires a PRD at
  `docs/prps/prds/<name>.prd.md` that answers: problem statement, audience and threat
  model, non-goals, phased rollout, success criteria, and the "why this can't live inside
  `ycc` or a sibling repo" argument. The `yci` → `claude-infra-plugins` split is the
  reference precedent: when scope cannot coexist with `ycc` without harming it
  (cross-contamination, descriptor pollution, fragility-cliff proximity), prefer a
  sibling repo over a second plugin here. An unjustified new `marketplace.json` entry
  is rejected by policy.
- **Do not market hooks as uniform across targets.** Claude, Cursor, Codex, and opencode each
  have different hook support and maturity. Any hook-related addition must ship with a
  per-target support matrix.
- **Meta-skills and internal optimizations precede new domain coverage.** Authoring
  workflows, release workflows, compatibility audits, validator CI, and source-driven
  inventory come before any new subject-matter skill.

### Proposing New Capabilities

Before opening a PR for a new skill or agent, answer each question below. If any
answer points elsewhere, revise the proposal before writing code.

- Could this extend an existing skill (a new phase, flag, or reference file) instead of
  becoming a new one?
- Does this belong in `ycc`? If yes, add it under `ycc/skills/` or `ycc/agents/`.
- Does this belong in a sibling repo (e.g., consulting/SI scope → `claude-infra-plugins`)?
  If yes, PR it there.
- Would this require a NEW top-level plugin and a new `marketplace.json` entry in this
  repo? If yes, stop and open a PRD first. Without PRD approval the entry is rejected
  by policy.
- Has a higher-priority meta-skill or drift fix been scheduled first?
- For hook-related work: does the proposal include a per-target support matrix?

See also: [`ycc/skills/bundle-author/references/when-not-to-scaffold.md`](ycc/skills/bundle-author/references/when-not-to-scaffold.md)
for the skill-author-facing anti-patterns (duplication, one-off tasks, shared-logic
misplacement, agents without consumers, etc.) that complement this policy.

### Maintainer-only workflows

Three workflows are maintainer-only for this repo's layout — `bundle-author`,
`bundle-release`, and `compatibility-audit` (their descriptions carry a
"Maintainer-only (ycc repo)" prefix). They operate on this repo's `ycc/`
source-of-truth layout and are not general-purpose tooling. They are still
shipped in the single `ycc` plugin (not excluded from generated targets):
`bundle-release` backs the release flow in RELEASING.md, and the other two
stay for single-plugin parity rather than because scripts import them.

### Repository rename tooling

`scripts/rename-repo.sh` rewrites repository references: run it with
`--from <owner>/<repo> --to <owner>/<repo> --dry-run` to print the full diff of
anchored remote references it would change; rerun without `--dry-run` to apply
those edits. It touches only the hand-maintained source files listed in
`scripts/rename_repo.py` (`ALLOWLIST_FILES`) — never generated bundles, local
filesystem paths, worktrees, or plugin identities — and it does not rename the
hosting repos, update remotes, or run sync. Regenerate bundles with
`./scripts/sync.sh` after applying a reference flip.

Codex migration recognizes the exact pre-rename repo-mode catalog entry as
installer-owned alongside the current entry. Its historical URL in
`scripts/install_migrate.py` is intentionally outside the rename allowlist;
edited and foreign catalog entries remain preserved.

## Structure Requirements

- Claude source plugin manifest: `ycc/.claude-plugin/plugin.json`
- Claude marketplace: `.claude-plugin/marketplace.json` (`ycc`, `ycc-mcp`, `ycc-hooks`, `ycc-all`)
- Codex generated plugin root: `.codex-plugin/ycc/`
- Codex generated custom agents: `.codex-plugin/agents/`
- Cursor generated packages: `packages/cursor/{ycc,ycc-rules,ycc-mcp,ycc-hooks}/` (all listed in the root `.cursor-plugin/marketplace.json`)
- Cursor file-copy settings input: `packages/cursor/installer-fallback/config/cli-config.json`, generated from `ycc/settings/cursor/cli-config.json`
- opencode generated bundle: `.opencode-plugin/` (skills, agents, commands, AGENTS.md, opencode.json)
- OMP generated packages: `packages/omp/ycc/` with `{skills,agents,commands}/`, `packages/omp/ycc-mcp/` with `.mcp.json` (a byte copy of `mcp-configs/mcp.json`) and `packages/omp/ycc-rules/` with flat `rules/ycc-<family>-<stem>.md` (from `ycc/rules/` via `scripts/generate_omp_rules.py`), each with `.omp-plugin/plugin.json`, `.claude-plugin/plugin.json` and `package.json`; the root `.omp-plugin/marketplace.json` lists `ycc`, `ycc-mcp`, and `ycc-rules`. `install.sh install --target omp` (`scripts/omp_install.py`) exports the packages to a local `ycc` marketplace (`--mode local`, the default) or registers the repository catalog (`--mode repo`) and installs them through `omp plugin`; opt-in `--settings` and `--rules` merge `ycc/settings/omp/config.yml` and link `AGENTS.md` at user scope ([`docs/install/omp.md`](docs/install/omp.md))
- ycc ships no OMP hooks (`ycc-hooks` is excluded on OMP; herdr ships its own OMP integration); the only OMP code is the ycc agent scope guard (`scripts/omp_templates/scope-guard.ts`, tested by `scripts/test_omp_scope_guard.py`). `validate_omp_native.py` rejects any other OMP code surface and checks the hook verdict table.
- Skills go in `ycc/skills/<skill-name>/SKILL.md`
- Scripts must be executable (`chmod +x`) and use `set -euo pipefail`
- Reference templates go in `ycc/skills/<skill-name>/references/`

## Naming Conventions

- Directories and files: `kebab-case`
- Public skills are slash-invocable by skill name (e.g., skill `git-workflow` -> `/ycc:git-workflow`)

## Skills and Slash Commands

Public skills under `ycc/skills/<name>/SKILL.md` are native Claude slash invocations
(`/ycc:<name>`). Skill frontmatter controls visibility and invocation:

- `user-invocable: false` hides passive guidance from the slash menu. Use it for
  skills the model reads when relevant, never typed by users.
- `disable-model-invocation: true` keeps a skill user-invocable but prevents the
  model from selecting it automatically. Use it for destructive, release, or
  maintainer workflows. It is separate from `user-invocable`. Skills that another
  model-invocable skill genuinely hands off to must stay model-invocable. The
  value must be a YAML boolean; quoted strings fail validation.
- `argument-hint` and `allowed-tools` are native skill frontmatter keys. Set them
  on the skill itself.
- Wrapper files under `ycc/commands/` are retired. Do not add new ones. The
  `command` key and the `command: false` opt-out no longer exist.

`scripts/validate-ycc-skills.sh` (wired into `./scripts/validate.sh`) enforces this:
it checks frontmatter, boolean keys, the absence of a legacy `command` key, and that
`ycc/commands/` does not exist. The `bundle-author` skill scaffolds a skill with
`user-invocable: false` when you pass `--skill-only`.

### Cross-target implications

Claude Code invokes public skills directly. opencode still gets native slash commands:
`scripts/generate_opencode_commands.py` emits one thin command per public skill into
`.opencode-plugin/commands/`, sourced from that skill's `SKILL.md` frontmatter. Each
command loads the skill through the opencode `skill` tool and forwards `$ARGUMENTS`.
This exists only so commands-only installs keep working; it does not make slash
commands a general feature. Manual-only skills still get these commands because
the user may invoke them. Policy mapping: Cursor keeps `disable-model-invocation`;
Codex writes `agents/openai.yaml` with `policy.allow_implicit_invocation: false`;
opencode writes skill metadata `opencode/autoinvoke: 'false'`; the portable
`agents` bundle omits it (no standard key). Cursor's native `ycc` package derives
command files from user-invocable skills; the file-copy installer's `commands` intent
installs owned wrappers into `~/.cursor/commands/`, and its optional `hooks` intent
installs the `sessionStart` hook only. Native Cursor install is interactive (`/plugins`).
Codex has no command layer. See
`ycc/skills/_shared/references/target-capability-matrix.md` for the full matrix.

## Regeneration

After changing `ycc/skills/` or `ycc/agents/`, regenerate and validate
the compatibility bundles.

### Adding, Renaming, or Removing Agents

Every agent under `ycc/agents/*.md` (plus built-in `general` and `explore`) must have an
explicit model entry in `ycc/settings/models.json` under `targets.opencode.agents`.
Generated `.opencode-plugin/agents/*.md` stay model-free; `.opencode-plugin/opencode.json`
owns per-agent model assignment.

When adding, renaming, or removing an agent:

1. Update `ycc/settings/models.json` under `targets.opencode.agents` to assign the new/renamed agent ID to a full `provider/model` reference based on intended capability tier.
2. Run `./scripts/sync.sh` (or `./scripts/sync.sh --only opencode`).
3. Run `./scripts/validate.sh` (or `./scripts/validate.sh --only opencode`).

The generator (`scripts/generate_opencode_plugin.py`) fails fast if any agent is missing or stale.

The OMP agent generator (`scripts/generate_omp_agents.py`) also fails fast: agent frontmatter may
use only `name`, `description`, `tools`, `model` and `color`. Every tool needs an OMP mapping in
its `TOOL_MAP` (or `Bash(<cmd>:*)`, or an `mcp__<server>__*` server from `mcp-configs/mcp.json`),
and `model` must be `opus`, `sonnet` or `inherit`.

#### OpenCode Capability Tiers (Sample Policy)

These values are sample placeholders (`placeholder: true` in `models.json`); users map them to models available on their configured providers by capability and cost.

| Tier                              | Sample Model           | Intended Roles / Agents                                                                                                                                                                                                                                          |
| --------------------------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Deep Architecture & High-Risk** | `openai/gpt-6-astra`   | Complex system design, database mutation, deep debugging (`architect`, `code-architect`, `root-cause-analyzer`, `db-modifier`, `go-expert-architect`, `rust-expert-architect`)                                                                                   |
| **Docs, Lookup & Routine**        | `openai/gpt-5.6-terra` | Documentation authoring, code search, routine cleanup (`docs-git-committer`, `code-finder`, `api-documenter`, `code-documenter`, `documentation-writer`, `feature-writer`, `readme-generator`, `library-docs-writer`, `api-docs-expert`, `project-file-cleaner`) |
| **General Development**           | `openai/gpt-5.6-sol`   | All other implementation, review, and specialty agents (`implementor`, `code-reviewer`, `typescript-developer`, `python-developer`, built-ins `general`/`explore`, etc.)                                                                                         |

```bash
./scripts/sync.sh         # regenerate every Cursor / Codex / opencode / OMP bundle
./scripts/validate.sh     # run every validator (this is what CI runs)
```

Both accept `--only <targets>` with comma-separated values (`inventory, cursor, codex,
opencode, omp, json`). The individual generator/validator scripts are still available if you
need to target a single surface:

```bash
# Codex
./scripts/generate-codex-skills.sh && ./scripts/validate-codex-skills.sh
./scripts/generate-codex-agents.sh && ./scripts/validate-codex-agents.sh
./scripts/generate-codex-plugin.sh && ./scripts/validate-codex-plugin.sh

# Cursor
./scripts/generate-cursor-packages.sh && ./scripts/validate-cursor-packages.sh
./scripts/generate-cursor-skills.sh && ./scripts/validate-cursor-skills.sh
./scripts/generate-cursor-agents.sh && ./scripts/validate-cursor-agents.sh
./scripts/generate-cursor-rules.sh  && ./scripts/validate-cursor-rules.sh

# opencode
./scripts/generate-opencode-skills.sh   && ./scripts/validate-opencode-skills.sh
./scripts/generate-opencode-agents.sh   && ./scripts/validate-opencode-agents.sh
./scripts/generate-opencode-commands.sh && ./scripts/validate-opencode-commands.sh
./scripts/generate-opencode-plugin.sh   && ./scripts/validate-opencode-plugin.sh

# OMP (oh-my-pi)
./scripts/generate-omp-skills.sh && ./scripts/validate-omp-skills.sh
./scripts/generate-omp-agents.sh && ./scripts/validate-omp-agents.sh
./scripts/generate-omp-commands.sh && ./scripts/validate-omp-commands.sh
./scripts/generate-omp-packages.sh && ./scripts/validate-omp-packages.sh  # manifests + catalog; run last
bash scripts/test-omp-native-packages.sh  # live install; also runs in .github/workflows/omp-live.yml (Linux and macOS)
bash scripts/test-omp-herdr-hooks.sh     # local herdr proof; not in CI (needs a herdr binary)
```

## Plugin evals

`ycc/evals/` holds `claude plugin eval` cases: a **trigger** suite (does the
right skill load for a prompt?) and a **behavior** suite (hard gates such as
"plan edits nothing before confirmation"). Runs are real model calls, so they
are **not** part of CI or `./scripts/validate.sh`. Run them locally:

```bash
./scripts/eval.sh                              # both suites, one run per case, $8 ceiling
./scripts/eval.sh --suite trigger              # trigger cases only
./scripts/eval.sh --case 'plan-*' --max-cost-usd 8
```

`scripts/eval.sh` skips with a notice when `claude` is not on `PATH`, enforces
`--max-cost-usd` (default `8`) and exits non-zero on any failing case. Requires
Claude Code ≥ 2.1.269. Layout, grader rules, and the follow-up list live in
[`ycc/evals/README.md`](ycc/evals/README.md).

**New skills ship with 3 eval cases** (2 should-trigger prompts + 1 near-miss).
Manual-only skills use two no-autoinvoke policy cases instead of should-trigger
prompts; behavior cases are additional, not replacements.
skills with hard gates add a behavior case. The `bundle-author` skill scaffolds
this requirement.

## Pull Requests

- Include a description of the source change and any regenerated compatibility artifacts
- Ensure relevant marketplace/manifests are updated when generators change them
