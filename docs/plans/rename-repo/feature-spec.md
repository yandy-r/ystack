# Feature Spec: Rename Repo Preparation

## Executive Summary

YAN-1134 / [#304](https://github.com/yandy-r/claude-plugins/issues/304), targeted at v6.0.0, delivers a bounded repository-reference transformer and isolated regression proof for the later YAN-1138 reference flip. It does not rename this repository or change installation behavior during preparation. A strict Bash wrapper delegates to a Python standard-library engine that preflights a fixed 12-file source allowlist, computes exact-slug/context-aware replacements, and either prints a full diff or atomically replaces changed files while preserving unrelated bytes and modes. The principal risks are overbroad matching, local-path corruption, unsafe filesystem destinations, and false claims of generated/hosting activation.

## External Dependencies

No external APIs, services, authentication, SDKs, or new runtime packages are involved. Runtime requirements are Bash and Python 3, following the repository's existing wrapper/module pattern. The utility must not invoke Git mutation, network tools, sync, package publishing, or generators.

## Business Requirements

### User Stories

- As a maintainer, I want a full no-write preview so that I can review and retain the exact planned source changes in the PR.
- As the later flip operator, I want a deterministic apply operation so that approved remote references change without damaging identities or local state.
- As an existing user, I want marketplace/plugin identities preserved so that a repository rename does not become an unintended plugin migration.

### Business Rules

1. This preparation ships tooling only; never apply the rename against the preparation checkout.
2. Repository hosting, remotes, directory names, generated artifacts, package listings, publication, and version activation are outside scope.
3. `ycc:`, `ycc@ycc`, `ycc-mods`, `CLAUDE_PLUGIN_ROOT`, and `claude-plugins-official` remain byte-identical.
4. Historical documents, bare prose names, local settings, filesystem paths, and worktrees are deliberately excluded from rewrite scope.
5. A no-match or repeated apply is successful and performs no writes.

### Success Criteria

- A reviewer can inspect a complete real-checkout dry-run diff without any reference being applied.
- Independent fixtures prove exact positive transformations and byte-identical negative controls, including inside allowlisted files.
- The new suite is explicitly wired into inventory validation and changed-path scope selection.
- Parent-run checks, adversarial review, PR/CI, and merge evidence are reported truthfully, never inferred from research.

## Technical Specifications

### Architecture

```text
scripts/rename-repo.sh
  └─ exec python3 scripts/rename_repo.py
       ├─ parse/validate CLI
       ├─ derive physical root from __file__
       ├─ preflight every fixed source path and compute changes
       ├─ --dry-run: complete unified diff, no filesystem writes
       └─ default: same-directory atomic replacement of changed files
```

Python API: `main(argv: list[str] | None = None) -> int`. The wrapper is strict Bash and forwards quoted arguments. No environment root override, root flag, or dependency on the invoking working directory is permitted. Fixtures copy both scripts into their own `scripts/` directory and populate every required source entry.

### CLI Contract

```text
scripts/rename-repo.sh --from owner/repo --to owner/repo [--dry-run]
```

`--from` and `--to` are required canonical owner/repository slugs. `--dry-run` opts into preview; absence selects apply. There is no `--apply` flag or prompt. `-h`/`--help` succeeds and explicitly explains apply-by-default, source-only scope, and no host rename, remote updates, or sync. Invalid/unknown/duplicate arguments fail before writes; errors go to stderr, useful results/diffs to stdout. A successful no-op is not an error.

### Source Allowlist

Exactly these files are eligible for future apply:

1. `README.md`
2. `.claude-plugin/marketplace.json`
3. `.github/ISSUE_TEMPLATE/config.yml`
4. `docs/install/codex.md`
5. `install.sh`
6. `scripts/codex_marketplace.py`
7. `scripts/generate_codex_plugin.py`
8. `scripts/test_codex_marketplace.py`
9. `scripts/lib/install/targets/claude.sh`
10. `scripts/lib/install/targets/codex.sh`
11. `ycc/mods/.claude-plugin/marketplace.json`
12. `ycc/settings/settings.json`

These are transformation targets, not a request to edit their references now. The rename scripts, tests, and new research documents are not part of the transformation write set. Do not recursively enumerate repository matches or expand the allowlist from approximate roadmap counts.

### Match and Preservation Rules

| Input shape                                                                | Expected behavior                                              |
| -------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Exact standalone `owner/repo` marketplace slug                             | Replace only the source slug.                                  |
| HTTPS remote, SCP SSH, or `ssh://` remote                                  | Replace exact owner/repository; preserve syntax and suffixes.  |
| `.git`, URL subpath/query/fragment, supported ref suffix                   | Preserve suffix while rewriting the exact repository identity. |
| `owner/repo-official`, `owner/repo.fork`, longer repository, partial owner | Unchanged.                                                     |
| `/home/.../owner/repo`, local/worktree paths inside managed content        | Unchanged.                                                     |
| Matching text outside allowlist, generated/history/worktree content        | Unchanged and never opened for writing.                        |
| Stable YCC/plugin/official identifiers                                     | Byte-identical.                                                |

A regex word boundary alone is insufficient: hyphenated extensions can satisfy `\b`. Escape the source slug and use literal replacement semantics; never interpolate CLI values into code. Do not match arbitrary `/claude-plugins.git` strings without owner/remote context.

### Filesystem and Byte Contract

Before any write, validate arguments and every managed path, and compute every transformation. Check parents and leaves without following symlinks. Required parents must be directories and leaves existing regular files; missing paths, symlink components (including broken/internal links), directories, FIFOs, sockets, and devices are hard errors in both modes. Derive the root physically from the scripts' location, not caller/environment/Git state.

Preserve unrelated bytes, all newline forms and final-newline state, and permission/executable modes. Use same-directory temporary files plus atomic replacement for changed files; do not rewrite unchanged files or truncate existing inodes. Clean temporary files on failure. This gives all-preflight-before-write behavior and per-file atomicity, not cross-file rollback or protection against concurrent hostile checkout mutation.

### System Integration

Create `scripts/rename-repo.sh`, `scripts/rename_repo.py`, `scripts/test-rename-repo.sh`, and an independent Python fixture module if used. Update `scripts/validate.sh` inventory dispatch, `scripts/lib/validate-scope.sh`, and `scripts/test-validate-scope.sh`. Add short maintainer usage/scope guidance to `CONTRIBUTING.md`. Do not modify `RELEASING.md`, changelog, generated targets, or actual repository references in this preparation.

## UX Considerations

The documented first action is a dry-run using the current and future repository slugs. Output must include all hunks with stable repository-relative labels, not a truncated summary. The maintainer retains that preview for review; only the later approved flip reruns without `--dry-run`. Error messages identify the invalid argument or relative managed path and return nonzero before writes; restoring a required safe source file and retrying preview is the recovery path. Plain uncolored text makes the output accessible to terminals, logs, and reviewers without color-dependent meaning.

## Recommendations

Use the smallest existing patterns: wrapper/module separation, Python `unittest` fixtures, generator-style preflight, and config-writer-style atomic replacement. Independent tests must not compute expected output by reusing the implementation matcher. Copying the shipped scripts into complete temporary trees proves real root resolution while keeping production root hooks unnecessary. Do not add generalized repository discovery, aliases, compatibility modes, transactional abstractions, or telemetry.

## Risk Assessment

### Critical — Hard Stops

| Risk                                           | Required mitigation                                                                 |
| ---------------------------------------------- | ----------------------------------------------------------------------------------- |
| Unsafe destination or ambient root redirection | Physical script root, every-component symlink/nonregular rejection, full preflight. |
| Overbroad rewrite of identities/local state    | Fixed allowlist and exact context/token boundaries with negative fixtures.          |
| Real rename applied during preparation         | Fixture-only apply; parent real-checkout operation is dry-run only.                 |

### Warnings — Must Address

- Preserve raw bytes/newlines/modes and avoid hardlink alias writes through atomic replacement.
- Wire the new suite explicitly; its name does not match release test discovery.
- Do not promise cross-file transactionality or race-proof containment under hostile mutation.
- Do not claim generated bundles, remote redirects, or installation behavior were exercised by local fixtures.

### Advisories

Keep stable relative diff labels and concise summaries. The broader prose and operational inventory belongs to the later flip; it must not silently expand this tool's remit.

## Task Breakdown Preview

### Phase 1: Concurrent Implementation

Run wrapper/engine implementation and independent fixtures/validator wiring concurrently after agreeing the contract; documentation synthesis is a separate nonoverlapping slice. Use the assigned checkout only, with no per-task worktree setup and no mid-flight tests, lint, builds, or formatters.

### Phase 2: Parent Integration and Verification

After all slices land, the parent integrates and runs direct fixture tests, scope regression, inventory validation, lint, and the full CI-equivalent validation. Capture a complete read-only real-checkout dry-run diff. No actual rename apply is allowed.

### Phase 3: Adversarial Review and Shipping

Review correctness, security boundaries, tests, and preparation scope; fix substantive findings and verify affected gates. Parent opens the PR with the reviewed preview and exercised evidence, handles CI/review, and merges only after required gates succeed. Hosting rename and YAN-1138 activation remain separate.

## Decisions Needed

None remain for this feature contract. Research proposals for default preview/`--apply`, ambient `PROJECT_ROOT`, Perl, permissive literal matching, zero-match failure, and implicit regeneration were rejected in favor of the settled behavior above. Verification results are pending parent execution, not unresolved product design.

## Research References

- [Executable PRP plan](../../prps/plans/completed/rename-repo.plan.md)

## Evidence Status

This specification synthesizes seven read-only research streams. No tests, builds, linters, structural validators, dry-runs, apply runs, remote operations, or shipping gates were executed for this documentation assignment. Acceptance and validation statements above are requirements, not claimed results.
