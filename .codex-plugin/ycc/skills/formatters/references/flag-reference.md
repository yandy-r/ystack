# Flag Reference

## Contents

- Flag Matrix
- Per-Flag Examples

Detailed reference for every flag accepted by `formatters`. See `SKILL.md` for live phase logic.

---

## Flag Matrix

| Flag               | Default     | Affects phases   | Writes to                                                           | Example                                  |
| ------------------ | ----------- | ---------------- | ------------------------------------------------------------------- | ---------------------------------------- |
| `--dry-run`        | off         | 3 (halt)         | nothing                                                             | `formatters --dry-run`               |
| `--force`          | off         | 4, 5 (overwrite) | all target files                                                    | `formatters --force`                 |
| `--yes`            | off         | 3 (skip prompt)  | existing files preserved                                            | `formatters --yes`                   |
| `--sync`           | auto        | 4 (prune)        | `scripts/` bundle + removes stale managed files                     | `formatters --sync`                  |
| `--copy`           | on          | 4 (install)      | `scripts/` bundle                                                   | `formatters --copy`                  |
| `--ci`             | off         | 5 (extend)       | `.github/workflows/lint.yml` + `.github/workflows/lint-autofix.yml` | `formatters --ci`                    |
| `--no-autofix`     | off         | 5 (skip)         | (suppresses `lint-autofix.yml`; only meaningful with `--ci`)        | `formatters --ci --no-autofix`       |
| `--hooks`          | off         | 5 (extend)       | `lefthook.yml` or `.husky/pre-commit`                               | `formatters --hooks`                 |
| `--no-aliases`     | off         | 5 (skip)         | (suppresses package.json / Makefile / justfile alias injection)     | `formatters --no-aliases`            |
| `--no-docs`        | off         | 5 (skip)         | (suppresses README section append)                                  | `formatters --no-docs`               |
| `--target=<dir>`   | `$PWD`      | 1 (override)     | configs + scripts land in `<dir>`                                   | `formatters --target=~/projects/app` |
| `--profile=<lang>` | auto-detect | 1 (override)     | (forces stack flags)                                                | `formatters --profile=rust`          |
| `--rust`           | auto        | 4 (enable)       | `rustfmt.toml`, `clippy.toml`                                       | `formatters --rust`                  |
| `--ts`             | auto        | 4 (enable)       | `biome.json`, `tsconfig.json`, `package.json` (TS scaffold only)    | `formatters --ts`                    |
| `--python`         | auto        | 4 (enable)       | `pyproject.toml` (scaffold only; refuses to overwrite)              | `formatters --python`                |
| `--go`             | auto        | 4 (enable)       | `.golangci.yml`                                                     | `formatters --go`                    |
| `--docs`           | auto        | 4 (enable)       | `.markdownlint.json`, `.prettierrc`, `.prettierignore`              | `formatters --docs`                  |
| `--shell`          | auto        | 4 (enable)       | `.gitignore` entry for `/tools/shellcheck` + bundled shell tooling  | `formatters --shell`                 |
| `--all`            | off         | 4 (enable all)   | every stack regardless of detection                                 | `formatters --all`                   |

### Flag precedence

1. `--profile=<lang>` **and** explicit stack flags (`--rust`, `--ts`, …) override auto-detection entirely.
2. `--all` is shorthand for every per-stack flag; it does not override `--no-aliases` or `--no-docs`.
3. `--force` implies `--yes`; `--yes --force` are both accepted for clarity.
4. `--sync` and `--copy` are mutually exclusive. If neither is passed, `--sync` is chosen when `has_style_bundle=true`, otherwise `--copy`.
5. `--dry-run` wins over everything: the phase runs for reporting only, no writes.

### `--profile` accepted values

| Value     | Skips detection? | Effect                                                          |
| --------- | ---------------- | --------------------------------------------------------------- |
| `rust`    | yes              | Forces `--rust`                                                 |
| `ts-node` | yes              | Forces `--ts` and `--docs`                                      |
| `python`  | yes              | Forces `--python`                                               |
| `go`      | yes              | Forces `--go`                                                   |
| `docs`    | yes              | Forces `--docs` only (useful for pure-docs repos)               |
| `mixed`   | yes              | Forces every stack whose matching manifest exists in the target |

---

## Per-Flag Examples

### `--dry-run`

Preview everything without writing. Combines with any other flag.

```
formatters --dry-run
formatters --dry-run --ci --hooks
```

### `--force`

Non-interactive overwrite. Required when running in CI or over existing user-authored configs.

```
formatters --force --yes
```

### `--sync`

Re-run after a prior install. Prunes managed files that were removed from the upstream bundle. Safe to run periodically.

```
formatters --sync
```

### `--ci`

Emit `.github/workflows/lint.yml` (authoritative check) **and** `.github/workflows/lint-autofix.yml` (applies `./scripts/style.sh format` + `lint --fix` and pushes fixes back to same-repo PRs). Each destination is managed independently — an existing file is skipped unless `--force` is also passed.

The check workflow runs on every pull request and on pushes to the default branch (detected via `git symbolic-ref refs/remotes/origin/HEAD`, falling back to `main`) and to `release/**` maintenance branches, so patch lines cut under the release-branches model (see `$release-model`) stay linted.

The autofix workflow:

