# Plan: Rename Repo Preparation (YAN-1134 / #304)

## Summary

Implement a bounded v6.0.0 rename-preparation utility that previews or applies only exact `owner/repo` remote/marketplace references across 12 hand-maintained source files. A strict Bash wrapper executes Python standard-library logic; standalone disposable fixture tests prove positive forms, protected content, filesystem safety, and no-op behavior. Explicit validator wiring, concise contributor guidance, parent verification, adversarial review, then PR/CI/merge complete the work; no references are applied to the repository and no hosted repository rename is performed.

## User Story

As a repository maintainer, I want a fixture-proven `scripts/rename-repo.sh` that renders a complete no-write diff by default on request (`--dry-run`) and applies only approved replacements when explicitly rerun without it, so the later reference flip can be reviewed and repeated without corrupting plugin identities, local settings, generated bundles, or filesystem paths.

## Problem → Solution

The `yandy-r/claude-plugins` slug occurs in active source, generated manifests, historical documents, and a local filesystem trust path → ship an off-by-default fixed-allowlist transformer instead of running a repository-wide substitution. Support exact slug/HTTPS/SSH contexts with repository-boundary protections, preflights and atomic per-file replacement; test it only in copied fixture roots and retain the reviewed dry-run diff in the PR.

## Metadata

- **Complexity**: Medium (small engine plus an adversarial fixture matrix and three-file validator wiring)
- **Source**: GitHub #304, YAN-1134, ADR 0001, roadmap `rename-prep`, `RELEASING.md:83`
- **Research**: `docs/plans/rename-repo/feature-spec.md` and its seven linked research documents
- **Target**: v6.0.0 preparation only; later reference flip is YAN-1138
- **Execution**: Enhanced research synthesis; B1 tasks run concurrently, followed by sequential parent integration/review/shipping

## External APIs

No external APIs are involved. The utility and its tests must not make network calls, rename GitHub/Forgejo repositories, modify remotes, publish packages, or invoke sync.

## UX Design

### Before

```
Maintainer manually searches owner/repo matches
  → generated, historical, and local-path matches are indistinguishable
  → no safe reviewed apply is available for the later flip
```

### After

```
scripts/rename-repo.sh --from yandy-r/claude-plugins --to yandy-r/agentic-code-plugins --dry-run
  → full preflight + reviewable no-write diff
  → rerun without --dry-run only during the later approved flip
```

### Interaction Changes

| Touchpoint        | Before                  | After                                                                 | Notes                                          |
| ----------------- | ----------------------- | --------------------------------------------------------------------- | ---------------------------------------------- |
| Preview           | Ad hoc search/diff      | `--dry-run` prints every hunk and writes nothing                      | Retain PR review evidence.                     |
| Apply             | Manual edits            | Omit `--dry-run` to apply approved source changes                     | Explicitly warn in help and `CONTRIBUTING.md`. |
| Error recovery    | Undefined               | stderr diagnostic, nonzero exit, no writes before preflight completes | Fix path/arguments, then preview again.        |
| Target scope      | Approximate match count | Frozen 12-file source allowlist                                       | Generated files regenerate in the later flip.  |
| Repository rename | Owner-host operation    | Unchanged                                                             | This utility does not rename hosts/remotes.    |

## Mandatory Reading

