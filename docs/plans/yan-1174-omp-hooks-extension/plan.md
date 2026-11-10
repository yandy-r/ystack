# Plan: YAN-1174 — ycc hooks on OMP: verdicts, guards and herdr-native proof

- **Linear:** YAN-1174 (P-YAN-21). **GitHub:** #407. **Target release:** ystack v6.1.0 (trunk-only; state it in the PR body).
- **Spec:** [`docs/research/yan-1174-omp-hooks-extension/feature-spec.md`](../../research/yan-1174-omp-hooks-extension/feature-spec.md) (all evidence, live probes, verdict table).
- **Contract:** [ADR 0002](../../internal/adr/0002-omp-runtime-contract.md) (amended here), spike §2.3–2.4, §3, §5.
- **Mirror:** YAN-1173 commit `749f155` (generator, validator, golden tests, model flip, docs, opt-in harness).

## Summary

ycc ships **no** OMP hook or extension. herdr session reporting on OMP is herdr's own first-party
integration (`herdr integration install omp`). A ycc reporter is ignored by herdr (`ycc:omp`) or
corrupts herdr's `seq` ordering (`herdr:omp`); both were verified live. `WorktreeCreate` is
unsupported because OMP has no such event.

The work makes that verdict explicit, enforced and tested:

- the `ycc-hooks` OMP row becomes `excluded`;
- the generator fails closed with a herdr-naming message;
- the validator rejects any OMP code surface in ycc packages and checks a hook-verdict table
  against the sources and docs;
- an opt-in live harness proves trigger, payload, error, timeout, cancellation and
  duplicate-freedom against a fake and an isolated herdr;
- the docs stop promising a ycc `session_start` shim.

## User Story

As an OMP user in herdr, I want herdr's own OMP integration, with no competing ycc reporter, so
that pane state, notifications and resume work. As a ycc maintainer, I want every ycc hook to
carry a tested OMP verdict that CI keeps honest.

## Problem → Solution

- **Problem:**
  - ADR 0002, the spike, the capability matrix, `packages.json` and `docs/install/omp.md` promise a
    ycc `session_start` herdr shim.
  - The generator names YAN-1174 as the hooks owner.
  - No test proves any hook verdict.
- **Solution:**
  - Record the evidence-backed verdicts: herdr reporting is native and herdr-owned; WorktreeCreate
    is unsupported; `herdr-agent-state.sh` is n/a.
  - Exclude the row and guard the OMP tree against code surfaces.
  - Add a drift check and a live harness.

## Metadata

| Field            | Value                                                                                                  |
| ---------------- | ------------------------------------------------------------------------------------------------------ |
| Complexity       | Medium (≈20 files; no runtime code)                                                                    |
| Source of truth  | `ycc/settings/packages.json`, `scripts/*.py`, docs; never hand-edit `packages/omp/**` or matrix copies |
| Languages        | Python 3.12 (mypy --strict files), Bash, Markdown                                                      |
| New runtime deps | none (no JS in CI; harness uses local `omp` + `herdr`)                                                 |
| Research         | Done (spec); external: OMP v18.12.5 source, herdr 0.8.2 binary + v0.9.5 docs                           |

## Batches

| Batch | Tasks              | Depends On | Parallel Width |
| ----- | ------------------ | ---------- | -------------- |
| B1    | 1.1, 1.2, 1.3, 1.4 | —          | 4              |
| B2    | 2.1, 2.2, 2.3      | B1         | 3              |
| B3    | 3.1                | B2         | 1              |

- **Total tasks:** 8. **Total batches:** 3. **Max parallel width:** 4.
- File ownership is disjoint inside each batch (checked in "Files to Change").

## Worktree Setup

- **Parent**: .omp/worktrees/ystack-yan-1174-omp-hooks-extension/ (branch: feat/yan-1174-omp-hooks-extension)

## UX Design

### Before

- `install.sh --target omp --package ycc-hooks` → `package 'ycc-hooks' is deferred or opt-in for target 'omp'`.
- The docs promise a future ycc herdr shim.

### After

- The same command → `package 'ycc-hooks' is excluded or opt-in for target 'omp'`
  (`package_install_plan.py:132` formats `entry.status`).
- `docs/install/omp.md` has a "herdr" section: run `herdr integration install omp` once, restart
  omp, and do not add a ycc or hand-made reporter.
- `install.sh --help` names herdr's integration.

### Interaction Changes

No new commands. The installer output for default `--target omp` is unchanged (`ycc`, `ycc-mcp`).

## Mandatory Reading

| File                                                                                  | Why                                                                               |
| ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `docs/research/yan-1174-omp-hooks-extension/feature-spec.md`                          | Verdicts, evidence, AC mapping, constants                                         |
| `scripts/generate_omp_packages.py:58-124`                                             | `COMPONENT_OWNERS`, `native_packages` fail-closed path                            |
| `scripts/validate_omp_native.py:36-44,139-151,202-243`                                | Constants, `inactive_root_errors`, `mcp_closure_errors`, `validate`               |
| `scripts/test_generate_omp_packages.py:43-112,193-212,442-446`                        | `with_omp`, fixture repo, fail-closed tests, repo-sync test                       |
| `scripts/test-omp-native-packages.sh:56-200,255-275`                                  | Sandbox pattern (`mktemp`, real-HOME guard, `env -i`, bwrap, null model provider) |
| `scripts/omp_native_smoke.py:1-60`                                                    | Typed subcommand driver pattern the new smoke driver mirrors                      |
| `docs/internal/adr/0002-omp-runtime-contract.md`                                      | Decision 3, package matrix row, required adapter 5, follow-up row                 |
| `docs/internal/spikes/omp-runtime-contract.md:20-26,336-353,381`                      | Summary §1, matrix rows, open question                                            |
| `ycc/skills/_shared/references/target-capability-matrix.md:76,97-105,381-391,416-421` | OMP packaging row, evidence bullet, HOOKS.\*:omp notes, INSTALL_PATH:omp          |