- Triggers on pull requests to the target repo's default branch (detected via `git symbolic-ref refs/remotes/origin/HEAD`, falling back to `main`).
- Skips fork PRs in both jobs via `github.event.pull_request.head.repo.full_name == github.repository`; the workflow cannot push to fork branches.
- Runs two jobs. The `format` job checks out the PR head (`persist-credentials: false`), runs the language setup and `./scripts/style.sh format` + `lint --fix` with `GITHUB_TOKEN` at `contents: read` and no secrets, and uploads any fixes as a `git diff` patch artifact. With no fixes it succeeds and the `push` job is skipped.
- The `push` job holds the App key and token, so it never checks out or runs PR code: no `./scripts/style.sh`, package installs, or hooks. It treats the patch as untrusted, accepts only in-place text edits to existing regular files, and fails without pushing on anything else, including any path under `.github/` (workflows, local actions, and repository settings). It applies the patch to the PR head commit's index in a fresh repository (the PR tree is never written to disk, hooks are disabled), re-checks the result, and pushes. Keep it on GitHub-hosted or ephemeral runners so nothing started by the `format` job can outlive it. The split keeps the App key away from code that the formatters and package installs run; it does not protect against someone who can push a changed workflow file to a branch, so limit branch write access to trusted writers and review autofix commits like any other commit on the PR.
- Pushes with a GitHub App installation token minted by `actions/create-github-app-token` with Contents write only. A push made with `GITHUB_TOKEN` creates the `pull_request` runs for the fix commit in an approval-required state, so every check on it would wait for a maintainer.
- Needs the `AUTOFIX_APP_CLIENT_ID` variable and `AUTOFIX_APP_PRIVATE_KEY` secret and an App with repository permission Contents read and write, installed on the repo. The App needs no Workflows permission: the `format` job leaves `.github/` out of the patch (format those files locally; `lint.yml` still reports them) and the `push` job refuses them. Organization-level variables and secrets are not available to private repositories on GitHub Free, so set them on the repository there. Anyone who can write to a repository holding the private key can mint tokens for every repository the App is installed on, so reuse one App only across repositories with the same trusted writers. Without them, or if minting fails, the job prints a warning, lists the fixes in the job summary, and exits successfully without pushing.
- Commits as `github-actions[bot]`; the check workflow (`lint.yml`) still runs authoritatively on the resulting push. A loop guard stops a second push when the PR head is already the autofix commit and the fixers still change files.
- Carries a commented `git add -u -- . ':(exclude)...'` placeholder in the `format` job — customize after install if the project has generated files that should not be auto-fixed.

```
formatters --ci                     # installs both workflows
formatters --ci --force             # overwrite both if they already exist
formatters --ci --no-autofix        # install only lint.yml (check-only)
```

### `--no-autofix`

Only meaningful when `--ci` is set. Skips installing `lint-autofix.yml`. The existing check workflow (`lint.yml`) is still installed. Use when a repo has branch-protection rules that forbid bot pushes, when no GitHub App can be set up for the push, or when the team prefers to run formatters exclusively via pre-commit hooks.

```
formatters --ci --no-autofix
```

### `--hooks`

Wire a pre-commit hook via lefthook (default) or husky (if `.husky/` is detected). Always prints a `git commit --no-verify` escape reminder.

The emitted pre-commit commands call `./scripts/style.sh lint --staged` and
`./scripts/style.sh format --staged`, which scope work to files in the git
index only (fast feedback). The bundled `style.sh` accepts `--modified`,
`--staged`, or `--unstaged` as mutually-exclusive scope flags — see
`./scripts/style.sh lint --help` for details.

If `lefthook.yml` already exists (e.g., because `init --git` ran first),
`apply-hooks.sh` merges its `pre-commit` block into the existing file rather
than overwriting, so the init-owned `pre-push` and `commit-msg` stages are
preserved.

```
formatters --hooks
```

### `--no-aliases` / `--no-docs`

Opt out of the post-install sugar. Useful when the target project already has a custom Makefile or docs pipeline.

```
formatters --no-aliases
formatters --no-aliases --no-docs
```

### `--target=<dir>`

Install into a directory other than `$PWD`. The directory must exist and should be a git repo (hooks refuse otherwise).

```
formatters --target=~/projects/new-app
```

### `--profile=<lang>`

Skip detection entirely and force a stack set. Auto-detection already ignores
gitignored files and well-known vendored/build directories (`node_modules`,
`dist`, `vendor`, `.venv`, …), so this is mainly needed to force a specific stack.
To drop a vendored tree that is **committed and not gitignored**, list it in
`.style-excludes` or `STYLE_EXTRA_EXCLUDES` instead (see
`references/stack-detection.md`).

```
formatters --profile=rust
formatters --profile=mixed --target=./monorepo
```

### Per-stack flags (`--rust`, `--ts`, `--python`, `--go`, `--docs`, `--shell`)

Enable one or more specific stacks explicitly. When any per-stack flag is passed, auto-detection is suppressed and only the named stacks run.

```
formatters --rust --go
formatters --ts --docs
```

When `--ts` and `--docs` are both enabled, Biome owns JS/TS/CSS/JSON/JSONC and Prettier is limited to Markdown/YAML so the formatters do not overlap.

### `--all`

Install configs for every supported stack regardless of detection. Useful for template repos or scaffolding an empty project ahead of code.

```
formatters --all
```
