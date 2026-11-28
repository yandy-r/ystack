# Best Practices

Per-language tool selection, rationale, and deviation guidance. The skill installs this toolchain by default; override with per-stack flags if the project has strong reasons to diverge.

---

## Rust — `rustfmt` + `clippy`

- **Formatter:** `cargo fmt --all` using `rustfmt.toml` (project-pinned edition, max width 100).
- **Linter:** `cargo clippy --all-targets -- -D warnings` using `clippy.toml`. `-D warnings` treats every clippy lint as an error in CI.
- **Rationale:** Both tools are first-party (rust-lang/rustfmt, rust-lang/rust-clippy). `rustfmt` is the canonical formatter; deviating fragments the ecosystem. `-D warnings` in CI surfaces regressions early.
- **When to deviate:** Projects on `beta`/`nightly` that need unstable `rustfmt` options — pin via `rust-toolchain.toml` and document the rationale in the project's README.

---

## Go — `gofmt` + `goimports` + `golangci-lint`

- **Formatter:** `gofmt -w` + `goimports -w` (the latter reorders imports and adds missing ones).
- **Linter:** `golangci-lint run ./...` using `.golangci.yml`. The template enables `errcheck`, `govet`, `ineffassign`, `staticcheck`, `unused`, and `gofmt`/`goimports` consistency checks.
- **Rationale:** `gofmt` is the language-mandated formatter. `golangci-lint` is the de-facto meta-linter — it multiplexes every useful linter, caches per-package, and is the fastest way to get broad coverage.
- **When to deviate:** Monorepos with build tags or generated code should extend `issues.exclude-rules` in `.golangci.yml` rather than disable linters globally.

---

## TypeScript / JavaScript — `biome` + `tsc`

- **Formatter + linter:** `@biomejs/biome format --write` and `@biomejs/biome check --fix` against `biome.json`. In CI, use `@biomejs/biome ci` on JS/TS/CSS/JSON/JSONC sources.
- **Type checker:** `tsc --noEmit` against `tsconfig.json` (runs when any `tsconfig*.json` is present).
- **Rationale:** Biome is a single Rust-based tool that replaces Prettier + ESLint + several common plugins. It is ~100× faster on medium repos, has zero plugin resolution overhead, and ships sensible defaults. A single dependency replaces ~15 `eslint-*` plugins.
- **When to deviate:**
  - Projects with extensive ESLint plugin investments (e.g., `eslint-plugin-react-hooks` with custom rules, framework-specific linters not yet in Biome) should keep ESLint but still pair with Biome's formatter.
  - Legacy ecosystems still on `eslint@8` with `eslint-config-*` dependencies may defer migration until the plugins land in Biome or support Biome's plugin API.

---

## Python — `ruff` + `black`

- **Linter + import sorter:** `ruff check --fix` (replaces `flake8`, `isort`, `pyupgrade`, `pydocstyle`, etc.).
- **Formatter:** `black .` (or `ruff format .` — both are supported; the default template uses `black` for broadest ecosystem familiarity).
- **Config:** `[tool.ruff]` and `[tool.black]` in `pyproject.toml`. The skill **refuses to overwrite** an existing `pyproject.toml`; it emits the merge snippet for manual addition.
- **Rationale:** `ruff` is a Rust-based linter that is ~100× faster than the combined Python tool stack and subsumes `flake8`, `isort`, `pyupgrade`, `pydocstyle`, and more. `black` remains the canonical formatter — though `ruff format` is a fully-compatible drop-in if the project prefers a single tool.
- **When to deviate:** Projects using `mypy --strict` should add it explicitly to the lint script; it is orthogonal to `ruff`. Django/Flask projects with `isort` profiles codified in team docs should keep `isort` settings in `[tool.ruff.lint.isort]` to preserve behavior.

---

## Docs — `markdownlint` + `prettier`

- **Markdown linter:** `markdownlint` (CommonMark + `.markdownlint.json` rules, default rule set MD001–MD059).
- **Formatter:** `prettier --write` for Markdown and YAML by default. In docs-only repos, it also owns JSON/JSONC.
- **Rationale:** `markdownlint` catches Markdown-specific structural issues (heading ordering, list indent, line-length exceptions). Prettier remains the lightweight docs formatter, while TS/JS repos delegate JSON/JSONC to Biome so the tools never fight over the same files.
- **When to deviate:** MDX-heavy repos should add `mdx` to `prettier` plugins. Docs sites using Vale or custom writing-style linters can layer them on top.

---

## Shell — `shellcheck` + `shfmt`

- **Linter:** `shellcheck --severity=warning` (catches quoting, word-splitting, unused variables, cross-shell portability issues).
- **Formatter:** `shfmt -w -i 2 -ci` (2-space indent, switch-case indented) — optional; not all repos install it.
- **Rationale:** `shellcheck` is the only mature static analyzer for POSIX shell/bash. Its checks prevent the vast majority of production shell bugs.
- **When to deviate:** Projects using `zsh` extensions or `ksh` features that `shellcheck` can't handle should pin `# shellcheck shell=bash` at the top of each file or exclude via `.shellcheckrc`.

---

## Guiding Principles

1. **Prefer Rust-based tools for performance.** `biome`, `ruff`, `shfmt` are all orders of magnitude faster than their predecessors and pay back their install cost within the first lint run.
2. **Pin configs, not tool versions by default.** Use `mise.toml` / `rust-toolchain.toml` / `go.mod`'s `toolchain` directive for most version pinning. The formatter bundle manages a tooling-specific `shellcheck` pin so local runs and generated CI stay aligned.
3. **Single source of truth per language.** One formatter per stack. Adding a second (e.g., both `prettier` and `biome` on `.ts` files) guarantees a fight.
4. **Always gate `-D warnings` / `--strict` behind CI, not local dev.** Local lint should be fast and forgiving; CI should be strict.
5. **Idempotence over cleverness.** The skill prefers `--sync` (prune stale, install fresh) over cascading merge heuristics. Tool configs should be reproducible, not negotiated.

---

## The Installer Contract

The skill **does not reimplement** linter/formatter dispatch. It installs a self-contained bundle (`scripts/style.sh`, `lint.sh`, `format.sh`, `init-formatters.sh`, templates) rooted in `scripts/style.sh`. All runtime dispatch — stack detection, `--modified` file filtering, `cargo fmt` vs `cargo fmt --check`, etc. — lives in that bundle. Upgrading the bundle upstream propagates to all installed targets via `ycc:formatters --sync`.

When in doubt about which tool runs on a given file, read `scripts/style.sh` functions `run_*_lint` and `run_*_format`. That file is the source of truth.
