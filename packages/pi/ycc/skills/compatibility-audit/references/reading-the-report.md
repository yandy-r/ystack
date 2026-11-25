# Reading the compatibility-audit report

## Contents

- What each section means
- Per-target verdict semantics
- How to fix drift
- How to fix install-assumption failures
- Why we don't collapse to a single pass/fail
- Annotated sample report

This document explains how to interpret the output of `ycc:compatibility-audit`: the
structure of the human-format report, what each per-target verdict means, and how to act
on the most common failure classes.

---

## What each section means

The Markdown report has one section per target. Each section contains four subsections:

**Drift block** — compares the `ycc/` source tree against the generated bundle for that
target (`.cursor-plugin/` for Cursor, `.codex-plugin/ycc/` for Codex, or the source tree
itself for Claude). Drift means the bundle is stale — a skill, agent, or rule file is
missing or no longer matches the source.

**Validator sweep** — output of `./scripts/validate.sh --only <target>`. Runs the suite
of per-target validators (inventory check, manifest JSON, executable bits, file counts).
A failure here means the bundle cannot be trusted for release.

**Install assumptions** — output of `audit-install-assumptions.sh`. Verifies that every
artifact uses the expected install-path convention, has a valid shebang where required,
and that plugin-root variable references are rewritten target-appropriately (kept as
`${CLAUDE_PLUGIN_ROOT}` in the Claude source tree; rewritten to the installed plugin's
absolute path in generated Cursor and Codex bundles). For `omp`, `OM1` passes while the root
`.omp-plugin/` is absent only if the matrix marks `INSTALL_PATH:omp` `unsupported` or `partial`
(`partial` with no listed OMP package: installed by `install.sh --target omp` from a generated
export); once the catalog exists, `OM2` requires a valid `.omp-plugin/marketplace.json`. For
`pi`, `PI1` fails closed both ways on an installable package (`packages/pi/*/package.json`): until
one exists every `pi` matrix cell must be `unsupported` (a skills-only `packages/pi/ycc/skills`
tree does not count), and once one exists `INSTALL_PATH:pi` must not be `unsupported`.

**Feature-vs-matrix** — output of `audit-target-features.sh`. Cross-references
capabilities in the source tree against `target-capability-matrix.md`. Features present
in source but absent from a bundle are flagged here with their matrix verdict alongside.

---

## Per-target verdict semantics

Each target section ends with one of three capability verdicts (from the matrix) and one
overall verdict.

**supported** — fully available with a primary-source citation in the matrix Notes
section. A missing artifact for a `supported` feature is a portability bug.

**partial** — available in a limited or adapted form. Read the note in
`target-capability-matrix.md` for that `capability:target` key before acting. For
example, `COMMANDS:cursor` is `partial` because slash commands are surfaced via rule-file
guidance, not as executable artifacts. This is expected behavior, not a bug.

**unsupported** — does not exist on that target. A matched surface is either a
portability bug (a generated artifact that should not be there) or an intentionally
target-specific file that should be documented. Verify whether the absence is intentional
before treating it as a failure.

The overall per-target verdict is:

- `FAIL` — drift detected, validation failed, or install assumptions violated.
- `WARN` — no hard failures, but `partial` or `unsupported` gaps documented in the matrix.
  These are expected and do not block release.
- `PASS` — all checks passed; only `supported` features or no gaps present.

---

## How to fix drift

Drift means the generated bundle is out of sync with `ycc/`. Run from the repository
root:

```
./scripts/sync.sh && ./scripts/validate.sh
```

`sync.sh` regenerates all three targets; `validate.sh` confirms structural correctness.
After both exit 0, re-run `ycc:compatibility-audit` to confirm the drift block clears.

Do not hand-edit `.cursor-plugin/` or `.codex-plugin/`. Those paths are generator-owned.

---

## How to fix install-assumption failures

Checks are keyed by short codes. One-liner remediation per group:

**Claude (C1-C4)**

- `C1` — `plugin.json` missing or malformed; fix and validate with
  `python3 -m json.tool ycc/.claude-plugin/plugin.json`.
- `C2` — version mismatch between `plugin.json` and `marketplace.json`; align them.
- `C3` — skill or agent directory missing its required `.md` file; create or restore it.
- `C4` — script not executable; run `chmod +x` on the flagged file.

**Cursor (CR1-CR4)**

- `CR1-CR4` — regenerate via `./scripts/sync.sh`. If residue persists after regeneration,
  open an issue — a generator is leaking Claude-specific content (e.g., a raw
  plugin-root variable reference) into the Cursor bundle instead of rewriting it.

**Codex (CX1-CX4)**

- `CX1-CX4` — regenerate via `./scripts/sync.sh`. If the `plugin.json` / skills directory
  mismatch persists, there is a codex generator regression; open an issue with the full
  `validate-codex-plugin.sh` output attached.

---

## Why we don't collapse to a single pass/fail

Each target operates under a different runtime contract. Cursor does not support slash
commands as executable artifacts; Codex does not support hooks. These are expected,
documented gaps — not failures. Collapsing the three targets into one aggregate verdict
would obscure which target needs attention and why. The per-target verdict model preserves
this distinction: `FAIL` on `cursor` with `PASS` on `claude` and `codex` isolates the
problem to a Cursor generator regression, not a source-tree issue.

---

## Annotated sample report

Partial human-format report with inline annotations above each subsection.

```
## compatibility-audit report

# --- Target: cursor ---
# Drift: two skills were added to ycc/ but not yet propagated to .cursor-plugin/.
- Drift: 2 skills missing from .cursor-plugin/ (bundle-author, compatibility-audit)
# Validator sweep: the generated rules file is missing a required [skills] section.
- Validation: FAILED — .cursor-plugin/rules/ycc.mdc missing section [skills]
# Install assumptions: one script was not rewritten by the generator.
- Install assumptions: 1 script missing executable bit (audit-install-assumptions.sh)
# Feature-vs-matrix: COMMANDS is "partial" on Cursor — expected per the capability matrix.
- Feature gaps: slash commands not supported on Cursor (expected, per capability matrix)

Verdict: FAIL

---

# --- Target: codex ---
# Drift: generated bundle matches source tree.
- Drift: none detected
# Validator sweep: all codex validators passed.
- Validation: passed
# Install assumptions: path conventions correct, no leaked variables.
- Install assumptions: all checks passed
# Feature-vs-matrix: HOOKS.* are "unsupported" on Codex — expected per the capability matrix.
- Feature gaps: hooks not supported on Codex (expected, per capability matrix)

Verdict: WARN
```

The `WARN` on `codex` is not actionable — it reflects documented `unsupported` hook
status in the matrix. Only `cursor` requires action: run
`./scripts/sync.sh && ./scripts/validate.sh` to regenerate and fix the stale bundle.