## External Documentation

- OMP v18.12.5: `docs/extensions.md`, `docs/extension-loading.md`, `docs/hooks.md`,
  `docs/marketplace.md:80` (restart for extensions).
- herdr v0.9.5: [Integrations § OMP](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.5/docs/next/website/src/content/docs/integrations.mdx),
  [Add Herdr support](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.5/docs/next/website/src/content/docs/add-herdr-support.mdx)
  (the `herdr:` prefix is reserved; `seq` must be monotonic).

## Patterns to Mirror

### NAMING_CONVENTION

```python
# scripts/validate_omp_native.py — one *_errors(root, …) -> list[str] per policy, aggregated in validate()
def mcp_closure_errors(root: Path, source_root: Path, package: Package) -> list[str]:
    rel = generator.package_root(package)
```

### ERROR_HANDLING

```python
# scripts/generate_omp_packages.py:116 — fail closed with the row path and the reason
raise ValueError(
    f"{where}: no OMP emitter for components {sorted(components)} (owned by {', '.join(owners)}); "
    "keep the row deferred and unlisted until its emitter lands"
)
```

### LOGGING_PATTERN

```python
# validator: print(f"validate_omp_native: {error}", file=sys.stderr); exit 1 if any error
```

### TEST_STRUCTURE

```python
# scripts/test_generate_omp_packages.py — fixture repo in tmp, model mutated via with_omp(...)
def test_included_rows_without_an_emitter_fail_closed(self) -> None:
    for key, owner in (("ycc-hooks", "YAN-1174"), ("ycc-rules", "YAN-1175")):
        with self.assertRaisesRegex(ValueError, rf"packages\.{key}\.runtimes\.omp: no OMP emitter.*{owner}"):
            self.output(with_omp(self.model, key, status="included"))
```

### LIVE_HARNESS

```bash
# scripts/test-omp-native-packages.sh — never the real HOME
root=$(mktemp -d /tmp/omp-native-packages.XXXXXX)
[[ "$root" != "$real_home" && "$root" != "$real_home"/* ]] || die 'sandbox must not live under the real HOME'
```

## Files to Change

| File                                                        | Action | Task | Change                                                                                                                          |
| ----------------------------------------------------------- | ------ | ---- | ------------------------------------------------------------------------------------------------------------------------------- |
| `ycc/settings/packages.json`                                | UPDATE | 1.1  | `ycc-hooks.runtimes.omp` → excluded, gates `[]`, new evidence + notes; `ycc-all.runtimes.omp.notes` drops ycc-hooks             |
| `scripts/test_package_model.py`                             | UPDATE | 1.1  | Add `test_omp_ycc_hooks_excluded`                                                                                               |
| `scripts/package_install_plan.py`                           | UPDATE | 1.1  | Comment at :53-54 (hooks: no OMP carrier, row excluded; rules YAN-1175)                                                         |
| `scripts/test_package_install_plan.py`                      | UPDATE | 1.1  | :67 expectation `is excluded or opt-in for target 'omp'`                                                                        |
| `scripts/tests/install/omp.sh`                              | UPDATE | 1.1  | :147-150 message `excluded`, label text                                                                                         |
| `scripts/test-release-bundle.sh`                            | UPDATE | 1.1  | :654 → `"                                                                                                                       | ycc-hooks | omp | excluded | native | no  | target v6.1.0 | "`and label`excluded omp target` |
| `install.sh`                                                | UPDATE | 1.1  | Help :299-300: `omp: ycc, ycc-mcp (ycc-rules deferred; ycc-hooks excluded: herdr reporting is 'herdr integration install omp')` |
| `scripts/generate_omp_packages.py`                          | UPDATE | 1.2  | `COMPONENT_REASONS` replaces `COMPONENT_OWNERS`; docstring :18-20                                                               |
| `scripts/test_generate_omp_packages.py`                     | UPDATE | 1.2  | Fail-closed test asserts herdr message; excluded row emits nothing and prunes the root; listed excluded fails                   |
| `scripts/validate_omp_native.py`                            | UPDATE | 1.3  | `hook_surface_errors`, `hook_verdict_errors`, constants, wiring in `validate()`, docstring                                      |
| `scripts/test_validate_omp_hooks.py`                        | CREATE | 1.3  | Golden tests for both new checks (D2–D6)                                                                                        |
| `docs/internal/adr/0002-omp-runtime-contract.md`            | UPDATE | 1.4  | Amend decision 3, package-matrix row, adapter 5, follow-up row; add an "Amendment (YAN-1174)" note                              |
| `docs/internal/spikes/omp-runtime-contract.md`              | UPDATE | 1.4  | §1 item 2 bullet, §3 rows (herdr, Cursor source, package ycc-hooks, ycc-all), §5 open question → settled                        |
| `ycc/skills/_shared/references/target-capability-matrix.md` | UPDATE | 1.4  | :76 OMP row, :97-105 evidence bullet, HOOKS.PreToolUse:omp note, INSTALL_PATH:omp sentence                                      |
| `docs/install/omp.md`                                       | UPDATE | 1.4  | :42-45, a new `## herdr` section, Reload/Restart wording, OMP Notes bullet                                                      |
| `docs/install/v6/README.md`                                 | UPDATE | 1.4  | :123 wording "`ycc-hooks` (not Codex or OMP; on OMP herdr ships its own integration)"                                           |
| `scripts/test-omp-herdr-hooks.sh`                           | CREATE | 2.1  | Opt-in live harness (L1–L8)                                                                                                     |
| `scripts/omp_herdr_smoke.py`                                | CREATE | 2.1  | Typed driver: fake socket recorder, RPC runner, assertions, isolated herdr probe                                                |
| `scripts/lib/validate-scope.sh`                             | UPDATE | 2.2  | Map new scripts                                                                                                                 |
| `scripts/test-validate-scope.sh`                            | UPDATE | 2.2  | `expect_targets` for the new scripts                                                                                            |
| `pyproject.toml`                                            | UPDATE | 2.2  | mypy files += `scripts/omp_herdr_smoke.py`, `scripts/test_validate_omp_hooks.py`                                                |
| `scripts/validate.sh`                                       | UPDATE | 2.2  | `omp` target: run `test_validate_omp_hooks.py`                                                                                  |
| generated matrix copies, `packages/omp/**`                  | REGEN  | 3.1  | `./scripts/sync.sh` (never hand-edit)                                                                                           |

