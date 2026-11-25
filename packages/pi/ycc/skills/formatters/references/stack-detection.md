# Stack Detection

## Contents

- Detection Predicates
- Manifest + Config Probes
- Heuristics for Merging with Existing Configs
- Adding a New Stack

How `profile-style.sh` decides which language tracks and configs apply to a target project. Predicates mirror the upstream logic in `scripts/style.sh` (`detect_*_project` functions, roughly lines 133–181). Keep this table in sync when upstream changes.

---

## Detection Predicates

| Stack  | Positive if any match                                                                                                             | Notes                                                |
| ------ | --------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| Rust   | `Cargo.toml` exists **OR** any `*.rs` file exists                                                                                 | Workspace and crate repos both pass                  |
| Go     | `go.mod` exists **OR** any `*.go` file exists                                                                                     |                                                      |
| TS/JS  | any `tsconfig*.json` **OR** `biome.json(c)` **OR** `*.ts/.tsx/.js/.jsx/.mjs/.cjs/.mts/.cts`                                       | Covers Node, Deno, Bun, browser, and edge runtimes   |
| Python | `pyproject.toml` **OR** `requirements.txt` **OR** `setup.py` **OR** any `*.py/*.pyi`                                              |                                                      |
| Docs   | any `.markdownlint*` or `.prettierrc*` exists **OR** any `*.md/.mdx/.yaml/.yml` **OR** `*.json/.jsonc` when TS/JS is not detected | Docs track yields JSON/JSONC to Biome in TS/JS repos |
| Shell  | any `*.sh` file                                                                                                                   | Always attempted when shellcheck is on the PATH      |

### Ignore-aware enumeration

The suffix-based checks go through `directory_has_suffixes` — a thin wrapper over
`dir_has_source_suffix` in `bundle/lib/excludes.sh`. Detection enumerates only
**project source**, i.e. the same set the linter operates on:

- **Git worktree** → `git ls-files --cached --others --exclude-standard`, so
  `.gitignore` is honored (tracked + brand-new untracked files, minus ignored ones).
- **Non-git dir** → a `find` fallback that prunes `.git/`.

Both then drop `STYLE_EXCLUDES` paths (`node_modules`, `dist`, `build`, `out`,
`vendor`, `.venv`, `__pycache__`, the tool caches, generated bundle dirs, …).
The unambiguous dependency/cache dirs listed in `STYLE_EXCLUDES_ANY_DEPTH`
(`node_modules`, `vendor`, `.venv`, `venv`, `__pycache__`, `.mypy_cache`,
`.pytest_cache`, `.ruff_cache`) are pruned at **any** depth; every other entry —
including generic words like `env`, `build`, `out` — matches **root-relative only**
so a legitimately-tracked nested source dir is never silently dropped.

Net effect: a stray `*.rs`/`*.py` inside `node_modules/`, a build-output dir, or
any gitignored/vendored tree no longer flips `detect_*` to `true`. `profile-style.sh`
and `style.sh` share this one enumeration, so detection and linting can never
disagree about what counts as source.

### User excludes (committed vendored trees)

A vendored tree that is committed **and not gitignored** is still source to git.
Declare it non-source for both detection and linting with either:

- **`.style-excludes`** at the project root — one entry per line; blank lines,
  `#` lines and `entry # comment` trailing comments are ignored (a `#` inside an entry is
  kept). Example:

  ```text
  # checked-in reference data
  config/data/trashguide
  third_party
  ```

- **`STYLE_EXTRA_EXCLUDES`** env var — whitespace- or colon-separated entries, for
  CI or one-off runs (`STYLE_EXTRA_EXCLUDES="third_party:gen" ./scripts/style.sh lint`).

Entries are appended to `STYLE_EXCLUDES` and match **root-relative** (the path
itself or anything under `<entry>/`); a leading `./` or trailing `/` is ignored.
When any user exclude is set, full-repo Python runs pass the filtered file list to
ruff/black instead of `.`; explicitly passed files bypass ruff/black's own
`exclude` settings unless `force-exclude` is enabled in their config. Tools that scan the tree themselves (`cargo`,
`golangci-lint`, `tsc`) do not see these entries — use their own config to skip
the path.

---

## Manifest + Config Probes

In addition to stack detection, `profile-style.sh` emits existence flags for known config files. The skill uses these to decide whether to create vs skip vs merge during the install phase.

| Probe key                        | Source                                                    | Default action on re-run                            |
| -------------------------------- | --------------------------------------------------------- | --------------------------------------------------- |
| `has_style_bundle`               | `scripts/.style-bundle-manifest` exists                   | Prefer `--sync` on install                          |
| `has_package_json`               | `package.json` at target root                             | Merge `scripts` block via `jq`                      |
| `has_makefile`                   | `Makefile` at target root                                 | Append targets with duplicate-target guard          |
| `has_justfile`                   | `justfile` at target root                                 | Append recipes                                      |
| `has_existing_prettierrc`        | `.prettierrc` / `.prettierrc.json` / `.prettierrc.y(a)ml` | Skip template; warn on conflict                     |
| `has_existing_biome_json`        | `biome.json` or `biome.jsonc`                             | Skip template; warn on conflict                     |
| `has_existing_golangci_yml`      | `.golangci.yml` or `.golangci.yaml`                       | Skip template; warn on conflict                     |
| `has_existing_rustfmt_toml`      | `rustfmt.toml`                                            | Skip template                                       |
| `has_existing_clippy_toml`       | `clippy.toml`                                             | Skip template                                       |
| `has_existing_pyproject_ruff`    | `pyproject.toml` contains `[tool.ruff]` or `[tool.black]` | Refuse to overwrite; emit merge hint                |
| `has_existing_markdownlint_json` | `.markdownlint.json` or `.markdownlint.jsonc`             | Skip template                                       |
| `has_lefthook`                   | `lefthook.yml` or `lefthook.yaml`                         | Merge `pre-commit` commands (preserve other stages) |
| `has_husky`                      | `.husky/` directory                                       | Append to `.husky/pre-commit`                       |
| `has_pre_commit_framework`       | `.pre-commit-config.yaml`                                 | Leave alone; skill does not manage it               |
| `ci_provider`                    | `.github/workflows/` / `.gitlab-ci.yml` / `.circleci/`    | Drives which CI template to emit                    |

---

## Heuristics for Merging with Existing Configs

1. **Never silently overwrite a user-authored config.** Compare canonical content (or presence of `[tool.*]` tables for TOML) and present a diff before prompting.
2. **Tool configs are idempotent targets.** Re-running with `--sync` on an unchanged project is a no-op by design.
3. **package.json scripts merge, never replace.** `apply-aliases.sh` loads the user's existing `scripts` object, adds only keys not already present, and writes back via `jq`. Existing `lint`, `format`, etc. are preserved unless `--force` is passed.
4. **Docs appending is anchored.** `apply-docs.sh` matches `^##\s+Linting & Formatting\s*$` to decide between create vs replace. No heading match → append at EOF with a single blank-line separator.
5. **Hook tooling is detected before installed.** If both `lefthook.yml` and `.husky/` exist, prefer lefthook (repo-shared) and log the choice.

---

## Adding a New Stack

If upstream `scripts/style.sh` gains a new language track:

1. Add a row to the predicate table above.
2. Add a matching probe key if relevant.
3. Extend `profile-style.sh` to emit the new `detect_<lang>=true|false` line.
4. Add a conditional block to `references/templates/readme-section.md.tmpl`.
5. Update `flag-reference.md` with the new per-stack enable flag.
6. Regenerate bundles and re-run `./scripts/validate.sh`.
