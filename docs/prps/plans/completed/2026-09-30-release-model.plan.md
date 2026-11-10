# Release Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a repo-root `RELEASING.md` the source of truth for a project's trunk,
maintenance branches and release steps, generate it with a new `ycc:release-model`
skill, and make the branch/PR/release/cleanup skills follow it automatically.

**Architecture:** One machine-readable state block inside `RELEASING.md`, read by one
shared bash parser (`release-state.sh`) and written by one shared updater
(`release-state-update.sh`). Skills consume key=value output from the parser and fall
back to today's behavior when `present=0`. Two new skills (`release-model`, `backport`)
plus targeted edits to existing skills.

**Tech Stack:** Bash (`set -euo pipefail`, shellcheck-clean), Markdown skills, the repo's
Python generators (`scripts/sync.sh`) and validators (`scripts/validate.sh`).

**Spec:** `docs/prps/specs/2026-09-30-release-model-design.md`

## Global Constraints

- Scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`; stdout for results,
  stderr for errors; exit 0 success, 1 error, 2 malformed state (parser only); executable bit set.
- Shared helpers live in `ycc/skills/_shared/scripts/`, referenced as
  `${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/<name>.sh`.
- Never hand-edit `.cursor-plugin/`, `.codex-plugin/`, `.opencode-plugin/`, `docs/inventory.json`;
  regenerate with `./scripts/sync.sh`, then `./scripts/validate.sh` must pass.
- Every new skill has a paired `ycc/commands/<name>.md`; every new agent has an entry in
  `ycc/settings/models.json` under `targets.opencode.agents`.
- Missing `RELEASING.md` never blocks any skill; a malformed state block stops readers with
  the parse error and `/ycc:release-model --audit`.
- Agents never tag, publish, or push to `release/*` directly.
- Conventional Commits; files ~500 lines soft cap; do not bump `ycc/.claude-plugin/plugin.json`
  except in the final `ycc:bundle-release` step.
- Worktrees under `~/.claude-worktrees/claude-plugins-<branch>/`; run
  `pnpm install --frozen-lockfile` in each new worktree before committing (the pre-commit
  hook needs the pinned prettier).
- One PR per phase into `main`, linked to the tracking issue, labelled from the repo taxonomy.

## Review Focus

1. A `RELEASING.md` with no state block (hand-written, e.g. 9router's before migration):
   treated as `present=1` with a clear "no ycc state block" error (exit 2), not silently
   as missing — tested in Task 1.2.
2. CRLF line endings or trailing spaces in the state block: parsed identically — tested in Task 1.2.
3. A repo with no `origin` remote or no `origin/HEAD`: `release-state.sh base` still prints
   a branch (the state trunk, or `main`) and never errors — tested in Task 1.2.
4. `release-state-update.sh` on a file with human prose after the table: prose byte-identical
   after the rewrite — tested in Task 1.3.
5. `prepare-feature-branch.sh` in a repo with `RELEASING.md` but the trunk not fetched
   (`origin/<trunk>` missing locally): fetch it, and if that fails fall back to today's
   behavior with a warning — tested in Task 3.1.

---

## Phase 1 — Foundation (PR 1)

### Task 1.1: Shared methodology reference

**Files:**

- Create: `ycc/skills/_shared/references/branching-model.md`

**Interfaces:** Produces section anchors cited by later tasks: `#rules`, `#models`,
`#where-does-my-change-go`, `#backporting`, `#state-block`, `#missing-or-malformed-state`.

- [ ] Write the reference with these sections: Rules (the six shared rules from spec §2),
      Models (trunk-only; release-branches), Where does my change go (table: bug in shipped
      version / security fix / bug only on trunk / feature-refactor-docs / bug in code the trunk
      rewrote / dependency bump → target, PR into, backport), Backporting (`git cherry-pick -x`,
      branch `backport/X.Y/<slug>`, PR body "Backport of #N"), State block (the exact format
      rules from spec §3.2), Missing or malformed state (fallback rules from spec §5), and
      "How skills use this" (a table: skill → what it reads).
- [ ] Commit: `docs(skills): add shared branching and release model reference`

### Task 1.2: State parser `release-state.sh`

**Files:**

- Create: `ycc/skills/_shared/scripts/release-state.sh`
- Create: `scripts/test-release-model.sh`
- Modify: `scripts/validate.sh` (add `release` target)

**Interfaces:**

- Produces: `release-state.sh [--repo DIR] [get|base [--head REF]|check]`.
  `get` prints exactly these keys, one `key=value` per line, in this order:
  `present file model trunk maintenance latest_maintenance frozen support backport_label tracker tracker_ref`.
  `present=0` → only `present=0` is printed, exit 0. Malformed → stderr
  `release-state: <reason> (run /ycc:release-model --audit)`, exit 2.
  `base` prints one branch name. `check` prints `finding: <text>` lines; exit 1 if any.

- [ ] **Step 1: Write the failing tests** in `scripts/test-release-model.sh`, modelled on
      `scripts/test-install-sync.sh` (`ok`/`ko` counters, sandbox via `mktemp -d`, trap cleanup,
      exit 1 if `FAIL>0`). Helper `mkrepo` creates a git repo with an initial commit and a bare
      `origin` remote pushed with `main`. Cases:
  - no `RELEASING.md` → output exactly `present=0`, exit 0
  - full block (release-branches, `maintenance: release/0.6, release/0.5`) → `maintenance=release/0.6,release/0.5`,
    `latest_maintenance=release/0.6`, defaults filled (`support=latest-minor`,
    `backport_label=backport:{X.Y}`, `tracker=none`)
  - trunk-only block with only `model` and `trunk` → `maintenance=` and `latest_maintenance=`
  - CRLF block → same output as LF
  - malformed: unknown key; missing `trunk`; `model: weird`; `maintenance` set under
    `trunk-only`; `RELEASING.md` without a block → each exits 2 with a stderr reason
  - `base`: on a branch cut from `main` → `main`; on a branch cut from `origin/release/0.5`
    with a release-only commit → `release/0.5`; no `RELEASING.md` and no origin HEAD → `main`
  - `check`: table out of sync with block → a `finding:` line and exit 1

- [ ] **Step 2:** Run `bash scripts/test-release-model.sh` → FAIL (script missing).

- [ ] **Step 3: Implement** the parser. Core parsing (awk extracts the block between
      `<!-- ycc-release-state` and the next `-->`, strips `\r`, trims whitespace):

```bash
rs_extract_block() { # $1=file → key: value lines on stdout; exit 3 if no block
  awk '
    { sub(/\r$/, "") }
    /^<!-- ycc-release-state[[:space:]]*$/ { inblock=1; found=1; next }
    inblock && /^-->[[:space:]]*$/ { inblock=0; exit }
    inblock { print }
    END { if (!found) exit 3 }
  ' "$1"
}
```

Validate keys against `model trunk maintenance frozen support backport_label tracker tracker_ref`;
normalise lists by removing spaces around commas. `base` logic: read state; if
`present=0`, print `origin/HEAD`'s branch, falling back to `main` (no network calls);
otherwise for each maintenance branch `B`: `n=$(git rev-list --count origin/B ^origin/$trunk)`,
`m=$(git rev-list --count origin/B ^origin/$trunk ^HEAD)`; if `n>0 && m<n` (HEAD contains
at least one `B`-only commit) print `B`. Otherwise print `$trunk`. A branch cut from a
`release/X.Y` that has no commits of its own yet resolves to the trunk; callers offer
`--base` for that case. `check` renders
the expected table (Task 1.3's renderer, sourced from a shared function file
`lib/release-state-lib.sh`) and diffs it against the file's table section, then verifies
`git ls-remote --heads origin <branch>` for trunk and maintenance.
Put `rs_extract_block`, `rs_parse_file`, and `rs_render_table` in
`ycc/skills/_shared/scripts/lib/release-state-lib.sh` so both scripts share them.

- [ ] **Step 4:** Run the tests → PASS. Run `shellcheck` on both files → clean.
- [ ] **Step 5:** Add `release` to `VALID_TARGETS` in `scripts/validate.sh` with a
      `run_target` case running `scripts/test-release-model.sh`; update the header comment.
      Run `./scripts/validate.sh --only release` → PASS.
- [ ] **Step 6:** Commit `feat(skills): add shared release-state parser with tests`.

### Task 1.3: State updater `release-state-update.sh` and table renderer

**Files:**

- Create: `ycc/skills/_shared/scripts/release-state-update.sh`
- Modify: `ycc/skills/_shared/scripts/lib/release-state-lib.sh` (`rs_render_table`, `rs_write_file`)
- Test: `scripts/test-release-model.sh`

**Interfaces:**

- Produces: `release-state-update.sh [--repo DIR] [--dry-run] (--set-model M | --set-trunk B | --add-maintenance release/X.Y | --freeze release/X.Y | --render)`.
  Rendered table (between `<!-- ycc-release-state:table:begin -->` and
  `<!-- ycc-release-state:table:end -->`):

```markdown
Model: **release-branches**. Support window: latest-minor.

| Role        | Branch        | Notes                          |
| ----------- | ------------- | ------------------------------ |
| Trunk       | `master`      | Next minor/major release       |
| Maintenance | `release/0.5` | Patches via `backport:0.5`     |
| Frozen      | `release/0.4` | Security fixes only, if at all |
```

(Maintenance and Frozen rows repeat per branch; omitted when empty. Column widths are
padded so prettier leaves the table unchanged.)

- [ ] Tests first: add-maintenance on `latest-minor` moves the previous maintenance branch to
      `frozen`; on `latest-two-minors` keeps two; `--freeze`; `--set-trunk`; `--set-model trunk-only`
      with maintenance present → exit 1 with a message; `--render` fixes a hand-edited table;
      prose after the end marker is byte-identical; `--dry-run` prints a diff and leaves the file
      unchanged; running the rendered file through `prettier --check` passes.
- [ ] Implement; tests PASS; shellcheck clean.
- [ ] Commit `feat(skills): add release-state updater and table renderer`.

### Task 1.4: `RELEASING.md` template

**Files:**

- Create: `ycc/skills/release-model/templates/RELEASING.md.tmpl`
- Create: `ycc/skills/release-model/references/template-placeholders.md`

**Interfaces:** Produces placeholders consumed by Task 2.1: `{{PROJECT_NAME}}`, `{{TRUNK}}`,
`{{STATE_BLOCK}}`, `{{STATE_TABLE}}`, `{{TAG_PATTERN}}`, `{{VERSION_FILES}}`,
`{{CHANGELOG_FILE}}`, `{{PUBLISH_STEP}}`, `{{TRACKER_SECTION}}`, and conditional blocks
`{{#IF_RELEASE_BRANCHES}}…{{/IF_RELEASE_BRANCHES}}` / `{{#IF_TRUNK_ONLY}}…{{/IF_TRUNK_ONLY}}`
(same syntax as `ycc/skills/init/templates`).

- [ ] Write the template with the sections from spec §3.4, adapted from 9router's
      `RELEASING.md`, and the placeholder reference (each placeholder: meaning, source signal,
      fallback text).
- [ ] Test: in `test-release-model.sh`, render the template with a minimal sed substitution for
      both models into a sandbox repo, run `release-state.sh get` and `check` on the result → valid.
- [ ] Commit `feat(release-model): add RELEASING.md template`.

### Task 1.5: Ship phase 1

- [ ] `./scripts/sync.sh` then `./scripts/validate.sh` (all targets) → PASS; `npm run lint` → PASS.
- [ ] Push, open PR "feat(skills): release model foundation — shared reference, state scripts, template" with `Part of #<issue>`; CI green; squash-merge; delete branch; remove worktree.

## Phase 2 — `ycc:release-model` (PR 2)

### Task 2.1: Signal collector

**Files:** Create `ycc/skills/release-model/scripts/collect-signals.sh`; tests in
`scripts/test-release-model.sh`.

**Interfaces:** Produces key=value: `default_branch`, `long_lived_branches` (comma list of
non-default branches with a commit in the last 30 days and >20 commits not on the default
branch), `tags_count`, `latest_tag`, `tag_pattern` (`v*` or `*`), `older_line_patched`
(1 when a tag's `X.Y` is lower than an earlier-created tag's `X.Y`), `release_branches`,
`gh_releases` (count or `unknown`), `ci_trigger_branches`, `publish_workflow` (path or empty),
`version_files`, `changelog` (path or empty), `sync_merges_recent` (count of merge commits in the
last 200 on the default branch whose subject matches `Merge .* into` or `sync .* into`),
`linear_refs` (1 if commit subjects reference `[A-Z]{2,}-[0-9]+`), `suggested_model`,
`suggested_reason`.

- [ ] Tests on seeded repos: no tags → `suggested_model=trunk-only`; tags v0.1.0,v0.2.0,v0.1.1
      (patch after newer minor) → `older_line_patched=1`, `suggested_model=release-branches`;
      `release/0.5` branch → listed; a sync merge → counted; missing `gh` → `gh_releases=unknown`.
- [ ] Implement, PASS, shellcheck, commit `feat(release-model): add project signal collector`.

### Task 2.2: Skill and command

**Files:** Create `ycc/skills/release-model/SKILL.md`, `ycc/commands/release-model.md`.

- [ ] SKILL.md frontmatter (`name: release-model`, description stating when to use, `argument-hint`
      `[--upgrade | --audit] [--model trunk-only|release-branches] [--trunk NAME] [--yes]`), phases:
      0 preflight (git repo, `release-state.sh get`; present + no flags → switch to audit), 1 signals,
      2 proposal + at most three questions (`--yes` skips), 3 render template (state block written by
      `release-state-update.sh`-compatible format, table via `release-state-update.sh --render`),
      4 pointer sections (CLAUDE.md, AGENTS.md, copilot-instructions if present; idempotent via a
      `## Branching & releases` heading check), 5 labels doc (release-branches only), 6 dry-run
      preview then write, 7 summary (never commits). `--upgrade` and `--audit` phases per spec §3.5.
      Cite `_shared/references/branching-model.md` rather than restating rules.
- [ ] Command file mirrors the argument hint and flag table (pattern: `ycc/commands/releaser.md`).
- [ ] `./scripts/sync.sh && ./scripts/validate.sh` PASS; commit `feat(release-model): add ycc:release-model skill and command`.

### Task 2.3: Dogfood and ship

- [ ] Run the skill's create flow on this repo in the worktree (expected trunk-only, trunk `main`);
      commit the generated `RELEASING.md` + pointer sections as `docs: add RELEASING.md` in the same PR.
- [ ] PR, CI, merge, cleanup.

## Phase 3 — PR and branch skills (PR 3)

### Task 3.1: `prepare-feature-branch.sh`

- [ ] Tests (in `test-release-model.sh`): with state trunk `develop2` (non-standard name) the helper
      treats it as trunk; creates `feat/x` from `origin/develop2` even when local `develop2` is
      behind; on `release/0.5` exits 2 unless `--allow-release-branch`; without `RELEASING.md`
      behavior unchanged; `origin/<trunk>` missing and fetch fails → warning + today's behavior.
- [ ] Implement; update `_shared/references/branch-prep.md` rows; commit `feat(skills): branch from the RELEASING.md trunk in prepare-feature-branch`.

### Task 3.2: `git-workflow` and `prp-pr`

- [ ] `git-workflow` Phase 5 and `scripts/create-pr.sh`: base = `release-state.sh base`
      unless `--base`; `prp-pr`: replace the hard-coded `main` fallback with
      `release-state.sh base`. Both: sync guard (spec §4.1) and the backport prompt; command files
      document `--base`. Keep git-workflow's SKILL.md growth small by putting the new logic in
      `ycc/skills/_shared/references/pr-base-and-backport.md` and linking it from both skills.
- [ ] Commit `feat(git-workflow,prp-pr): pick the PR base from RELEASING.md and guard sync merges`.

### Task 3.3: `code-review`

- [ ] Context phase reads `RELEASING.md`; PR mode compares `baseRefName` with
      `release-state.sh base --head <pr-head>` and reports a finding on mismatch.
- [ ] Commit `feat(code-review): flag PRs whose base contradicts RELEASING.md`; sync, validate, PR, merge, cleanup.

## Phase 4 — Releaser (PR 4)

- [ ] Preflight reads state; missing → offer `ycc:release-model` or continue as today.
- [ ] Branch check (spec §4.2) implemented in `ycc/skills/releaser/scripts/check-release-branch.sh`
      (`<version>` → exit 0 ok / 1 with fix commands), with tests in `test-release-model.sh`
      (minor on trunk ok; minor on `release/0.5` refused; patch `0.5.3` on `release/0.5` ok; patch
      `0.6.1` on `release/0.5` refused; trunk-only patch on trunk ok).
- [ ] Phase 8 emitted commands: minor/major under release-branches adds
      `release-state-update.sh --add-maintenance release/X.Y` before the release commit, then
      `git push origin vX.Y.0^{commit}:refs/heads/release/X.Y` and the label; patch adds the
      forward-port step.
- [ ] Phase 8.5 uses the current release branch for the protection check.
- [ ] `references/ci-optimization-checklist.md` runbook row accepts `RELEASING.md`.
- [ ] Commit `feat(releaser): cut releases from the branch RELEASING.md names`; sync, validate, PR, merge, cleanup.

## Phase 5 — `ycc:backport` (PR 5)

- [ ] `scripts/find-pending.sh` (gh search merged PRs with `backport:*` labels; excludes those
      referenced by an existing "Backport of #N" PR) with tests using a stub `gh` on `PATH`.
- [ ] `scripts/cherry-pick-pr.sh <pr> <release/X.Y>` (worktree via `_shared/scripts/setup-worktree.sh`,
      `git cherry-pick -x <merge-sha>`, exit 3 on conflict leaving the worktree for inspection)
      with a local-repo test (clean pick; conflicting pick → exit 3).
- [ ] `SKILL.md` + `ycc/commands/backport.md` (`<PR#> [--to release/X.Y] | --pending [--resolve] [--ci]`).
- [ ] Agent `ycc/agents/backport-conflict-resolver.md` (tools: Read, Grep, Glob, Edit, Bash(git:*));
      minimal resolution, never commits; entry in `ycc/settings/models.json`.
- [ ] Commit `feat(backport): add ycc:backport skill and conflict-resolver agent`; sync, validate, PR, merge, cleanup.

## Phase 6 — Hygiene (PR 6)

- [ ] `git-cleanup` skill + `references/active-code-rules.md` + `ycc/agents/git-cleanup.md`:
      protected set includes state trunk + maintenance; retired `release/*` and sync-merge findings.
- [ ] `formatters/references/templates/lint.yml.tmpl`: push branches default + `release/**`;
      `scripts/validate-formatters-bundle.sh` still passes.
- [ ] `init`: CLAUDE.md template section, labels template `backport:X.Y` family, release-model
      offer phase, `--release-model`/`--no-release-model` (SKILL.md, `references/flag-reference.md`,
      `ycc/commands/init.md`).
- [ ] `blueprint`: interview question + `release_model` key in `references/bootstrap-mapping.md`.
- [ ] Commit `feat(skills): follow RELEASING.md in git-cleanup, formatters, init and blueprint`; sync, validate, PR, merge, cleanup.

## Phase 7 — Bundle release

- [ ] Run `ycc:bundle-release` (minor bump: new skills) on `main`; follow its checklist to tag
      and publish; close the tracking issue.