Batch file-disjointness:

- B1: 1.1, 1.2, 1.3 and 1.4 touch disjoint files. 1.1 owns `packages.json`; 1.2 and 1.3 only read
  it in tests, through fixture models.
- B2: 2.1 owns the new harness files; 2.2 owns the wiring; 2.3 owns `CONTRIBUTING.md`, `README.md`
  and `AGENTS.md` (all disjoint).

## NOT Building

- Any ycc OMP extension, hook factory, tool module or `packages/omp/ycc-hooks` root.
- Any change to the Cursor or Claude `ycc-hooks` packages or to `herdr-session-start.sh`.
- Installing herdr's integration from `install.sh`. herdr owns it, and it is a user decision.
- Profile-specific herdr installs. That is documented only (herdr writes the default profile path).
- A JS runtime in CI.
- Status-line or status-bar ports (YAN-1175 and mods; unchanged).

## Step-by-Step Tasks

### Task 1.1: Model flip and dependent expectations — Depends on [none]

- **BATCH**: B1
- **ACTION**: Set `packages.ycc-hooks.runtimes.omp` to the spec's JSON (Data Models): `status`
  `excluded`, `listed` false, `gates` `[]`, `evidence` += the spec path, the new `notes`. In
  `ycc-all.runtimes.omp.notes`, replace "(the union of ycc, ycc-mcp, and ycc-hooks)" with "(on
  Claude the union of ycc, ycc-mcp, and ycc-hooks)" and "install those parts separately" with
  "install ycc and ycc-mcp separately; herdr reporting comes from `herdr integration install omp`".
  Update the dependent expectations.
- **IMPLEMENT**:
  - `test_package_model.py`: add `test_omp_ycc_hooks_excluded`, mirroring
    `test_codex_ycc_hooks_excluded` (status excluded, not listed, `gates == ()`).
  - `test_package_install_plan.py:67`: change the reason to `"is excluded or opt-in for target 'omp'"`.
  - `tests/install/omp.sh:147-150`: same message; label `rejected as excluded`.
  - `test-release-bundle.sh:654`: expect `| ycc-hooks | omp | excluded | native | no | target v6.1.0 |`.
    Excluded rows render `target …` exactly like the codex row asserted at :651.
  - `package_install_plan.py:53-54` comment: "hooks never get an OMP carrier (ycc-hooks is excluded
    on OMP: herdr ships its own integration); rules wait for YAN-1175".
  - `install.sh` help at :299-300.
- **MIRROR**: TEST_STRUCTURE; the YAN-1173 `packages.json` diff.
- **GOTCHA**:
  - `package_model.py:238` already rejects `listed=true` on excluded rows; keep `listed: false`.
  - The `evidence` path must exist. The spec file is committed in this PR, and
    `_evidence_errors` resolves it.
  - `test_omp_install.py:912` already includes `ycc-hooks` in `rejected`; it needs no change.
  - The `migrate` refusal text (`omp_install.py:1063`, "has no native OMP package yet") stays
    accurate; leave it alone.
- **VALIDATE**: `python3 scripts/test_package_model.py && python3 scripts/test_package_install_plan.py && bash scripts/tests/install/omp.sh`

### Task 1.2: Generator — herdr-naming fail-closed message — Depends on [none]

