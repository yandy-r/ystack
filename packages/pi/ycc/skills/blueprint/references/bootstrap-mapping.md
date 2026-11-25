# Bootstrap Mapping

Canonical mapping from the blueprint's machine-readable **Bootstrap** section to
`/skill:init` and `/skill:formatters` flags. This is the single source of truth shared by the
`blueprint` GENERATE phase and any future `--from-spec` reader. Keep it in sync with the
flag surfaces of `ycc/skills/init/SKILL.md` and `ycc/skills/formatters/SKILL.md`.

## Key → Flag Table

| Bootstrap key         | Values                                                          | `/skill:init` flag            | `/skill:formatters` flag                                       | Notes                                                                       |
| --------------------- | --------------------------------------------------------------- | --------------------------- | ------------------------------------------------------------ | --------------------------------------------------------------------------- |
| `profile`             | `rust \| ts-node \| python \| go \| mixed \| empty`             | `--profile=<value>`         | `--profile=<value>`                                          | The only language vocabulary `init` accepts. Coerce out-of-vocab answers.   |
| `secondary_languages` | comma list (e.g. `python, shell`)                               | (informs `mixed`)           | per-stack flags (below)                                      | Drives multi-stack gitignore / style activation.                            |
| `package_manager`     | `pnpm \| npm \| yarn \| uv \| poetry \| pip \| cargo \| go mod` | —                           | —                                                            | Captured for the init "next steps" + formatters aliases; not a direct flag. |
| `ci`                  | `yes \| no`                                                     | `--templates` (if yes)      | `--ci` (if yes)                                              | CI from day one.                                                            |
| `autofix_ci`          | `yes \| no`                                                     | —                           | omit `--no-autofix` when `yes`; add `--no-autofix` when `no` | Only meaningful when `ci=yes`.                                              |
| `formatter_stacks`    | subset of `ts, python, rust, go, docs, shell`                   | —                           | `--ts --python --rust --go --docs --shell`                   | One flag per enabled stack. Default follows `profile`.                      |
| `github_templates`    | `yes \| no`                                                     | `--templates` (if yes)      | —                                                            | Issue + PR templates, labels, workflows.                                    |
| `git_conventions`     | `yes \| no`                                                     | `--git` (if yes)            | `--hooks` (if yes)                                           | Conventional commits + pre-commit hooks.                                    |
| `vendor_neutral`      | `yes \| no`                                                     | `--vendor-neutral` (if yes) | —                                                            | Also emit `.ai/rules/project.md`.                                           |
| `release_model`       | `trunk-only \| release-branches \| undecided`                   | `--release-model[=<value>]` | —                                                            | Bare flag when `undecided`. Writes `RELEASING.md`; see Release Model below. |

## Profile Coercion Rules

`init` only understands `rust | ts-node | python | go | mixed | empty`. Map common answers:

| User answer                                 | Coerced `profile` |
| ------------------------------------------- | ----------------- |
| TypeScript, JavaScript, Node, Deno, Bun     | `ts-node`         |
| Python                                      | `python`          |
| Rust                                        | `rust`            |
| Go, Golang                                  | `go`              |
| Two+ primary languages of comparable weight | `mixed`           |
| No code yet / undecided                     | `empty`           |

Record any coercion in the blueprint's **Decisions Log** so the choice is auditable and the
orchestrated `--profile=<value>` call cannot fail.

## Release Model

The interview asks: _"Will older versions need patches after a newer release ships?"_

| Answer                                          | `release_model`    | `/skill:init` flag                   |
| ----------------------------------------------- | ------------------ | ---------------------------------- |
| No — fixes ship in the next release             | `trunk-only`       | `--release-model=trunk-only`       |
| Yes — users stay on older minors that need them | `release-branches` | `--release-model=release-branches` |
| Not sure yet                                    | `undecided`        | `--release-model`                  |

`init` handles the flag in its **Phase 5.5**: with a value it runs
`/skill:release-model --model <value> --yes`; bare, it runs `/skill:release-model` so the skill
proposes a model and confirms it. Either way `init` skips the step when `RELEASING.md`
already exists. Rules behind both models:
`../_shared/references/branching-model.md`.

## init Already Chains formatters

`/skill:init --formatters` invokes the `/skill:formatters` skill at its **Phase 6.5**, passing
through `--dry-run` and `--force`. Therefore:

- The single line `/skill:init --profile=<p> --templates --git --formatters` is usually enough
  to scaffold docs + GitHub + git + a baseline formatter bundle.
- Emit a **separate** `/skill:formatters …` line only when you need richer formatter options
  that `init` does not forward — `--ci`, specific stack flags, or `--hooks`.

## Worked Example

Bootstrap values:

```
profile          = ts-node
secondary_languages = python, shell
package_manager  = pnpm
ci               = yes
autofix_ci       = yes
formatter_stacks = ts, python, shell
github_templates = yes
git_conventions  = yes
vendor_neutral   = no
release_model    = trunk-only
```

Derived commands:

```bash
/skill:init --profile=ts-node --templates --git --formatters --release-model=trunk-only
/skill:formatters --profile=ts-node --ts --python --shell --ci --hooks
```
