# Template Library

## Contents

- Template Catalog
- Placeholder Reference
- Conditional Blocks
- Notes

Every template the skill can render, its target path, and the variables it substitutes.

---

## Template Catalog

| Template file                                          | Output path                                    | Gating flag          | Placeholders used                                                                                                       |
| ------------------------------------------------------ | ---------------------------------------------- | -------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `templates/CLAUDE.md.tmpl`                             | `./CLAUDE.md` (`@AGENTS.md`)                   | Default shim         | `CLAUDE_MD_SHIM`, `CLAUDE_ONLY_NOTES`, `IF_CLAUDE_ONLY` block                                                           |
| `templates/AGENTS.md.tmpl`                             | `./AGENTS.md` (canonical)                      | _(default)_          | `PROJECT_NAME`, `PROJECT_PURPOSE`, `TEST_CMD`, `LINT_CMD`, `BUILD_CMD`, `PROJECT_CONVENTIONS`, `IF_RELEASE_MODEL` block |
| `templates/cursor-rule.mdc.tmpl`                       | `./.cursor/rules/<scope>.mdc`                  | path-scoped rules    | `RULE_DESCRIPTION`, `RULE_GLOBS`, `PATH_SPECIFIC_RULES`                                                                 |
| `templates/ai-rule.md.tmpl`                            | `./.ai/rules/project.md` (pointer)             | `--vendor-neutral`   | `PROJECT_NAME`                                                                                                          |
| `templates/github/bug_report.yml.tmpl`                 | `./.github/ISSUE_TEMPLATE/bug_report.yml`      | `--templates`        | `PROJECT_NAME`                                                                                                          |
| `templates/github/feature_request.yml.tmpl`            | `./.github/ISSUE_TEMPLATE/feature_request.yml` | `--templates`        | `PROJECT_NAME`                                                                                                          |
| `templates/github/docs_request.yml.tmpl`               | `./.github/ISSUE_TEMPLATE/docs_request.yml`    | `--templates`        | `PROJECT_NAME`                                                                                                          |
| `templates/github/config.yml.tmpl`                     | `./.github/ISSUE_TEMPLATE/config.yml`          | `--templates`        | `PROJECT_NAME`, `GITHUB_REPO_URL`                                                                                       |
| `templates/github/pull_request_template.md.tmpl`       | `./.github/pull_request_template.md`           | `--templates`        | `PROJECT_NAME`, `TEST_CMD`, `PRIMARY_LANG`                                                                              |
| `templates/github/labels.md.tmpl`                      | `./.github/labels.md`                          | `--templates`        | `PROJECT_NAME`, `IF_RELEASE_MODEL` block                                                                                |
| `templates/github/copilot-instructions.md.tmpl`        | `./.github/copilot-instructions.md`            | `--templates`        | `PROJECT_NAME`, `TEST_CMD`, `LINT_CMD`, `BUILD_CMD`                                                                     |
| `templates/github/workflows/pr-title.yml.tmpl`         | `./.github/workflows/pr-title.yml`             | `--templates`        | _(none — static template)_                                                                                              |
| `templates/github/workflows/pr-title-autofix.yml.tmpl` | `./.github/workflows/pr-title-autofix.yml`     | `--templates`        | _(none — static template)_                                                                                              |
| `templates/git/gitignore.tmpl`                         | `./.gitignore`                                 | `--git`              | `PROJECT_NAME` + `IF_RUST`/`IF_GO`/`IF_PYTHON`/`IF_TS`/`IF_TERRAFORM` language blocks                                   |
| `templates/git/gitmessage.tmpl`                        | `./.gitmessage`                                | `--git`              | _(none — static template)_                                                                                              |
| `templates/git/commitlint.config.cjs.tmpl`             | `./commitlint.config.cjs`                      | `--git` + JS/TS only | `PACKAGE_MANAGER`                                                                                                       |
| `templates/git/lefthook.yml.tmpl`                      | `./lefthook.yml`                               | `--git`              | `PROJECT_NAME`, `TEST_CMD` + `IF_RUST`/`IF_GO`/`IF_PYTHON`/`IF_TS` language blocks                                      |
| `templates/git/install-lefthook.sh.tmpl`               | `./scripts/install-lefthook.sh`                | `--git`              | `PROJECT_NAME`, `PACKAGE_MANAGER`                                                                                       |
| `templates/git/lefthook-usage.md.tmpl`                 | `./docs/lefthook-usage.md`                     | `--git`              | `PROJECT_NAME`, `PRIMARY_LANG`, `LINT_CMD`, `TEST_CMD`, `IF_TS` block                                                   |