- **BATCH**: B1
- **ACTION**: In `scripts/generate_omp_packages.py`, replace `COMPONENT_OWNERS` (:62) with
  `COMPONENT_REASONS` (exact text in the spec, API Design). Build the error as
  `f"{where}: no OMP emitter for components {sorted(components)}: {reasons}"`, where `reasons`
  joins the sorted reasons for the unsupported components, with fallback `"no planned issue; keep
the row deferred and unlisted"`. Update the module docstring :18-20: "hooks never get an OMP
  emitter (herdr's own integration; ADR 0002, YAN-1174); rules are YAN-1175".
- **IMPLEMENT**: `test_generate_omp_packages.py`:
  - **D1** `test_included_rows_without_an_emitter_fail_closed`: `ycc-hooks` matches
    `herdr integration install omp` and `WorktreeCreate`, and must not contain `YAN-1174 extension`;
    `ycc-rules` still matches `YAN-1175`.
  - **D1b** new `test_excluded_hooks_row_emits_nothing_and_prunes_its_root`: start from
    `with_omp(self.model, "ycc-hooks", status="excluded")`, pre-create
    `packages/omp/ycc-hooks/package.json` with `{"omp":{"extensions":["./x.ts"]}}`, generate, then
    assert the root is gone. `native_package_roots` still owns it because the mechanism is native.
  - Existing `test_listed_deferred_row_fails_closed`: add a subTest for
    `status="excluded", listed=True`.
- **MIRROR**: ERROR_HANDLING.
- **GOTCHA**:
  - Keep the components-set logic: `{hooks}` is neither `WORKFLOW_COMPONENTS` nor `MCP_COMPONENTS`,
    so it fails only when the row is `included`. The excluded row is skipped at :110-111 before the
    check.
  - Typed `dict[str, str]`; mypy --strict.
- **VALIDATE**: `python3 scripts/test_generate_omp_packages.py && mypy scripts/generate_omp_packages.py scripts/test_generate_omp_packages.py`

### Task 1.3: Validator — code-surface guard and hook-verdict drift check — Depends on [none]

- **BATCH**: B1
- **ACTION**: Add to `scripts/validate_omp_native.py`:
  1. Constants `CODE_SURFACE_KEYS`, `CODE_SURFACE_DIRS`, `CODE_SUFFIXES` and `HOOK_VERDICTS`, plus
     `SPIKE_DOSSIER = Path("docs/internal/spikes/omp-runtime-contract.md")` and
     `HOOK_DOCS = (Path("docs/internal/adr/0002-omp-runtime-contract.md"), Path("docs/install/omp.md"), Path("ycc/skills/_shared/references/target-capability-matrix.md"))`.
  2. `hook_surface_errors(root: Path, model: PackageModel) -> list[str]`. For every root in
     `generator.native_package_roots(model.packages)` plus `generator.COMPONENT_ROOT` that exists,
     report:
     - (a) a `package.json` with a top-level `extensions`/`hooks`/`tools`, or an `omp`/`pi` object
       holding any `CODE_SURFACE_KEYS`;
     - (b) `.omp-plugin/plugin.json` or `.claude-plugin/plugin.json` with a `hooks`, `extensions` or
       `tools` key;
     - (c) a top-level directory named in `CODE_SURFACE_DIRS`;
     - (d) any file named `hooks.json` anywhere under the root;
     - (e) any `*.ts|*.js|*.mjs|*.cjs` file outside `skills/`. Skills may ship helper scripts, which
       OMP never loads as extensions.

     Message: `"{rel}: ycc OMP packages ship no hooks or extensions (herdr reporting is herdr's own integration; ADR 0002)"`.

  3. `hook_verdict_errors(source_root: Path) -> list[str]`. Derive the live hook set from:
     - `ycc/settings/hooks/*` files;
     - `ycc/settings/cursor/herdr-session-start.sh` if present;
     - events in `ycc/settings/cursor/hooks.json#hooks`, keyed `…#<event>`;
     - events in `ycc/settings/settings.json#hooks`;
     - events in `packages/claude/ycc-hooks/hooks/hooks.json#hooks`.

     Report each key missing from `HOOK_VERDICTS` (`"{key}: ycc hook has no OMP verdict; add it to HOOK_VERDICTS and the spike §3 matrix"`)
     and each stale `HOOK_VERDICTS` key. For each key, the spike dossier must contain a line with
     the anchor whose verdict cell holds the token. Finally, no `HOOK_DOCS` file and not the spike
     may contain the phrases `session_start shim`, `herdr extension shim`, `session_start\` extension shim`or`herdr \`session_start\` shim`.

  4. `validate()`: append `hook_surface_errors(root, model)`, and append
     `hook_verdict_errors(source)` only when `not export`. An export has no docs; `source` is the
     checkout either way, so run it once per invocation.

  Update the module docstring with both policies.

- **IMPLEMENT**: new `scripts/test_validate_omp_hooks.py` (unittest, typed, imports `validate_omp_native as policy`):
  - **D2** `test_package_json_extensions_rejected`: `omp.extensions`, `pi.extensions`, top-level
    `hooks`, and `tools` each produce the error (subTests).
  - **D2b** `test_manifest_hooks_key_rejected` (`.omp-plugin/plugin.json` `{"hooks": "./h"}`).
  - **D3** `test_hook_dirs_and_hooks_json_rejected`: `hooks/pre/x.ts`, `extensions/`, `tools/`, and
    a nested `skills/a/hooks.json` are each rejected.
  - **D4** `test_js_module_outside_skills_rejected_but_skill_helpers_allowed`.
  - **D4b** `test_current_repository_has_no_omp_code_surface`: `hook_surface_errors(REPO_ROOT, load_package_model()) == []`.
  - **D5** `test_reintroducing_a_ycc_herdr_extension_fails`: a fixture with
    `packages/omp/ycc-hooks/{package.json,.omp-plugin/plugin.json,extensions/herdr.ts}` on an
    included model gives the surface error. On the real model (excluded), `inactive_root_errors`
    also fires.
  - **D6** `test_verdict_table_matches_sources`: on a tmp copy of the six source files and the
    dossier:
    - the real files give `[]`;
    - adding `ycc/settings/hooks/new.sh` gives "has no OMP verdict";
    - adding `"Stop"` to the cursor hooks gives a missing `…#Stop`;
    - removing the dossier row gives the anchor error;
    - changing the token to `**adapter**` gives the token error;
    - inserting `herdr session_start shim` into the omp doc gives the phrase error.
  - **D6b** `test_repository_hook_verdicts_hold`: `hook_verdict_errors(REPO_ROOT) == []`. This
    passes only after Task 1.4; see the GOTCHA.
- **MIRROR**: NAMING_CONVENTION, TEST_STRUCTURE (`tempfile.TemporaryDirectory`, `assert_has`).
- **GOTCHA**:
  - D6b and `test_generate_omp_packages.py:442` depend on the 1.4 docs and the 3.1 regen. Run the
    full suite only in 3.1.
  - The dossier's verdict cell for the herdr row must read `**native**`. The ADR says "native
    (herdr-owned)"; keep the token check to the dossier only.
  - Skip non-UTF-8 files when scanning phrases.
- **VALIDATE**: `python3 scripts/test_validate_omp_hooks.py -k "not repository" && mypy scripts/validate_omp_native.py scripts/test_validate_omp_hooks.py`

### Task 1.4: Docs — remove every shim promise; record verdicts — Depends on [none]

- **BATCH**: B1
- **ACTION**: Edit the source docs only.
- **IMPLEMENT**:
  - **ADR 0002:**
    - Decision 3, second bullet → "herdr session reporting is **native and herdr-owned**: herdr's
      `herdr integration install omp` extension (v8) reports session and state. ycc ships no OMP
      reporter. herdr records only `herdr:`-sourced session reports, and a ycc copy under
      `herdr:omp` corrupts its `seq` ordering (verified live, YAN-1174)."
    - Package matrix `ycc-hooks` row → mechanism `none`, verdict `excluded`, notes "herdr
      reporting: `herdr integration install omp`; `WorktreeCreate` unsupported".
    - Required adapter 5 → strike it and state "dropped (YAN-1174): herdr ships the integration".
    - Follow-up row YAN-1174 → "Delivered: hook verdicts (herdr native via herdr's integration,
      `WorktreeCreate` unsupported), `ycc-hooks` excluded on OMP, validator guards, opt-in herdr
      harness".
    - Add a dated "Amendment (2026-10-21, YAN-1174)" paragraph under Status.
  - **Spike dossier:**
    - §1 item 2, `herdr` bullet → native (herdr-owned).
    - §3 herdr row → `herdr integration install omp` | **native** | "herdr-owned extension; ycc
      ships none (YAN-1174 live: `ycc:omp` session ignored, `herdr:omp` impersonation breaks `seq`)".
    - Cursor `hooks.json`/`herdr-session-start.sh` row → **native** "(superseded on OMP by herdr's
      integration)".
    - Package `ycc-hooks` row → none | **excluded**.
    - `ycc-all` row: drop `ycc-hooks` from the install list.
    - §5 open question at :381 → strike and mark settled with the YAN-1174 finding.
  - **Capability matrix source:**
    - :76 → "`ycc`, `ycc-mcp` generated, unlisted until v6.1.0; `ycc-rules` deferred to v6.1.0;
      `ycc-hooks` and `ycc-all` excluded (herdr: `herdr integration install omp`)".
    - Evidence bullet :97-105 → append "YAN-1174: ycc ships no OMP hooks; herdr reporting is
      herdr's own OMP integration".
    - HOOKS.PreToolUse:omp → replace "the only planned OMP hook … (YAN-1174)" with "ycc ships no
      OMP hooks; herdr session reporting is herdr's own integration (`herdr integration install omp`)
      and `WorktreeCreate` has no OMP event (YAN-1174)".
    - INSTALL_PATH:omp :420 → "`ycc-rules` is YAN-1175; `ycc-hooks` is excluded on OMP".
    - Keep the capability cells unchanged: the `unsupported` cells stay correct.
  - **`docs/install/omp.md`:**
    - :42-45 → "`ycc-rules` is deferred (YAN-1175); `ycc-hooks` and `ycc-all` are excluded".
    - New `## herdr` section after MCP Servers:
      - run `herdr integration install omp` once;
      - it writes `~/.omp/agent/extensions/herdr-omp-agent-state.ts`;
      - for a named profile, copy it to `~/.omp/profiles/<name>/agent/extensions/`;
      - restart omp sessions;
      - do not also install a project copy or a ycc/Cursor-style reporter, because a second
        `herdr:omp` reporter breaks herdr's state ordering;
      - verify with `herdr integration status` and `herdr pane get "$HERDR_PANE_ID"`.
    - "Reload Or Restart": keep the sentence. It stays true for any package.
    - "OMP Notes" bullet → "OMP never runs shell hooks; `WorktreeCreate` has no OMP event; herdr
      reporting comes from herdr's integration".
  - **`docs/install/v6/README.md`:123** wording.