| Priority | File                                                                                                         | Why                                                                                                            |
| -------- | ------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| P0       | `docs/plans/rename-repo/feature-spec.md`                                                                     | Settled deliverable, allowlist, match rules, filesystem and verification contract.                             |
| P0       | `.claude/rules/scripts.md`                                                                                   | Script style and regression requirements.                                                                      |
| P1       | `scripts/generate-claude-packages.sh:1-6`                                                                    | Thin strict Bash → stdlib Python wrapper pattern.                                                              |
| P1       | `scripts/generate_claude_packages.py:141-165,203-213`                                                        | Managed-path preflight before preview/write branching.                                                         |
| P1       | `scripts/merge_managed_config.py:362-389`                                                                    | Same-directory temp replacement and mode preservation; rename must preserve bytes, not reserialize text.       |
| P1       | `scripts/test_codex_marketplace.py:1-36` and `scripts/test_generate_codex_plugin.py:213-240`                 | `unittest`/subprocess fixture and symlink-test precedent.                                                      |
| P1       | `scripts/validate.sh:198-215`, `scripts/lib/validate-scope.sh:54-63`, `scripts/test-validate-scope.sh:74-76` | Explicit inventory dispatch and changed-path mapping/mirror tests.                                             |
| P2       | `.claude/rules/generators.md`                                                                                | Generated targets are changed only through generators.                                                         |
| P2       | `RELEASING.md:55-85`                                                                                         | Behind-the-scenes preparation vs owner-led activation. Documentation changes remain in `CONTRIBUTING.md` only. |

## Patterns to Mirror

### WRAPPER

```bash
# SOURCE: scripts/generate-claude-packages.sh:1-6
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
exec python3 "${REPO_ROOT}/scripts/generate_claude_packages.py" "$@"
```

Mirror the argument, strictness, and stdlib delegation pattern. Root containment must still be validated physically by the engine from `__file__`; do not import production code merely to spell the temporary destination. Keep messages concise.

### PREFLIGHT_BEFORE_BRANCH

```python
# SOURCE: scripts/generate_claude_packages.py:203-213 (concept)
# Calculate every output and run guards before deciding dry-run vs write.
```

Apply the same ordering: parse arguments, derive root, reject all unsafe/missing/nonregular paths, read bytes, and compute all outputs before either rendering the diff or replacing files.

## Files to Change

| File                                                     | Action           | Justification                                                                    |
| -------------------------------------------------------- | ---------------- | -------------------------------------------------------------------------------- |
| `scripts/rename-repo.sh`                                 | CREATE           | Strict thin executable wrapper with quoted `"$@"`.                               |
| `scripts/rename_repo.py`                                 | CREATE           | CLI, exact matcher, preflight, diff, atomic writes, `main()->int`.               |
| `scripts/test-rename-repo.sh`                            | CREATE           | Discoverable regression entrypoint (shell dispatch or owned standalone harness). |
| `scripts/test_rename_repo.py`                            | CREATE IF NEEDED | Detailed independent `unittest` fixtures invoked by the shell entrypoint.        |
| `scripts/validate.sh`                                    | UPDATE           | Explicitly run rename regression in `inventory`.                                 |
| `scripts/lib/validate-scope.sh`                          | UPDATE           | Map rename implementation/test to `inventory`.                                   |
| `scripts/test-validate-scope.sh`                         | UPDATE           | Lock the new scope mapping.                                                      |
| `docs/plans/rename-repo/{research-*.md,feature-spec.md}` | CREATE           | Seven research artifacts plus synthesis (this planning assignment).              |
| `docs/prps/plans/rename-repo.plan.md`                    | CREATE           | This executable plan.                                                            |
| `CONTRIBUTING.md`                                        | UPDATE           | Concise maintainer usage and scope, near maintainer-only workflows.              |

## NOT Building

- No actual repository reference rename in this checkout; no `apply` run against it.
- No GitHub/Forgejo host rename, directory rename, remotes update, old-repo recreation, package listing, npm publishing, version bump, tag, or release.
- No generated target hand-edits and no automatic `sync.sh`; source generators/regeneration belong to the later flip.
- No bare-prose rewrite pass, historical-link rewrite, worktree/path cleanup, marketplace/plugin rename, `acc` conversion, or Codex local catalog rename.
- No `--apply`, `--root`, `PROJECT_ROOT`, prompts, telemetry, new dependencies, or generalized rename framework.

## Batches