---

The `templates/CLAUDE.md.tmpl` row combines three mechanisms in one Placeholders cell on purpose: `CLAUDE_MD_SHIM` is the canonical shim token rendered by the shared helper (`ycc/skills/_shared/scripts/rules_pointer.py` via `rules_pointer.py`), so the pointer line is not user-overridable policy; `CLAUDE_ONLY_NOTES` is user/Phase 2 text substituted into that same template; and `IF_CLAUDE_ONLY` is the conditional block that gates the notes section. All three are aspects of the single default `CLAUDE.md` shim, so they share one row.

## Placeholder Reference

Every `{{VAR}}` used across all templates:

| Placeholder                                             | Source                                      | Description                                                       |
| ------------------------------------------------------- | ------------------------------------------- | ----------------------------------------------------------------- |
| `PROJECT_NAME`                                          | `profile-project.sh` or user prompt         | Repository/project name (e.g., `my-app`)                          |
| `PROJECT_PURPOSE`                                       | `profile-project.sh` or user prompt         | One-sentence description of what the project does                 |
| `PRIMARY_LANG`                                          | `profile-project.sh` → `primary_language`   | Normalised language string (e.g., `rust`, `typescript`)           |
| `TEST_CMD`                                              | `profile-project.sh` → `test_cmd`           | Command to run the test suite (e.g., `cargo test`)                |
| `LINT_CMD`                                              | `profile-project.sh` → `lint_cmd`           | Command to run linting (e.g., `cargo clippy`)                     |
| `BUILD_CMD`                                             | `profile-project.sh` → `build_cmd`          | Command to build the project (e.g., `go build ./...`)             |
| `PACKAGE_MANAGER`                                       | `profile-project.sh` → `package_manager`    | Package manager name (e.g., `pnpm`, `uv`, `cargo`)                |
| `PROJECT_CONVENTIONS`                                   | Existing docs / Phase 2 / user              | Verified project-specific constraints, not generic language rules |
| `CLAUDE_ONLY_NOTES`                                     | Phase 2 / user                              | Short Claude-only notes (keep total file ≤15 lines)               |
| `RULE_DESCRIPTION`, `RULE_GLOBS`, `PATH_SPECIFIC_RULES` | Phase 2 / user                              | Narrow Cursor rule metadata/body, never a project-wide copy       |
| `RULES_FILES_LINES`                                     | Phase 7                                     | Actual line counts with >200 warning                              |
| `GITHUB_REPO_URL`                                       | `profile-project.sh` (git remote) or prompt | Full GitHub URL (e.g., `https://github.com/org/repo`)             |

---

## Conditional Blocks

`{{#NAME}}…{{/NAME}}` keeps its contents when the condition holds and is removed entirely
otherwise.

| Block                                                    | Kept when                                                                                                                                              | Used in                                                                              |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| `IF_RUST`, `IF_TS`, `IF_GO`, `IF_PYTHON`, `IF_TERRAFORM` | The block's language matches `primary_language` (all of `secondary_languages` too for `gitignore.tmpl`)                                                | Most templates                                                                       |
| `IF_RELEASE_MODEL`                                       | `RELEASING.md` exists at the project root after Phase 5.5 — already present (`has_releasing_md=true`) or created by `ycc:release-model` in this run    | `AGENTS.md.tmpl`, `github/labels.md.tmpl`                                            |
| `IF_ARTIFACT_STORE`                                      | Phase 5.6 succeeds with effective choice linear, or the root pointer was already linear and tracked; failed setup or an explicit local choice drops it | `AGENTS.md.tmpl` (`## Planning artifacts`), `git/gitignore.tmpl` (`.ycc/artifacts/`) |
| `IF_CLAUDE_ONLY`                                         | Claude-specific content exists (Phase 2 or user-supplied) — otherwise only the `@AGENTS.md` shim remains                                               | `CLAUDE.md.tmpl`                                                                     |