- **MIRROR**: The YAN-1173 docs diff (matrix row and evidence bullet style; prettier
  `printWidth` 120 for tables).
- **GOTCHA**:
  - Do not edit the copies under `packages/`, `.codex-plugin/`, `.agents-plugin/` or
    `.opencode-plugin/`; `sync.sh` regenerates them.
  - `scripts/validate_install_doc_ids.py` (the `packages` target) checks that install docs mention
    excluded or deferred packages by bare name, never `ycc-hooks@ycc` for OMP.
  - Keep the `capability-matrix` table header untouched (`validate_capability_matrix.py`).
- **VALIDATE**: `python3 scripts/validate_install_doc_ids.py && python3 scripts/validate_capability_matrix.py && npx markdownlint-cli docs/install/omp.md docs/internal/adr/0002-omp-runtime-contract.md`

### Task 2.1: Opt-in live harness (trigger, payload, error, timeout, cancellation, duplicates) — Depends on [1.1, 1.2, 1.3]

- **BATCH**: B2
- **ACTION**: Create `scripts/test-omp-herdr-hooks.sh` and `scripts/omp_herdr_smoke.py`. Not CI.
- **IMPLEMENT**:
  - **Shell.** Copy the sandbox preamble from `test-omp-native-packages.sh:56-200`:
    - flags `--keep` and `--allow-env-i`;
    - `root=$(mktemp -d /tmp/omp-herdr-hooks.XXXXXX)` with the real-HOME guard;
    - `clean()` runs `env -i` with `HOME=$root/case/home` and XDG and TMPDIR inside `$root`;
    - bwrap `--tmpfs $real_home --unshare-net` when available;
    - the null model `models.yml` from :259-272.
    - **Never** pass a parent `HERDR_*` variable; `die` if `HERDR_SOCKET_PATH` resolves outside
      `$root`.
    - Preflight: `omp` ≥18.12.2 and `herdr` on PATH (`OMP_BIN`/`HERDR_BIN` override).
    - Install herdr's integration into the sandbox with
      `HOME=$case_home/home herdr integration install omp`, after
      `mkdir -p $case_home/home/.omp/agent/extensions`. Assert `herdr integration status` reports
      `omp: current`.
    - Export and install the ycc packages: `generate_omp_packages.py --export $root/export`, then
      `omp plugin marketplace add` and `install --scope user ycc@ycc ycc-mcp@ycc`, mirroring the
      existing harness's local fixture.
  - **Python** (`omp_herdr_smoke.py`, typed, subcommands):
    - `recorder SOCKET MODE OUT`: a fake herdr unix socket. Modes `ok` (reply
      `{"result":{"type":"ok"}}`), `stall` (accept, never reply), `refuse` (no socket file). It
      records JSONL with a timestamp.
    - `session OUT -- omp…`: runs `omp --mode rpc`, sends `get_state`, then `new_session`, then
      closes stdin after N s. It records the frames, `sessionId`, ready time and exit time.
    - `assert-*` checks.
    - `herdr-pane`: starts an isolated `herdr server` with `HOME`/`XDG_CONFIG_HOME`/`XDG_RUNTIME_DIR`
      under `$root` and `SHELL=/bin/sh`, creates a workspace, runs `omp` in pane `w1:p1`, and reads
      `pane.get`.
  - **Cases:**
    - **L1 trigger.** With `HERDR_ENV=1` and the sandbox socket and pane: exactly one
      `report_agent_session` with `session_start_source:"startup"` after start, and one with
      `"new"` after `new_session`.
    - **L2 payload.** Each session report has `pane_id`, `source=="herdr:omp"`, `agent=="omp"`,
      integer `seq` strictly increasing across all reports, and `agent_session_path` an absolute
      file whose name contains the RPC `sessionId`. It validates against
      `herdr api schema --json` → `PaneReportAgentSessionParams.required`.
    - **L3 fail-closed env.** Without `HERDR_*`: zero connections, session ready.
    - **L4 error.** Mode `refuse`: no `extension_error` frame, and `get_state` is answered.
    - **L5 timeout.** Mode `stall`: `get_state` is answered within 5 s of `ready`, the process exits
      within the scripted budget + 3 s, and no `extension_error` appears.
    - **L6 cancellation.** Mode `stall`, closing stdin right after `get_state`: exit within 3 s.
      OMP's `session_shutdown` cap is 2 s and herdr's timers are unref'd.
    - **L7 duplicates.** With the ycc packages installed: every recorded `source` is `herdr:omp`,
      and no `ycc` source exists. Exactly 2 records (session + state) per session event, so a
      second reporter would double them. `omp plugin list --json` shows no ycc package with
      `manifest.extensions`.
    - **L8 real herdr** (optional, `--herdr-pane`): in the isolated herdr server the pane reports
      `agent=="omp"` and `agent_session.source=="herdr:omp"`. Then send a `ycc:omp`
      `report_agent_session`; the pane's `agent_session.value` is unchanged (ycc reports are
      inert). Never use the real herdr socket.