| Batch | Tasks         | Depends On | Parallel Width |
| ----- | ------------- | ---------- | -------------- |
| B1    | 1.1, 1.2, 1.3 | —          | 3              |
| B2    | 2.1           | B1         | 1              |
| B3    | 3.1, 3.2      | B2         | 2              |
| B4    | 4.1           | B3         | 1              |

- **Total tasks**: 6
- **Total batches**: 4
- **Max parallel width**: 3

There is intentionally **no `## Worktree Setup` section** and no child worktree requirement: all B1 work targets the assigned `.claude/worktrees/claude-plugins-yan-1134-rename-prep` checkout / parent-maintained working tree, with no per-task worktree setup. Files changed in one batch must not overlap.

## Step-by-Step Tasks

### Task 1.1: Implement rename wrapper and Python engine — Depends on [none]

- **BATCH**: B1
- **ACTION**: Create `scripts/rename-repo.sh` and `scripts/rename_repo.py` in the assigned worktree only.
- **IMPLEMENT**: The strict Bash wrapper forwards quoted `"$@"` and `exec python3` to the sibling stdlib module. Implement `main(argv: list[str] | None = None) -> int`; resolve the physical root from `__file__` and the script location (siblings must work when both scripts are copied into another root's `scripts/`). Parse required `--from`, `--to`, optional `--dry-run`, and `--help`; absent `--dry-run` means apply; no `--apply`.
- **IMPLEMENT**: Validate canonical slugs (reject empty/whitespace/control/scheme/path traversal/extra segments/shell syntax and duplicate/unknown arguments); `--from == --to` and no matched content are successful no-ops. Freeze exactly the 12 files listed in the spec; do not enumerate by grep/git/recursion.
- **IMPLEMENT**: Use escaped owner/repo plus explicit repository/context boundaries supporting standalone marketplace slug, HTTPS, SCP/SSH, `.git`, path/query/fragment/ref suffixes. Never modify `-official`, `.fork`, longer-repo or partial-owner strings, unrelated marketplace names, protected YCC identities, absolute local paths, or worktree paths. Do not special-case a broader bare `/claude-plugins.git` hit.
- **IMPLEMENT**: Before any write, check every parent and leaf without following symlinks; required parents are directories, required leaves exist and are regular. Reject symlinks (absolute/relative/internal/external/broken), missing paths, directory/FIFO/socket/device leaves. Read bytes, calculate all transformations, preserve newlines/final bytes/modes, and render a full unified diff with stable repository-relative labels. In apply mode use same-directory temp files plus atomic replace, skip unchanged files, clean temporaries, and cleanly finish both modes. Help must state: no host rename, no remote update, no sync.
- **MIRROR**: `WRAPPER` and `PREFLIGHT_BEFORE_BRANCH`.
- **IMPORTS**: Standard library only (`argparse`, `difflib`, `pathlib`, `tempfile`, `os`, `re`, `sys`, `stat` as needed).
- **GOTCHA**: Never make the root caller-directory/env/Git-derived and never rely on `\b` alone. Same-directory atomic replace must avoid writing through the destination final component to a hardlinked alias. Dry-run and apply share all preflight/computation.
- **VALIDATE**: Parent will run the fixture suite and read-only checks after integration; do not run tests, builds, linters, formatters, or full validation mid-flight. State checks the parent should run.

### Task 1.2: Build independent fixtures and validator wiring — Depends on [none]

- **BATCH**: B1
- **ACTION**: Create `scripts/test-rename-repo.sh` (and `scripts/test_rename_repo.py` if needed as its implementation), then update only `scripts/validate.sh`, `scripts/lib/validate-scope.sh`, and `scripts/test-validate-scope.sh`.
- **IMPLEMENT**: Fixtures must copy the production `scripts/rename-repo.sh` and `scripts/rename_repo.py` into a disposable root, create `scripts/` and **all 12** allowlisted files with independently written expected-positive and expected-negative content, and never apply to the real checkout. Include full/partial byte and mode assertions, not implementation-matcher self-tests. Cover exact slug; HTTPS with/without `.git`; SCP SSH and `ssh://`; `.git`, URL path/query/fragment/ref suffixes; adjacent protected `ycc:`, `ycc@ycc`, `ycc-mods`, `CLAUDE_PLUGIN_ROOT`, official keys, `.fork`, longer repo, partial owner, unrelated marketplace; `/home/.../yandy-r/claude-plugins` inside an allowlisted file; matching content in a generated/nonallowlisted file; CRLF/mixed newlines and no final newline; executable mode; repeat apply and no-match success as no-op.
- **IMPLEMENT**: Cover dry-run no writes and complete expected diff; apply changes only allowlist positives. Test missing and nonregular leaf (FIFO where portable) and absolute/relative, parent/leaf, internal/external, broken symlink rejection in both modes with earlier allowlisted files untouched. Test invocation from a different cwd with misleading `PROJECT_ROOT`/root-like env and no real checkout mutation. Test hardlink alias content preserved after atomic replacement if the platform permits. Cover invalid CLI cases and help success without weakening the required fixtures.
- **IMPLEMENT**: Wire the new suite explicitly into the `inventory` target in `scripts/validate.sh` near existing repo-meta regressions; do not rely on release glob discovery. Map `scripts/rename-repo.sh`, `scripts/rename_repo.py`, `scripts/test-rename-repo.sh`, and `scripts/test_rename_repo.py` if present to `inventory` in `scripts/lib/validate-scope.sh`, and add one scope assertion to `scripts/test-validate-scope.sh` mirroring `test-plan-workflow-validators.sh` handling.
- **MIRROR**: `TEST_STRUCTURE`, `WRAPPER`, and the repository's explicit inventory-test convention.
- **GOTCHA**: Fixture setup must create every allowlisted file; omitting a required file is not coverage. Never derive fixture expectations by importing/calling the transformer's matcher. Never run `./scripts/validate.sh`, tests, lint, build, format, or smoke checks mid-flight.
- **VALIDATE**: Parent runs targeted fixture and scope checks after all B1 work lands; state those commands in the handoff. Keep generated and historical real files untouched.

### Task 1.3: Write planning research, spec, plan, and contributor usage — Depends on [none]

- **BATCH**: B1
- **ACTION**: Create the seven research documents and `feature-spec.md` under `docs/plans/rename-repo/`, this plan under `docs/prps/plans/`, and a short maintainer paragraph in `CONTRIBUTING.md` (existing placement near `### Maintainer-only workflows`).
- **IMPLEMENT**: Synthesize all research agents, resolve conflicts into one settled contract, state no external APIs and no invented verification, and preserve sources/rationale. The `CONTRIBUTING.md` paragraph should give the preview command, clarify that omitting `--dry-run` applies only to the 12 source files, state generated/host/remote exclusions, and link `docs/plans/rename-repo/feature-spec.md` or this plan. Do not edit `RELEASING.md` or the changelog.
- **MIRROR**: Existing maintainer-only workflow documentation style and the settled spec language.
- **GOTCHA**: Say “tests planned/not run” where checks have not run; do not turn proposed validation commands into observed results.
- **VALIDATE**: Parent checks Markdown/documentation lint after integration. Coordinate before editing `CONTRIBUTING.md` if another slice does.

### Task 2.1: Integrate and run parent checks — Depends on [1.1, 1.2, 1.3]

- **BATCH**: B2
- **ACTION**: Parent reviews cross-slice integration, reconciles contract drift, and only then runs the targeted checks and read-only preview.
- **IMPLEMENT**: Confirm the wrapper/engine/test/document files have mode/executable bits as required and no duplicate CLI contract exists. Run targeted fixture and scope tests; then `npm run lint`, `./scripts/validate.sh --only inventory`, and full `./scripts/validate.sh` if targeted checks pass. Run the real-checkout dry-run with captured full diff and no apply; verify the actual patch contains no renamed source references, generated targets, `RELEASING.md`/changelog edits, host/remote changes, or worktree artifacts.
- **MIRROR**: `VALIDATE_COMMANDS`.
- **GOTCHA**: Passing staged/changed paths or an empty staged list is not evidence. If changed-path selection is used, ensure the rename files select `inventory`; full-list output cannot prove the changed-scope fix. Include complete dry-run output or a retained artifact reference in PR evidence, never invented verification.
- **VALIDATE**: Observe and report every command actually run and its output; stop on substantive defects and return to the owning slice.

### Task 3.1: Adversarial correctness and security review — Depends on [2.1]

- **BATCH**: B3
- **ACTION**: Review matcher boundaries, preflight ordering, root/symlink behavior, dry-run purity, byte/mode/hardlink guarantees, CLI semantics, fixture independence, and scope wiring.
- **IMPLEMENT**: Attempt to make the tool rewrite `.fork`, `-official`, local paths, nonallowlisted files, generated files, protected identities, invalid suffixes, or unsafe linked destinations; confirm no-op/repeat behavior and no-host-remote-sync claims. Record severity and exact evidence for any finding.
- **VALIDATE**: Review result accepted by parent or findings sent back for repair; do not mark review complete merely because implementation tests pass.

### Task 3.2: Parent repair and re-verification — Depends on [2.1]

- **BATCH**: B3
- **ACTION**: If 3.1 finds defects, parent dispatches targeted fixes and reruns only affected tests/wiring checks plus required validation gates.
- **IMPLEMENT**: Keep fixes within the settled allowlist and no-external-API contract unless an approved scope decision changes the spec/plan first.
- **VALIDATE**: Parent reports rerun commands/output and leaves any nonblocking residual risks explicitly documented.

### Task 4.1: Open PR, satisfy CI/review, then merge — Depends on [3.1, 3.2]

- **BATCH**: B4
- **ACTION**: Parent prepares the PR description with the full reviewed dry-run diff (or retained artifact location), tested command output, negative-control summary, and explicit “preparation only / not applied” statement; runs/address CI and review; merges only when required gates succeed.
- **IMPLEMENT**: Title/body follow repository PR conventions. Disclose the assignable scope/wiring files and documentation changes; do not include generated bundles, source reference flips, `RELEASING.md`, changelog, host rename, or remote changes. No red CI, unresolved substantive review thread, or dry-run discrepancy may be narrated as deferred background.
- **VALIDATE**: Observe CI checks and merge result; if deployment or external activation is expected after merge, state that YAN-1138 remains a separate owner-led step and has not been performed.

## Testing Strategy

### Fixture/unit tests

| Area                 | Cases                                                                                      | Expected result                                                           |
| -------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Positives            | Exact slug, HTTPS±`.git`, SCP SSH, `ssh://`, `.git`, path/query/fragment/ref suffix        | Owner/repo changes; all syntax/suffix bytes preserved.                    |
| Negative boundaries  | `-official`, `.fork`, longer repo, partial owner, unrelated marketplace                    | Byte-identical                                                            |
| Protected identities | `ycc:`, `ycc@ycc`, `ycc-mods`, `CLAUDE_PLUGIN_ROOT`, official marketplace                  | Byte-identical                                                            |
| Local paths          | `/home/.../yandy-r/claude-plugins`, worktree paths inside managed files                    | Byte-identical despite allowlist membership                               |
| Filesystem matrix    | Missing/nonregular leaf, parent/leaf symlinks (absolute/relative/internal/external/broken) | Nonzero before any write, targets unchanged                               |
| Dry-run              | Changes available; no-match content                                                        | Full diff, no writes; successful no-op                                    |
| Apply                | Positives in all 12; negatives; generated/nonallowlisted matched sentinels                 | Only allowlisted positives change; unrelated bytes/newlines/modes survive |
| Repeat/no-match      | Apply twice; fixture already renamed                                                       | Second run succeeds, changes nothing                                      |
| Root/env             | Copied scripts, arbitrary cwd, misleading root env                                         | Derived fixture root is targeted                                          |
| CLI                  | Bad slug, unknown/duplicate argument, missing value, `--from == --to`                      | Invalid arguments reject; same-value is no-op success                     |
| Hardlink             | Managed path plus alias sharing inode                                                      | Atomic replacement does not mutate alias content                          |

### Edge Cases Checklist

- [ ] Machine-local trust path and generated trees remain untouched.
- [ ] Worktree names and generated manifests untouched.
- [ ] CRLF/mixed newlines and missing final newline preserved.
- [ ] Permissions/executable bit preserved.
- [ ] Dry-run leaves mtimes/content/temp state unchanged.
- [ ] No host API, remote mutation, sync, or external network operation.

## Validation Commands

Parent runs these only after B1 lands. Workers report commands for the parent rather than executing them mid-flight.

```bash
bash scripts/test-rename-repo.sh
bash scripts/test-validate-scope.sh
./scripts/validate.sh --only inventory
npm run lint
./scripts/validate.sh
scripts/rename-repo.sh --from yandy-r/claude-plugins --to yandy-r/agentic-code-plugins --dry-run
```

For changed-scope behavior, ensure the changed path set actually includes rename implementation/test paths so the `inventory` mapping is decisive. Do not pass an empty path list to changed validation and call it proof.

EXPECT: Every command parent actually runs exits `0`; failures are repaired and rerun. The real-checkout dry-run remains preview-only, with output captured for the PR.

## Acceptance Criteria

- [ ] `scripts/rename-repo.sh --from owner/repo --to owner/repo --dry-run` prints every planned hunk and changes no file.
- [ ] The same invocation without `--dry-run` applies only approved exact-boundary positives in exactly the 12 fixed source files.
- [ ] The engine rejects missing, symlinked (including parent/broken), or nonregular allowlisted paths before writing any file.
- [ ] `--from == --to`, no matches, and repeat apply succeed as no-ops.
- [ ] SSH/HTTPS/standalone forms, suffix preservation, protected tokens, local paths, and generated/history/worktree files pass adversarial fixtures.
- [ ] New tests explicitly selected by `inventory` validation and mirrored scope tests pass.
- [ ] `CONTRIBUTING.md` explains usage/scope; `RELEASING.md`/changelog/generated targets/source references are not changed.
- [ ] Parent verification, adversarial review, PR CI/review, and merge complete with evidence.

## Completion Checklist

- [ ] Wrapper contract, engine root/matching semantics, fixture independence, and scope wiring agree with `feature-spec.md`.
- [ ] No documentation claim presents planned commands as observed verification.
- [ ] Full dry-run diff retained for review; no apply ran against the checkout.
- [ ] No host rename, remote update, generated bundle edit, release action, or unrelated user change is included.

## Risks

| Risk                                              | Likelihood | Impact | Mitigation                                                     |
| ------------------------------------------------- | ---------- | ------ | -------------------------------------------------------------- |
| Word-boundary bug corrupts `-official` or `.fork` | Medium     | High   | Explicit boundary model plus adversarial tests                 |
| Local path contains slug                          | High       | High   | Local exclusion in matcher and settings fixtures               |
| Symlink/nonregular path escapes repo              | Medium     | High   | Full non-follow preflight, copied fixture matrix               |
| New suite never selected by CI scope              | Medium     | Medium | Explicit inventory + scope mapping/test                        |
| Stale plan text drifts from settled CLI           | Low        | Medium | Spec is P0 mandatory reading; parent integration audits        |
| False completion from empty changed set           | Low        | Medium | Decisive changed-path validation and observed output reporting |

## Notes

No checks, diff runs, API calls, or verification claims were generated by this planning assignment. “Evidence” above refers to research anchors, not test execution. The assigned worktree path is an operational target for implementers; it is not a deliverable and must never be written into the transformation allowlist.