`IF_RELEASE_MODEL` is resolved in Phase 5.5, after `ycc:release-model` has had its chance
to run, so the `## Branching & releases` pointer and the `backport:X.Y` label family never
reference a `RELEASING.md` that does not exist. Under `--dry-run` it is kept when
`has_releasing_md=true` or `--release-model` was passed.

`IF_ARTIFACT_STORE` is resolved in Phase 5.6: keep it only after a successful helper run
with effective choice linear, or when the root `.plans-config` was already linear and
tracked. A failed helper/MCP run drops it even if a pointer remains on disk.
`render-template` does not compute it: pass `--keep IF_ARTIFACT_STORE` for both templates.
Under `--dry-run`, keep it only when the effective choice is linear: the root pointer is
already linear and tracked, or `--artifact-store` / `--artifact-store=linear` was passed;
an explicit `--artifact-store=local` always drops it. Phase 5 performs read-only Gather
before a helper preview; unresolved values are shown as placeholders, not passed to it.

---

## Notes

- **Default templates** (no flag required) are always rendered unless `--docs-only` skips
  MCP/agent selection. Only `AGENTS.md` is always
  part of the default run. `CLAUDE.md` is a default one-line compatibility shim; omit only with `--no-claude-md` (Claude Code 2.1.277+). Claude-specific content adds a short section; `.cursor/rules/*.mdc` only for path-scoped rules (never an always-apply copy of `AGENTS.md`).
- **Existing file handling**: without `--force`, the skill diffs and prompts before
  overwriting any pre-existing target. Missing sections may be appended safely to
  existing `AGENTS.md`; a long existing `CLAUDE.md` is never rewritten — `--migrate-rules`
  moves its content into `AGENTS.md` with a dry-run diff first.
- **JS/TS gating**: `commitlint.config.cjs` is only rendered when `PRIMARY_LANG` is
  `typescript` or `javascript` (detected from `package.json` presence). The
  `lefthook.yml` and `lefthook-usage.md` templates include a `commit-msg`
  commitlint block gated by the same `{{#IF_TS}}` conditional.
- **Gitignore multi-language**: unlike other templates, `.gitignore` activates every
  language block matching `primary_language` **or** any entry in `secondary_languages`.
  A Rust+TS monorepo gets both sections; the universal OS/editor/secrets sections are
  always included. Follows the standard diff-and-skip update rule — `--update --force`
  overwrites.
- **Lefthook scaffold**: `lefthook.yml` + `scripts/install-lefthook.sh` +
  `docs/lefthook-usage.md` are emitted together under `--git`. The install
  script is always overwritten (managed tooling); `lefthook.yml` follows the
  standard diff-and-ask rule so user edits are preserved.
- **Agent-facing PR guardrails**: `copilot-instructions.md`,
  `workflows/pr-title.yml`, and `workflows/pr-title-autofix.yml` ship
  together under `--templates`. The validator enforces Conventional Commits
  title rules — agents that open a PR with `[WIP]` / `Draft:` / `Initial
plan` in the title get a failing required check, not a silent merge. The
  autofix workflow runs in parallel and strips those placeholder prefixes
  server-side because GitHub Copilot's coding-agent token often lacks
  `pull_requests:write` and cannot self-correct after the instructions file
  has been ignored. Only the validator should be a required status check;
  the autofix is a corrective side effect. All three files follow
  diff-and-skip update semantics.

---

## Helper contract

Helpers require Python 3.11+ (shell entrypoints work with Bash 3.2). The renderer
accepts only the bundled `templates/` tree (including symlink resolution), takes
profiles from readable files or stdin (`--profile -`, or a pipe), normalises CRLF,
and validates matching nested block names. Mixed profiles keep every component
language. `IF_TEST_CMD`, `IF_LINT_CMD`, `IF_BUILD_CMD` guard command-bearing YAML and
checklists; inverse `IF_NO_*_CMD` blocks explain skipped hooks. No detected test
command means no pre-push hook, never YAML `run: # not detected`.

`rules-report.sh --repo <root>` fills `RULES_FILES_LINES` from actual file counts and
prints a warning above 200 lines. The report itself is authored from the workspace
report template (not parsed as Handlebars by the helper).