- **MIRROR**: LIVE_HARNESS; `omp_native_smoke.py` subcommand style.
- **GOTCHA**:
  - herdr's integration gates on `ctx.hasUI === true`, so use `--mode rpc` (verified `hasUI:true`),
    not `-p`.
  - Use a short `sleep` budget; do not depend on inference.
  - `herdr pane run` types into the user's interactive shell, so set `SHELL=/bin/sh` and an empty
    `.zshrc` in the sandbox HOME.
  - Kill the herdr server process group in `cleanup`.
- **VALIDATE**: `bash -n scripts/test-omp-herdr-hooks.sh && shellcheck scripts/test-omp-herdr-hooks.sh && mypy scripts/omp_herdr_smoke.py && bash scripts/test-omp-herdr-hooks.sh --keep` (local, opt-in; record its output in the PR body)

### Task 2.2: Validation wiring — Depends on [1.2, 1.3]

- **BATCH**: B2
- **ACTION**:
  - `scripts/lib/validate-scope.sh`:
    - add `scripts/omp_herdr_smoke.py | scripts/test-omp-herdr-hooks.sh) echo "omp" ;;`;
    - add `scripts/test_validate_omp_hooks.py) echo "omp types" ;;` next to :84-87.
  - `scripts/test-validate-scope.sh`: matching `expect_targets` lines.
  - `pyproject.toml` mypy `files` += `scripts/omp_herdr_smoke.py`, `scripts/test_validate_omp_hooks.py`.
  - `scripts/validate.sh` `omp)` block (:271-274): after `test_generate_omp_packages.py`, add
    `echo "== test: omp hook verdicts and code-surface guard =="` and
    `python3 "${REPO_ROOT}/scripts/test_validate_omp_hooks.py" || fail "test_validate_omp_hooks.py"`.
- **MIRROR**: The YAN-1173 `validate-scope.sh` and `test-validate-scope.sh` diff.
- **GOTCHA**: The docs that `hook_verdict_errors` reads (`docs/install/omp.md`, the ADR and the
  spike) map to `packages` or nothing in validate-scope. Add `docs/internal/spikes/omp-runtime-contract.md | docs/internal/adr/0002-omp-runtime-contract.md) echo "omp" ;;`
  before the `docs/*` catch-all, and extend `docs/install/*` to `echo "packages omp"`. Update the
  scope tests accordingly.
- **VALIDATE**: `bash scripts/test-validate-scope.sh && mypy`

### Task 2.3: Repo docs index — Depends on [1.4]

- **BATCH**: B2
- **ACTION**:
  - `CONTRIBUTING.md:158`: add one sentence after the OMP packages line: "ycc ships no OMP hooks
    (`ycc-hooks` is excluded on OMP; herdr ships its own OMP integration); `validate_omp_native.py`
    rejects OMP code surfaces and checks the hook verdict table."
  - `README.md` scripts tree: add `test-omp-herdr-hooks.sh` (opt-in herdr proof).
  - `AGENTS.md:47`: unchanged (it lists `{ycc,ycc-mcp}`).
- **VALIDATE**: `npx markdownlint-cli CONTRIBUTING.md README.md`

### Task 3.1: Regenerate and full validation — Depends on [2.1, 2.2, 2.3]

- **BATCH**: B3
- **ACTION**:
  1. Run `./scripts/sync.sh`. It regenerates the matrix copies, `packages/omp/**` (no change
     expected besides the matrix copy) and the inventories.
  2. Run `./scripts/validate.sh` (~280 s).
  3. Fix any drift.
  4. Grep for leftover promises; it must return no matches:
     `rg -n "session_start shim|herdr extension shim|YAN-1174 extension" -g '!docs/research/**' -g '!docs/plans/**'`.
- **VALIDATE**: `./scripts/sync.sh && ./scripts/validate.sh && git status --short`
  (only intended files changed)

## Testing Strategy

### AC dimension → test (evidence)

| AC dimension         | Deterministic CI (Python, no JS)                                                                                                    | Opt-in live (`test-omp-herdr-hooks.sh`)                          | Prior evidence (spec)                           |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------- |
| Every hook verdict   | D6/D6b `hook_verdict_errors` (sources ↔ `HOOK_VERDICTS` ↔ dossier rows ↔ no shim phrases)                                           | —                                                                | Inventory table                                 |
| Trigger              | D1 generator refuses an included hooks row; D3/D5 no hook factories can ship (so ycc adds no trigger); WorktreeCreate verdict in D6 | L1 startup + `new` session events                                | [V-live] probe + fake socket                    |
| Payload              | —                                                                                                                                   | L2 schema-checked `herdr:omp` payload                            | [V-live] herdr reports                          |
| Blocking / error     | D2–D5 (no ycc code runs in OMP, so it cannot block)                                                                                 | L3 (env absent), L4 (refused socket)                             | OMP throw isolation [V-live]                    |
| Cancellation         | —                                                                                                                                   | L6 (stdin close with stalled socket)                             | OMP 2 s shutdown cap [V-src]                    |
| Timeout              | —                                                                                                                                   | L5 (stalled socket)                                              | [V-live] 3.03 s run                             |
| Duplicate prevention | D2–D5 (no `omp.extensions`, hooks, tools, `hooks.json` or JS modules), D1b (excluded root pruned), `inactive_root_errors`           | L7 (only `herdr:omp`, one pair per event), L8 (ycc report inert) | [V-live] ns-`seq` corruption, `ycc:omp` ignored |

### Unit Tests

- `test_generate_omp_packages.py`: D1, D1b, and excluded+listed fail-closed.
- `test_validate_omp_hooks.py`: D2, D2b, D3, D4, D4b, D5, D6, D6b.
- `test_package_model.py`: `test_omp_ycc_hooks_excluded`.
- `test_package_install_plan.py`, `tests/install/omp.sh`, `test-release-bundle.sh`: message and
  status updates.

### Edge Cases Checklist

- [ ] Excluded `ycc-hooks` root left on disk from an old checkout is pruned by the generator and
      flagged by `inactive_root_errors`.
- [ ] Skill helper `.js` files under `skills/` are not flagged (D4).
- [ ] A new hook script added to `ycc/settings/hooks/` fails CI until it has a verdict (D6).
- [ ] An export validation (`--export`) runs the surface check but not the doc check.
- [ ] Live harness refuses to run if a socket path or HOME escapes `$root`.

## Validation Commands

### Static Analysis

```bash
mypy   # pyproject [tool.mypy] files incl. new modules
./scripts/lint.sh --python --shell --docs
```

### Unit Tests

```bash
python3 scripts/test_generate_omp_packages.py
python3 scripts/test_validate_omp_hooks.py
python3 scripts/test_package_model.py
python3 scripts/test_package_install_plan.py
bash scripts/test-validate-scope.sh
```

### Full Test Suite

```bash
./scripts/sync.sh
./scripts/validate.sh            # ~280 s; also run by the lefthook pre-push hook
```

### Manual Validation

- [ ] `bash scripts/test-omp-herdr-hooks.sh --keep` passes L1–L7 locally (L8 with `--herdr-pane`);
      paste the summary into the PR.
- [ ] `./install.sh install --target omp --package ycc-hooks --dry-run` prints the `excluded`
      reason.

## Acceptance Criteria

- [ ] Every ycc hook has a documented OMP verdict, enforced by D6 (AC 1).
- [ ] Trigger, payload, blocking/error, cancellation, timeout and duplicate prevention each map to
      a test (table above) (AC 2).
- [ ] No doc promises a ycc `session_start` shim (D6 phrase check + Task 3.1 grep).
- [ ] Generator error names `herdr integration install omp`, not YAN-1174 as owner.
- [ ] `ycc-hooks` OMP row is `excluded`, unlisted, gates `[]`; YAN-1178 stays on the rows that ship.
- [ ] `./scripts/sync.sh` and `./scripts/validate.sh` pass.
- [ ] Neither the user's `~/.omp` nor the real herdr socket was touched by any test.

## Completion Checklist

- [ ] Code follows the `*_errors` validator pattern and typed generator style.
- [ ] Error messages are actionable (name the herdr command).
- [ ] Tests follow `unittest` + tmp-fixture patterns.
- [ ] Generated trees regenerated, never hand-edited.
- [ ] Docs updated: ADR 0002, spike, matrix source, `docs/install/omp.md`, `v6/README.md`,
      CONTRIBUTING, README.
- [ ] PR body: target release v6.1.0; live harness output; the decision log below.

## Decision Log

| #   | Decision                                                                                  | Rationale                                                                                                                                                                              |
| --- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | No ycc OMP extension (neither a `node:net` TS reporter nor `pi.exec` of the shell script) | herdr records only `herdr:`-sourced session reports. `herdr:omp` impersonation froze herdr state (ns vs µs `seq`). herdr's integration is a superset (state, blocked, resume) [V-live] |
| D2  | herdr verdict = native, herdr-owned                                                       | `herdr integration install omp` v8 exists, is maintained by herdr, and was exercised live against a fake socket                                                                        |
| D3  | `WorktreeCreate` = unsupported                                                            | No OMP event; shell hooks never run; OMP isolation owns its worktrees                                                                                                                  |
| D4  | `ycc-hooks` OMP row `excluded`, `gates: []`                                               | Nothing will ship. `deferred` would imply a future emitter. Precedent: `ycc-hooks`/codex and `ycc-all`/omp. YAN-1178 stays on shipping rows only                                       |
| D5  | Keep the generator fail-closed; replace the owner with an actionable reason               | Requested; prevents accidental re-inclusion                                                                                                                                            |
| D6  | Structural duplicate prevention + validator guard                                         | Strongest guarantee, CI-testable without JS; OMP dedupes extensions only by path                                                                                                       |
| D7  | Verdict drift check in `validate_omp_native.py`                                           | Keeps the inventory, the dossier and the user docs honest when hooks change                                                                                                            |
| D8  | Live proof is opt-in, sandboxed, fake + isolated herdr                                    | Needs `omp` + `herdr` binaries; matches the YAN-1171/1173 harness policy                                                                                                               |
| D9  | No `install.sh` step for herdr's integration                                              | herdr-owned file and user choice; docs give the one command                                                                                                                            |

## Risks

| Risk                                                                   | Likelihood | Impact | Mitigation                                                          |
| ---------------------------------------------------------------------- | ---------- | ------ | ------------------------------------------------------------------- |
| Doc phrase or anchor check too strict, breaking unrelated doc edits    | Medium     | Low    | Short anchors; error names the file, anchor and expected token      |
| herdr changes its integration (version, source, fields)                | Low        | Medium | L1/L2 pin observed behavior; docs cite herdr 0.8.2 / integration v8 |
| `test-release-bundle.sh` or other suites assert the old `deferred` row | High       | Low    | Enumerated in 1.1; Task 3.1 runs the full validator                 |
| Validate-scope misses doc paths and CI skips D6 on a docs-only change  | Medium     | Medium | Task 2.2 maps the ADR, spike and install docs to `omp`              |

## Notes

- Spec probes are reproducible from the harness. No probe touched `~/.omp` or the real herdr
  socket: every run used `/tmp` HOMEs and scrubbed `HERDR_*`.
- YAN-1178 (live matrix) may adopt `test-omp-herdr-hooks.sh`.
- Main approved this direction on 2026-10-21 (no ycc OMP extension; `ycc-hooks` excluded).
