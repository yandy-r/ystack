# Plan: YAN-1172 — `install.sh --target omp` lifecycle (install, package, update, remove, migrate, dry-run)

## Summary

This plan adds an `omp` target to `install.sh`. The target drives the `omp plugin` CLI through a new tested
helper, `scripts/omp_install.py`, which mirrors `scripts/codex_install.py`. The helper:

- exports the generated OMP packages into a ycc-owned marketplace directory;
- registers that directory as marketplace `ycc`;
- installs or upgrades each selected `<pkg>@ycc` at `--scope user` (default) or `--scope project`
  (`--project`);
- records ownership, so `remove` deletes only ycc-owned state;
- implements `--dry-run` itself, because omp 18.12.3 ignores `--dry-run` for `upgrade`, `enable` and
  `marketplace add`.

`migrate --target omp` retires early manual installs: `omp plugin link`, and a checkout-root marketplace
that falls back to the Claude catalog. A stateful fake `omp` makes every lifecycle × package × scope case
hermetic. An opt-in live harness checks the same flow against real omp.

## User Story

As an oh-my-pi user, I want `./install.sh install --target omp [--project] [--dry-run]` to install, update
and remove ycc natively and idempotently, so that I get `/ycc:*`, skills and agents without hand-running
`omp plugin` commands or risking my own plugins and settings.

## Problem → Solution

| Before                                                                       | After                                                                         |
| ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `install.sh` has no omp target; packages only install via the opt-in harness | `--target omp` with install, update (re-run), remove, migrate and `--dry-run` |
| `marketplace add <checkout>` silently installs the Claude tree               | always a validated export with `.omp-plugin/marketplace.json`                 |
| No ownership record, so manual cleanup can delete user state                 | `~/.config/ycc/omp-native-install.json`; remove acts only on recorded items   |

## Metadata

- **Linear / GitHub:** YAN-1172 / #393. **Project:** P-YAN-21. **Target release:** v6.1.0. The PR goes into
  `main` and states the target release in its body (RELEASING.md, trunk-only, tracker `none`).
- **Complexity:** Large, with about 25 files.
- **Spec:** [feature-spec.md](feature-spec.md). It records live omp 18.12.3 evidence, the edge cases and
  decisions D1–D12.
- **Research dispatch:** a single researcher (a codebase scout plus live omp sandbox probes), not the
  seven-agent enhanced fan-out. The format follows `--parallel --enhanced`.
- **Execution mode:** parallel, 3 batches, max width 6.

## Batches

| Batch | Tasks                        | Depends On | Parallel Width |
| ----- | ---------------------------- | ---------- | -------------- |
| B1    | 1.1, 1.2, 1.3, 1.4, 1.5      | —          | 5              |
| B2    | 2.1, 2.2, 2.3, 2.4, 2.5, 2.6 | B1         | 6              |
| B3    | 3.1                          | B2         | 1              |

- **Total tasks:** 12. **Total batches:** 3. **Max parallel width:** 6.

## Worktree Setup

- **Parent**: .claude/worktrees/ystack-yan-1172-omp-install-lifecycle/ (branch: feat/yan-1172-omp-install-lifecycle)

## Contract (shared by all tasks; do not change without updating every consumer)

### `scripts/omp_install.py` CLI

Exit codes:

| Code | Meaning                                                                    |
| ---- | -------------------------------------------------------------------------- |
| 0    | ok                                                                         |
| 1    | `available`/`listed` false                                                 |
| 2    | `[err] native OMP install stopped: <reason>` (stderr), no further mutation |

| Command                                                                                                    | Behaviour                                                                                                                                     |
| ---------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `available`                                                                                                | `omp` (`$OMP_BIN` or PATH) runs and `omp --version` ≥ `generate_omp_packages.MIN_OMP_VERSION`. Prints the version, or the reason on stderr.   |
| `listed`                                                                                                   | Exits 0 iff an `included` native omp row has `listed: true`.                                                                                  |
| `install --packages CSV --scope user\|project --project-root DIR --mode local\|repo [--dry-run] [--force]` | An empty CSV means every included native omp row. Rejects non-included rows with the model reason.                                            |
| `remove --scope user\|project --project-root DIR [--dry-run]`                                              | Removes recorded installs in that scope for the current profile. The marketplace and export go only when nothing recorded or unowned remains. |
| `migrate [--apply]`                                                                                        | Dry-run unless `--apply`. Called by `install_migrate.py`; the Python API is `omp_install.migrate(apply: bool) -> None`.                       |

Output lines are prefixed `[ok]`, `[!!]`, `[err]`, or `[dry-run] would run: omp …` for previews. Every
mutating omp call is echoed as `[ok] omp <argv>` before it runs (the codex `cli()` pattern).

### Paths

- **State:** `~/.config/ycc/omp-native-install.json` (schema in the spec, Data model). It is keyed by profile,
  using the output of `omp config path`.
- **Export:** `${XDG_DATA_HOME:-~/.local/share}/ycc/omp-marketplace`. **Never create `$XDG_DATA_HOME/omp`**:
  that directory opts omp into XDG routing and would relocate the user's omp state.

### Shell contract (`targets/omp.sh`)

**Required functions:**

| Function                  | Value or behaviour                                      |
| ------------------------- | ------------------------------------------------------- |
| `omp_valid_steps`         | `base`                                                  |
| `omp_intent_steps`        | `base` and `plugins` map to `base`; others map to empty |
| `omp_config_groups`       | empty                                                   |
| `omp_supports_repo_mode`  | `omp_install.py listed`                                 |
| `omp_reads_agents_skills` | returns 1                                               |
| `sync_omp_target`         | sync entry point                                        |
| `remove_omp_target`       | remove entry point                                      |

**New optional hooks:** the generic shell calls these only when `declare -F` finds them.

- `omp_preflight`: availability check, plus a `$HOME` check when the scope is project.
- `omp_in_all`: available and listed.
- `omp_project_steps`: `base`.

### install.sh flags

`--dry-run` is new. It is accepted by `install`, `sync` and `remove` only when every resolved target is `omp`.
The shell exports it to the target as `DRY_RUN=1`.

### Fake omp (`scripts/tests/install/fake_omp.py`)

- **State:** kept under `${FAKE_OMP_HOME:-$HOME/.fake-omp}`. `OMP_PROFILE` and `--profile` select a separate
  root.
- **Logging:** each argv is appended as `omp <args>` to `${FAKE_OMP_LOG:-$CLAUDE_STUB_LOG}`.
- **Version:** `FAKE_OMP_VERSION` (default `18.12.3`).
- **Failure injection:** `FAKE_OMP_FAIL=<verb>[:<target>]` makes the first matching call exit 1.
- **Fidelity:** it emulates every 18.12.3 behaviour in the spec's live table.

## UX Design

### Before

`./install.sh install --target omp` fails with `Unknown target: omp (supported: claude cursor codex opencode agents, all)`.

### After

```text
$ ./install.sh install --target omp
[ok] exported OMP packages → ~/.local/share/ycc/omp-marketplace (ycc 6.1.0)
[ok] omp plugin marketplace add ~/.local/share/ycc/omp-marketplace
[ok] omp plugin install --scope user ycc@ycc
[ok] ycc@ycc 6.1.0 installed (user)
[ok] running omp sessions: run /reload-plugins (skills, commands, agents, MCP)
[!!] OMP has no trust prompt: installed plugin code runs with your user privileges.
$ ./install.sh install --target omp            # re-run
[ok] ycc@ycc 6.1.0 up to date (user)
$ ./install.sh remove --target omp --only base --dry-run
[dry-run] would run: omp plugin uninstall --scope user ycc@ycc
[dry-run] would run: omp plugin marketplace remove ycc
[dry-run] would remove ~/.local/share/ycc/omp-marketplace
```

### Interaction Changes

| Touchpoint                    | Before              | After                                                                                             |
| ----------------------------- | ------------------- | ------------------------------------------------------------------------------------------------- |
| `--target` values/completions | no `omp`            | `omp`, and `--dry-run` on install/sync/remove                                                     |
| `--project`                   | mcp only            | also omp `base` (omp `--scope project`, prints the shadowing note)                                |
| `--target all`                | 5 targets           | omp joins only when omp ≥ 18.12.2 is on PATH **and** an omp row is listed; otherwise an info line |
| `migrate --target`            | claude/codex/cursor | also `omp`; `all` unchanged plus an omp hint                                                      |

## Mandatory Reading

| Priority | File                                                        | Why                                                                                                                        |
| -------- | ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| P0       | `docs/plans/yan-1172-omp-install-lifecycle/feature-spec.md` | Live omp behaviour, quirks, decisions D1–D12, edge cases                                                                   |
| P0       | `scripts/codex_install.py`                                  | The native-install helper to mirror: `guarded`, `inventory`, `load_state`/`save_state`, `cli()`, ownership-before-mutation |
| P0       | `scripts/lib/install/targets/codex.sh`                      | Target contract header and `run_native_codex_install` dispatch                                                             |
| P0       | `scripts/lib/install/steps.sh`                              | `resolve_targets`, `preflight_targets`, `preflight_step_support`, `run_target`, `resolve_skills_home`                      |
| P1       | `scripts/package_install_plan.py`                           | `TARGETS`, `CARRIERS`, `plan_install` rejection reasons                                                                    |
| P1       | `scripts/install_migrate.py`                                | `Migration`, dry-run default, preflight-before-apply                                                                       |
| P1       | `scripts/tests/install/lib.sh`                              | `STUB_BIN`, `run_install`, `install_must_succeed`, `assert_*`                                                              |
| P1       | `scripts/test_codex_install.py`                             | unittest structure, fake CLI side effects, `snapshot()` no-mutation helper                                                 |
| P1       | `scripts/test-omp-native-packages.sh`                       | Sandbox pattern (bwrap/env -i, XDG, git isolation) for the live harness                                                    |
| P2       | `scripts/generate_omp_packages.py`                          | `--export DIR`, `MIN_OMP_VERSION`, `export_destination`                                                                    |
| P2       | `docs/internal/adr/0002-omp-runtime-contract.md`            | Resolve paths through omp; `disable --scope project` is the per-project switch; trust                                      |

## External Documentation

| Topic                      | Source                                                                                    | Key takeaway                                                                                                        |
| -------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Marketplace CLI and scopes | <https://github.com/can1357/oh-my-pi/blob/main/docs/marketplace.md>                       | `/reload-plugins` vs restart; the shadowing rule; marketplace remove does not uninstall; shared version-keyed cache |
| Plugin manager plumbing    | <https://github.com/can1357/oh-my-pi/blob/main/docs/plugin-manager-installer-plumbing.md> | Not transactional; no lockfile locking; `--dry-run` only for install/link/uninstall previews                        |
| Live CLI surface (18.12.3) | feature-spec.md § External Dependencies                                                   | Exact rc and messages for every verb, including the dry-run and GC quirks                                           |

## Patterns to Mirror

### NAMING_CONVENTION

```python
# scripts/codex_install.py:65,87 — state path + echoed CLI wrapper
def state_path() -> Path:
    return Path.home() / ".config/ycc/codex-native-install.json"
def cli(*args: str, check: bool = True, capture: bool = False) -> str:
    print(f"[ok] codex {' '.join(args)}", flush=True)
```

### ERROR_HANDLING

```python
# scripts/codex_install.py:396-401 — one exit path, exit 2, no traceback
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"[err] native Codex install stopped: {error}", file=sys.stderr)
        return 2
```

### OWNERSHIP_BEFORE_MUTATION

```python
# scripts/codex_install.py:246-250 — never claim a pre-existing registration
    if registered is None:
        state["marketplace"] = expected
        save_state(state)
    if use_cli:
        cli("plugin", "marketplace", "add", target, ...)
```

### TARGET_CONTRACT (shell)

```bash
# scripts/lib/install/targets/opencode.sh:24-51
opencode_valid_steps() { echo "base,skills,agents,commands,settings,rules,mcp"; }
opencode_supports_repo_mode() { return 1; }
opencode_reads_agents_skills() { return 0; }
```

### NATIVE_DISPATCH (shell)

```bash
# scripts/lib/install/targets/codex.sh:65-67
run_native_codex_install() {
    local -a command=(python3 "${SCRIPT_DIR}/scripts/codex_install.py" "$1" --mode "${MODE:-local}")
    codex_plugin_cli_supported && command+=(--cli)
```

### MIGRATION_DRY_RUN

```python
# scripts/install_migrate.py:257-263 — "would remove" vs apply
        print(f"[ok] {'remove' if self.apply else 'would remove'} {path}")
        if self.apply:
            ...
```

### TEST_STRUCTURE (install suites)

```bash
# scripts/tests/install/packages.sh:13-18
home="$(new_home)"
install_must_succeed_stubbed "${home}" install --target claude --package ycc --skills-home native
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${calls}" "plugin install ycc@ycc" "claude ycc package installs ycc@ycc"
```

### TEST_STRUCTURE (Python)

- `scripts/test_codex_install.py` uses unittest. It patches `Path.home`, and its `snapshot()` asserts that
  nothing mutated.
- Python tests that build fixture git repos must strip inherited `GIT_*` variables with
  `patch.dict(os.environ, filtered, clear=True)`. This is a repo rule: the pre-push hook exports `GIT_DIR`.

## Files to Change

| File                                                        | Action | Task                           |
| ----------------------------------------------------------- | ------ | ------------------------------ |
| `scripts/omp_install.py`                                    | CREATE | 1.1                            |
| `scripts/tests/install/fake_omp.py`                         | CREATE | 1.2                            |
| `scripts/package_install_plan.py`                           | UPDATE | 1.3                            |
| `scripts/test_package_install_plan.py`                      | UPDATE | 1.3                            |
| `scripts/lib/install/targets/omp.sh`                        | CREATE | 1.4                            |
| `install.sh`                                                | UPDATE | 1.5                            |
| `scripts/lib/install/steps.sh`                              | UPDATE | 1.5                            |
| `scripts/lib/install/core.sh`                               | UPDATE | 1.5                            |
| `scripts/lib/install/migrate.sh`                            | UPDATE | 1.5                            |
| `scripts/completions/ycc.bash`                              | UPDATE | 1.5                            |
| `scripts/completions/_ycc`                                  | UPDATE | 1.5                            |
| `scripts/completions/ycc.fish`                              | UPDATE | 1.5                            |
| `scripts/test_omp_install.py`                               | CREATE | 2.1                            |
| `scripts/install_migrate.py`                                | UPDATE | 2.2                            |
| `scripts/tests/install/omp.sh`                              | CREATE | 2.3                            |
| `scripts/tests/install/lib.sh`                              | UPDATE | 2.3                            |
| `scripts/tests/install/core.sh`                             | UPDATE | 2.3                            |
| `scripts/tests/install/build.sh`                            | UPDATE | 2.3                            |
| `scripts/tests/install/migrate.sh`                          | UPDATE | 2.3                            |
| `scripts/test-install-sync.sh`                              | UPDATE | 2.3                            |
| `scripts/test-omp-install-lifecycle.sh`                     | CREATE | 2.4                            |
| `scripts/validate.sh`                                       | UPDATE | 2.5                            |
| `scripts/lib/validate-scope.sh`                             | UPDATE | 2.5                            |
| `scripts/test-validate-scope.sh`                            | UPDATE | 2.5                            |
| `pyproject.toml`                                            | UPDATE | 2.5                            |
| `ycc/settings/packages.json`                                | UPDATE | 2.6                            |
| `ycc/skills/_shared/references/target-capability-matrix.md` | UPDATE | 2.6                            |
| `docs/install/omp.md`                                       | CREATE | 2.6                            |
| `docs/install/README.md`                                    | UPDATE | 2.6                            |
| `docs/install/v6/README.md`                                 | UPDATE | 2.6                            |
| `README.md`                                                 | UPDATE | 2.6                            |
| `AGENTS.md`                                                 | UPDATE | 2.6                            |
| `CONTRIBUTING.md`                                           | UPDATE | 2.6                            |
| `docs/internal/adr/0002-omp-runtime-contract.md`            | UPDATE | 2.6 (follow-up table row only) |

Generated copies of `target-capability-matrix.md` live under `packages/*`, `.agents-plugin`, `.codex-plugin`
and `.opencode-plugin`. They are regenerated by `./scripts/sync.sh` in 3.1 and are **never hand-edited**.

## NOT Building

- **Not shipping new packages.** `ycc-mcp`, `ycc-hooks` and `ycc-rules` OMP packages are YAN-1173–1175. The
  installer picks them up from the model with no code change once they are flipped to `included`.
- **No listing.** The OMP catalog stays unlisted (YAN-1180). Listing turns on `--mode repo` and `--target all`
  inclusion automatically.
- **No `installer-fallback` file copies for omp.** `config.yml`, `modelRoles` and rules snippets are YAN-1175.
  There is no fallback path for omp.
- **No cross-tool skill dedupe.** Copies in `~/.agents/skills` are only reported by install and migrate.
  YAN-1176 decides the policy.
- **No `enable`/`disable` surface.** Users run `omp plugin disable --scope project ycc@ycc` themselves; the docs
  say so.
- **No `plugin-overrides.json` writes.** ADR 0002 says overrides are not a kill switch.
- **No global `--dry-run` for other targets.** The flag is omp-only and errors elsewhere.

## Step-by-Step Tasks

### Task 1.1: Native OMP install helper — Depends on [none]

- **BATCH**: B1
- **ACTION**: Create `scripts/omp_install.py` (stdlib only, `mypy --strict` clean) implementing the CLI and
  Python API in the Contract.
- **IMPLEMENT**:
  - **Read-only `OmpCli`:** `version()`, `profile_key()` (`omp config path`), `installed()` (parses
    `plugin list --json`), `marketplaces()` (strict text parse; unknown shapes fail closed).
  - **Mutating wrapper:** `run(*argv, cwd)` echoes `[ok] omp …`. In dry-run it prints
    `[dry-run] would run: omp …` and only `install --dry-run` and `uninstall --dry-run` are executed.
  - **Export:** `generate_omp_packages.py --export <staging>` (a sibling temp dir), then
    `validate_omp_native.py --export <staging>`. Compare the staging inventory with the recorded one; when
    they differ, swap atomically with `os.replace` after verifying that the current dir's inventory matches
    the record. An edited or unrecorded dir is refused unless `--force`.
  - **Plan:** for each selected package and scope, choose one of `add`, `update-marketplace`, `install`,
    `upgrade --scope S`, `force-reinstall` (dangling `installPath`, or `--force`), or `up-to-date`.
  - **Refuse before any mutation** when: the `ycc` marketplace has a foreign source; a `ycc` runtime link is
    present (`"npm"` entry named after a package); the project root is `$HOME`; or a package is not an
    included native omp row (reuse `package_install_plan.plan_install(model, pkgs, ("omp",))` for the reason
    text).
  - **Record state before each create.** Roll back only what this run created (`marketplace remove ycc`,
    restore the previous export) when a later step fails.
  - **After user-scope mutations,** check each recorded project install in this profile for a dangling
    `installPath`, and print the repair command `cd <root> && ./install.sh install --target omp --project`.
  - **Messages:** print the reload/restart message from the package-model components: `hooks` means restart,
    otherwise `/reload-plugins`. Project installs also print the shadow note, and a ycc-skill overlap in
    `~/.agents/skills` is warned.
  - **Remove:** uninstall recorded `(package, scope, project_root)` entries that are still at the recorded
    marketplace. Remove the marketplace only when it is recorded, its source is unchanged, and no `*@ycc`
    install remains in any visible scope; otherwise print `[!!] kept marketplace ycc: …`. Delete the export
    only when no profile references it and its inventory matches the record. Prune state, and delete the
    state file when it is empty.
  - **`migrate(apply)`:** follow the spec Migration table.
- **MIRROR**: NAMING_CONVENTION, ERROR_HANDLING, OWNERSHIP_BEFORE_MUTATION; reuse `codex_install.guarded`,
  `inventory`, `merge_managed_config.atomic_write`, and `package_model.load_package_model`.
- **IMPORTS**: `argparse`, `json`, `os`, `re`, `shutil`, `subprocess`, `sys`, `tempfile`, `pathlib`;
  `from generate_omp_packages import MIN_OMP_VERSION`; `from merge_managed_config import atomic_write`;
  `from package_model import load_package_model`; `from package_install_plan import plan_install`.
- **GOTCHA**:
  - Never pass `--dry-run` to `upgrade`, `enable` or `marketplace add`; they mutate (verified).
  - Always pass `--scope` explicitly, because both-scope installs error otherwise.
  - Run project-scope calls with `cwd=project_root`.
  - Strip `GIT_*` when calling git or the generators.
  - Never create `$XDG_DATA_HOME/omp`.
  - `marketplace list --json` returns text.
  - Version comes from the export's `.claude-plugin/plugin.json`.
- **VALIDATE**: `python3 -m mypy --strict scripts/omp_install.py` (via `./scripts/validate.sh --only types`
  after 2.5), then manually: `python3 scripts/omp_install.py available; echo $?`.

### Task 1.2: Stateful fake `omp` — Depends on [none]

- **BATCH**: B1
- **ACTION**: Create `scripts/tests/install/fake_omp.py`, an executable Python script that emulates the
  omp 18.12.3 behaviours listed in feature-spec.md § External Dependencies.
- **IMPLEMENT**:
  - **Supported commands:**
    - `--version` and `[--profile N] config path`;
    - `plugin marketplace add|remove|update|list`;
    - `plugin discover`;
    - `plugin install|uninstall|upgrade|enable|disable|list --json|link|doctor --json`.
  - **Scopes:** project root is the nearest ancestor with `.omp/`, else with `.git`. It errors at `$HOME`.
  - **Cache:** real cache dirs are named `<mkt>___<plugin>___<ver>` and hold a copy of the plugin source.
  - **Quirks to reproduce:**
    - `--dry-run` is honoured only by install and uninstall;
    - a duplicate marketplace add or install exits 1 with the real messages;
    - an upgrade GCs caches not referenced by the user registry or the cwd project;
    - marketplace add falls back to `.claude-plugin/marketplace.json`;
    - a link conflict yields `Runtime package name "<n>" conflicts`;
    - `shadowedBy` and `enabled` fields appear in list output;
    - reinstall and upgrade preserve the disabled state.
  - **Logging and failure injection:** log each argv to `FAKE_OMP_LOG`/`CLAUDE_STUB_LOG`, and support
    `FAKE_OMP_FAIL` injection and `FAKE_OMP_VERSION`.
- **MIRROR**: The Python `codex` fake in `scripts/tests/install/codex.sh` (the emulate-plus-log approach).
- **IMPORTS**: stdlib only.
- **GOTCHA**: Keep messages byte-identical to the spec table, because the helper's parser and tests depend
  on them. The live harness (2.4) is the guard against fake drift.
- **VALIDATE**: `python3 scripts/tests/install/fake_omp.py --version` prints `omp/18.12.3`. The full
  coverage comes through 2.1 and 2.3.

### Task 1.3: Planner accepts the omp target — Depends on [none]

- **BATCH**: B1
- **ACTION**: Add `"omp"` to `TARGETS` and `CARRIERS["omp"] = {"skills": "base", "agents": "base", "commands": "base", "shared": "base"}`
  in `scripts/package_install_plan.py`, and update its tests.
- **IMPLEMENT**:
  - Extend `test_closures` with `("ycc", "omp", ("base",))`.
  - Extend `test_rejections` with every non-included omp row (`ycc-mcp`, `ycc-hooks`, `ycc-rules`:
    deferred; `ycc-all`: excluded or the dependency-proof message).
  - Keep the `--target all` skip expectations: omp is not part of the `all` list passed in that test.
- **MIRROR**: Existing `CARRIERS` entries and table-driven `test_closures`.
- **GOTCHA**: Update the printed test count in `__main__` if one is added. Hooks, mcp and rules get no
  carrier until YAN-1173–1175, so they fail closed with "no installer carrier".
- **VALIDATE**: `python3 scripts/test_package_install_plan.py`

### Task 1.4: omp target library — Depends on [none]

- **BATCH**: B1
- **ACTION**: Create `scripts/lib/install/targets/omp.sh` implementing the shell contract and dispatching
  to `omp_install.py`.
- **IMPLEMENT**:
  - **Header:** the contract header comment.
  - **Contract functions** (see the Contract table):
    - `omp_valid_steps`, `omp_intent_steps` (`base|plugins` map to `base`; everything else is empty),
      `omp_config_groups`;
    - `omp_supports_repo_mode` (runs `python3 …/omp_install.py listed`);
    - `omp_reads_agents_skills`, which returns 1. Its comment says that OMP reads `~/.agents/skills` but
      the native package cannot shed its skills, so consolidation cannot apply; the overlap is reported by
      the helper.
  - **Optional hooks:**
    - `omp_preflight` runs `omp_install.py available`; on failure it errors "omp >= 18.12.2 is required
      for --target omp".
    - `omp_in_all` returns `available && listed`.
    - `omp_project_steps` echoes `base`.
  - **`sync_omp_target`:**
    - `validate_only_steps omp`;
    - when `step_enabled base` and the build is not skipped, run the build passes for skills, agents,
      commands and packages through `run_build_script` on `generate-omp-<pass>.sh` and
      `validate-omp-<pass>.sh`;
    - then run `omp_install.py install --packages "${PACKAGE:-}" --scope <user|project from step_scope omp base> --project-root "$(project_root)" --mode "${MODE}"`,
      adding `--dry-run` when `DRY_RUN=1` and `--force` when `FORCE=1`.
  - **`remove_omp_target`:** run `omp_install.py remove` with the same scope, root and dry-run flags.
- **MIRROR**: TARGET_CONTRACT, NATIVE_DISPATCH, and the codex.sh build-pass loop at lines 320-335.
- **GOTCHA**: `step_scope` returns `global` unless `--project` is set; map `global` to `user`. Keep the
  `${PACKAGE:-}` empty-means-default contract.
- **VALIDATE**: `bash -n scripts/lib/install/targets/omp.sh && shellcheck scripts/lib/install/targets/omp.sh`

### Task 1.5: Generic shell wiring, `--dry-run`, project scope, `all`, migrate, completions — Depends on [none]

- **BATCH**: B1
- **ACTION**: Wire the omp target and the new optional hooks into `install.sh`, `steps.sh`, `core.sh`,
  `migrate.sh` and the three completion files.
- **IMPLEMENT**:
  - **`install.sh`:**
    - `ALL_TARGETS=(claude cursor codex opencode agents omp)`, kept on one line (the test lib parses it
      with sed).
    - Parse `--dry-run`, which sets `DRY_RUN=1` and is exported.
    - After `resolve_targets`, reject `--dry-run` unless every target is omp:
      `--dry-run is only supported by the omp target`.
    - Allow `--dry-run` with `remove`.
    - `usage()`: the target lists, the "all" description, an omp example block, and the `--dry-run` and
      `--project` text.
  - **`steps.sh`:**
    - In `resolve_targets` for `all`, skip a target whose optional `<t>_in_all` returns false, with
      `info "--target all: skipping omp (needs omp >= 18.12.2 on PATH and a listed OMP package)"`.
    - Make the `--mode repo` warning list computed instead of hard-coded.
    - `preflight_targets` calls the optional `<t>_preflight`.
    - `preflight_step_support` uses `step_allows_project`, and its error text lists omp `base`.
  - **`core.sh`:** add `step_allows_project <t> <step>`, which returns `step_supports_project` or the step
    is in the optional `<t>_project_steps`. `step_supports_project` stays mcp-only, since it is the
    default-to-project rule.
  - **`migrate.sh`:**
    - Accept `omp` in the target loop and error message.
    - `all` keeps `claude,codex,cursor` and adds the info line "omp: run migrate --target omp separately".
    - Before calling Python with omp, check `omp_install.py available`.
  - **Completions:** add `omp` to the `--target` values (install/sync/remove and migrate), and add
    `--dry-run` to the install, sync and remove words in all three shells.
- **MIRROR**: The existing `declare -F`-free contract calls in `steps.sh`; follow the same style
  (`is_known_target "$1" && "${1}_…"`) and guard optional hooks with `declare -F "${t}_x" >/dev/null`.
- **GOTCHA**:
  - Each optional hook must be absent-safe for the five existing targets.
  - `remove` currently rejects `--mode`; do not change that.
  - `print_native_deprecation_hints` must stay claude/codex/cursor only.
  - `resolve_skills_home` must remain unaffected (`omp_reads_agents_skills` returns 1).
- **VALIDATE**: `bash -n install.sh scripts/lib/install/*.sh && ./install.sh --help | grep -q -- '--dry-run'`

### Task 2.1: Hermetic helper test matrix — Depends on [1.1, 1.2, 1.3]

- **BATCH**: B2
- **ACTION**: Create `scripts/test_omp_install.py` (unittest, `mypy --strict`). It runs the helper
  in-process against `fake_omp.py` on a temp PATH with a temp `HOME` and isolated XDG variables.
- **IMPLEMENT**: Use table-driven cases, one assertion group per acceptance criterion:

  | Area               | What to assert                                                                                                                                                                                                  |
  | ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
  | Matrix             | Every included omp package from the model, and a fixture export with two packages (patch the export function), × {user, project} × {install, update, remove, dry-run}                                           |
  | Idempotency        | A second install makes zero mutating fake calls                                                                                                                                                                 |
  | Update             | After a lockstep fixture bump, `marketplace update` and `upgrade --scope S` run                                                                                                                                 |
  | Disabled preserved | A user-disabled install stays disabled and is not re-enabled                                                                                                                                                    |
  | Ownership          | A pre-existing unrecorded `ycc@ycc` is never uninstalled; the marketplace is kept while it remains; a foreign marketplace and a link refuse before any mutation; an unrecorded export dir is refused            |
  | Dry-run            | Fake state and the ycc state file are byte-identical before and after; the log holds only read verbs plus `install --dry-run`/`uninstall --dry-run`                                                             |
  | Partial failure    | `FAKE_OMP_FAIL=install` after a fresh add rolls back the marketplace and state; a failure on the second package keeps the first recorded and re-run completes                                                   |
  | GC hazard          | A user upgrade that dangles a recorded project prints the repair command; the repair run force-reinstalls                                                                                                       |
  | Profiles           | `OMP_PROFILE=work` records a separate key; remove in the default profile leaves `work` untouched                                                                                                                |
  | Version and home   | `FAKE_OMP_VERSION=18.12.1` makes `available` exit 1; project scope at `$HOME` is refused                                                                                                                        |
  | Migration          | Link → uninstall; checkout-root Claude-fallback marketplace → retired and reinstalled; foreign kept; dry-run makes no mutation; re-run after apply is a no-op; `~/.agents/skills` overlap reported, not deleted |
  | Rejection          | Every non-included omp row is rejected with the model reason                                                                                                                                                    |

- **MIRROR**: TEST_STRUCTURE (Python): `test_codex_install.py`'s `snapshot()`, and `patch.dict(os.environ, …, clear=True)` without `GIT_*`.
- **GOTCHA**: Build fixture git repos with `GIT_*` stripped. Never touch the real `~/.omp`; assert that `HOME` is under tmp.
- **VALIDATE**: `python3 scripts/test_omp_install.py`

### Task 2.2: `install_migrate.py` delegates omp — Depends on [1.1]

- **BATCH**: B2
- **ACTION**: Add `omp` to the accepted `--targets` in `main()`, and add `Migration.omp()`, which calls
  `omp_install.migrate(self.apply)`.
- **IMPLEMENT**:
  - Preflight runs for the whole selection: when omp is selected, call `omp_install` availability before
    any target applies, and fail closed with `[err] migration stopped: omp …`.
  - Keep the unsupported-target error for anything else.
- **MIRROR**: MIGRATION_DRY_RUN, plus the `codex_eligible` preflight placement in `main()`.
- **GOTCHA**: Keep the existing claude, codex and cursor behaviour byte-identical (the migrate suite asserts
  their output).
- **VALIDATE**: `python3 scripts/install_migrate.py --targets omp` (a dry-run against the fake on PATH), then
  `bash scripts/tests/install/migrate.sh`.

### Task 2.3: install.sh-level omp suite and harness wiring — Depends on [1.2, 1.4, 1.5]

- **BATCH**: B2
- **ACTION**: Create `scripts/tests/install/omp.sh`. Update `lib.sh`, `core.sh`, `build.sh`, `migrate.sh`
  and the `scripts/test-install-sync.sh` suite list.
- **IMPLEMENT**:
  - **`lib.sh`:** add an `omp` stub to `STUB_BIN` that runs `fake_omp.py`. It defaults to version
    `18.12.3` with nothing listed, so `--target all` skips omp in every existing suite.
  - **`omp.sh` cases:**
    - `install --target omp` calls marketplace add and install with `--scope user`;
    - a re-run makes no mutating calls;
    - `--project` from `home/project` (`git init`) uses `--scope project`; `--project` still errors for
      `--target cursor --only base`;
    - `--dry-run` is accepted for omp and rejected for `--target codex` and `--target all`;
    - `remove --target omp --only base` and `remove … --project`;
    - `install --target omp --package ycc-mcp` is rejected as deferred;
    - `--mode repo --target omp` errors while unlisted;
    - `--target all` prints the omp skip line;
    - with `FAKE_OMP_VERSION=18.12.1`, `--target omp` errors before other targets run;
    - `sync --target omp --intent plugins` maps to base; `--intent settings` warns "not supported".
  - **`core.sh`:** the contract loop already covers omp through `ALL_TARGETS`. Assert that the completions
    offer `omp` and `--dry-run`.
  - **`build.sh`:** `BUILD_PASSES[omp]="skills agents commands packages"` and include omp in the real-build
    case.
  - **`migrate.sh`:** add `migrate --target omp` dry-run and `--apply` against a link fixture; `--target all`
    prints the omp hint.
  - **`test-install-sync.sh`:** add `omp` to the suite loop.
- **MIRROR**: TEST_STRUCTURE (install suites); end the suite with `[[ "${BASH_SOURCE[0]}" == "$0" ]] && install_tests_finish`.
- **GOTCHA**:
  - `run_install` puts `STUB_BIN` before the real PATH; the stub must shadow a real `omp` on developer
    machines.
  - Set `FAKE_OMP_HOME` per sandbox home.
  - `CLAUDE_STUB_LOG` is the shared call log.
- **VALIDATE**: `bash scripts/tests/install/omp.sh && scripts/test-install-sync.sh`

### Task 2.4: Opt-in live harness against real omp — Depends on [1.1, 1.4, 1.5]

- **BATCH**: B2
- **ACTION**: Create `scripts/test-omp-install-lifecycle.sh`, which is not part of CI. It runs the real
  `./install.sh` against real omp inside the `test-omp-native-packages.sh` sandbox (bwrap with
  `--unshare-net`, or `--allow-env-i`; env -i HOME/XDG/TMPDIR under `mktemp -d /tmp/omp-install-lifecycle.XXXXXX`).
- **IMPLEMENT**: Use `YCC_INSTALL_SKIP_BUILD=1` and `OMP_BIN` support. Steps:
  1. Run install `--dry-run` and verify nothing was written.
  2. Run install (user), check `plugin list --json`, and re-run to assert no mutating `[ok] omp` lines.
  3. Run install `--project` in a `git init` project and assert `shadowedBy`.
  4. Disable at project scope with `omp plugin disable --scope project`, re-run, and assert it is still
     disabled.
  5. Bump the export lockstep version (reuse the `omp_native_smoke.py bump` subcommand on the recorded
     export, then re-run) and assert the upgrade.
  6. Run remove `--project`, then remove (user), and assert absent: no registry entry, link or cache, and
     the `ycc` marketplace is gone.
  7. Run a migration: `omp plugin link <export>/packages/omp/ycc`, then `migrate --target omp`, then
     `--apply`, then install, and assert one ycc.
  8. Repeat the matrix with `OMP_PROFILE=work` and with an XDG data root (`mkdir $XDG_DATA_HOME/omp`).
- **MIRROR**: `scripts/test-omp-native-packages.sh` (`clean()`, `run()`, `record()`, `assert_rc`, `has`,
  `--keep`, and the transcript).
- **GOTCHA**: python3 and git must be reachable on the sandbox `safe_path`. The real home is hidden, so the
  repo path must be outside `$HOME` or bind-mounted read-only (`--ro-bind "$repo" "$repo"`).
- **VALIDATE**: `scripts/test-omp-install-lifecycle.sh --keep` (opt-in; run in 3.1).

### Task 2.5: Validate, scope and type wiring — Depends on [1.1, 1.2]

- **BATCH**: B2
- **ACTION**: Wire the new tests into `scripts/validate.sh`, the scope map and the mypy file list.
- **IMPLEMENT**:
  - **`scripts/validate.sh`:** in `run_config_part helpers`, add
    `python3 "${REPO_ROOT}/scripts/test_omp_install.py" || fail "test_omp_install.py"` and
    `python3 "${REPO_ROOT}/scripts/test_package_install_plan.py" || fail "test_package_install_plan.py"`
    (today it is unwired).
  - **`scripts/lib/validate-scope.sh`:**
    - `scripts/omp_install.py | scripts/test_omp_install.py` → `config omp`;
    - `scripts/tests/install/fake_omp.py` → `config`;
    - `scripts/test-omp-install-lifecycle.sh` → `omp`;
    - `scripts/package_install_plan.py | scripts/test_package_install_plan.py` → `config`.
  - **`scripts/test-validate-scope.sh`:** add the matching `expect_targets` lines.
  - **`pyproject.toml`:** add `scripts/omp_install.py` and `scripts/test_omp_install.py` to `[tool.mypy] files`.
- **MIRROR**: The existing `test_codex_install.py` line in `helpers`, and the `scripts/install_migrate.py`
  scope line at `validate-scope.sh:107`.
- **GOTCHA**: `scripts/*.py` automatically adds `types`; expectations must include it (for example
  `config omp types`).
- **VALIDATE**: `scripts/test-validate-scope.sh && ./scripts/validate.sh --only scope,types`

### Task 2.6: Docs, model notes, capability matrix — Depends on [1.4, 1.5]

- **BATCH**: B2
- **ACTION**: Document the omp lifecycle and flip the descriptive model and matrix state. Edit sources only.
- **IMPLEMENT**:
  - **New `docs/install/omp.md`:**
    - prerequisites: omp ≥ 18.12.2 and the trust warning;
    - install, update, `--project`, `--dry-run`, remove and migrate;
    - reload vs restart, project shadowing, and `omp plugin disable --scope project ycc@ycc`;
    - profiles and XDG;
    - pre-release status (unlisted until YAN-1180).

    Only `ycc@ycc` IDs may appear, because `validate_install_doc_ids.py` scans it.

  - **`docs/install/README.md`:** the runtime table, the `--target` lists, the migrate targets and the scope
    table.
  - **`docs/install/v6/README.md`:** the `--target all` sentence (omp joins only once listed).
  - **`README.md`:** the install block and the guides table.
  - **`AGENTS.md`:** an install-table row for OMP.
  - **`CONTRIBUTING.md:158`:** drop "`install.sh --target omp` is YAN-1172" and describe the target.
  - **`ycc/settings/packages.json`:** the `ycc`/omp note, and the `installer-fallback`/omp gate (remove
    the satisfied YAN-1172 gate and keep YAN-1175).
  - **`target-capability-matrix.md`:** set `INSTALL_PATH` omp from `unsupported` to `partial`, and rewrite
    the `**INSTALL_PATH:omp**`, `**SKILLS:omp**` and packaging-status prose.
  - **ADR 0002:** in the follow-up table, mark YAN-1172 delivered.
- **MIRROR**: The `docs/install/codex.md` section layout and the existing matrix note style.
- **GOTCHA**:
  - `validate_capability_matrix.py` requires a `**INSTALL_PATH:omp**` note for `partial`.
  - Packages-model gate edits must pass `validate.sh --only packages`.
  - Never edit generated matrix copies.
- **VALIDATE**: `./scripts/validate.sh --only packages,inventory`

### Task 3.1: Sync, full validation, live smoke — Depends on [2.1, 2.2, 2.3, 2.4, 2.5, 2.6]

- **BATCH**: B3
- **ACTION**: Regenerate, run the full gate, and run the opt-in live harness. Fix fallout in the owning files.
- **IMPLEMENT**: Run `./scripts/sync.sh`, then `./scripts/validate.sh` and `npm run lint:modified`. Then run
  `scripts/test-omp-install-lifecycle.sh` and `scripts/test-omp-native-packages.sh` (the regression check).
  Record the omp version and pass lines in the PR body with "Target release: v6.1.0".
- **MIRROR**: The YAN-1171 PR evidence format.
- **GOTCHA**: The pre-push hook runs the full `validate.sh` (about 280 s). Push async with a long timeout.
- **VALIDATE**: All commands in Validation Commands exit 0.

## Testing Strategy

### Unit Tests

| Test file                                       | Covers                                                                                                            |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `scripts/test_omp_install.py`                   | Helper planning, ownership, idempotency, dry-run, rollback, GC repair, profiles, migration (package × scope × op) |
| `scripts/test_package_install_plan.py`          | omp closures and rejections                                                                                       |
| `scripts/tests/install/omp.sh`                  | install.sh arg wiring, scope, `--dry-run` gating, `all` skip, package rejection, intents, migrate                 |
| `scripts/tests/install/{core,build,migrate}.sh` | Contract, completions, build passes, migrate dispatch                                                             |
| `scripts/test-omp-install-lifecycle.sh`         | Live omp parity for the same flow (opt-in)                                                                        |

### Acceptance criteria → task → test

| Acceptance criterion (YAN-1172)                         | Task(s)       | Test(s)                                                                                |
| ------------------------------------------------------- | ------------- | -------------------------------------------------------------------------------------- |
| `--target omp`, package-aware native path               | 1.4, 1.5, 1.3 | `omp.sh` install/package cases; `test_package_install_plan.py`                         |
| `marketplace add`, `install --scope user\|project`      | 1.1           | `test_omp_install.py` matrix; `omp.sh` `--project`; live steps 2–3                     |
| Upgrade (update)                                        | 1.1           | `test_omp_install.py` update; live step 5                                              |
| Enable/disable respected; disable is the project switch | 1.1, 2.6      | `test_omp_install.py` disabled-preserved; live step 4; `docs/install/omp.md`           |
| Uninstall / remove deletes only ycc-owned state         | 1.1           | `test_omp_install.py` ownership cases; `omp.sh` remove; live step 6                    |
| Dry-run                                                 | 1.1, 1.5      | `test_omp_install.py` byte-identical dry-run; `omp.sh` `--dry-run` gating; live step 1 |
| Profile/XDG paths resolved through omp                  | 1.1           | `test_omp_install.py` profiles; live step 8                                            |
| `/reload-plugins` vs restart; project shadowing         | 1.1, 2.6      | `test_omp_install.py` message assertions; live step 3 (`shadowedBy`)                   |
| Idempotent re-run                                       | 1.1           | `test_omp_install.py` zero-mutation re-run; `omp.sh` re-run; live step 2               |
| Rollback and partial failure                            | 1.1           | `test_omp_install.py` `FAKE_OMP_FAIL` cases                                            |
| Migration avoids duplicates and preserves user data     | 1.1, 2.2      | `test_omp_install.py` migration; `migrate.sh`; live step 7                             |
| Tests for each package and scope                        | 2.1           | Table over model rows plus a two-package fixture × {user, project}                     |
| `sync.sh` and `validate.sh` pass                        | 3.1           | Full gate                                                                              |

### Edge Cases Checklist

- [ ] omp missing or `< 18.12.2`: an explicit target errors in preflight; `all` skips
- [ ] foreign `ycc` marketplace or `ycc` link: refused before any mutation, with a migrate hint
- [ ] `--project` at `$HOME`: refused
- [ ] both scopes installed: every call passes `--scope`
- [ ] user upgrade dangling a recorded project cache: warned, and repaired with `--force`
- [ ] disabled install: upgraded but kept disabled
- [ ] edited or unrecorded export dir: refused, unless `--force`
- [ ] different `OMP_PROFILE`: state isolated
- [ ] remove with no state: no-op, exit 0
- [ ] `--mode repo` while unlisted: explicit errors, `all` skips

## Validation Commands

### Static Analysis

```bash
bash -n install.sh scripts/lib/install/*.sh scripts/lib/install/targets/*.sh
npm run lint:modified
./scripts/validate.sh --only types
```

### Unit Tests

```bash
python3 scripts/test_omp_install.py
python3 scripts/test_package_install_plan.py
bash scripts/tests/install/omp.sh
scripts/test-install-sync.sh
scripts/test-validate-scope.sh
./scripts/validate.sh --only config,omp,packages,scope
```

### Full Test Suite

```bash
./scripts/sync.sh
./scripts/validate.sh
```

### Manual Validation

```bash
scripts/test-omp-install-lifecycle.sh --keep       # opt-in live omp 18.12.3 (bwrap or --allow-env-i)
scripts/test-omp-native-packages.sh                # regression: YAN-1171 package harness still passes
```

## Acceptance Criteria

- [ ] `./install.sh install|sync|remove --target omp` works at user and project scope, with `--package` and `--dry-run`
- [ ] A re-run makes no mutating omp call. Remove leaves non-recorded state untouched
- [ ] `./install.sh migrate --target omp [--apply]` retires link and checkout-root installs without duplicates
- [ ] Every row in the "Acceptance criteria → task → test" table has a passing test
- [ ] `./scripts/sync.sh` and `./scripts/validate.sh` pass; the live harness passes on omp 18.12.3

## Completion Checklist

- [ ] Tasks 1.1–3.1 done; no generated file hand-edited (`packages/omp/`, `.omp-plugin/`, matrix copies)
- [ ] Docs updated (`docs/install/omp.md`, the READMEs, AGENTS.md, CONTRIBUTING.md, the matrix, the ADR follow-up row)
- [ ] `ycc/settings/packages.json` notes and gates updated; `validate.sh --only packages` is green
- [ ] The PR body states "Target release: v6.1.0" and the live harness evidence

## Risks

| Risk                                                                     | Likelihood | Impact | Mitigation                                                                                           |
| ------------------------------------------------------------------------ | ---------- | ------ | ---------------------------------------------------------------------------------------------------- |
| The fake drifts from real omp behaviour                                  | M          | H      | The live harness (2.4) exercises the same flow; fake messages are copied byte-for-byte from the spec |
| An omp update changes `marketplace list` text or the `list --json` shape | M          | M      | Strict parsing that fails closed; the floor check; the pinned harness                                |
| User-scope upgrade GC of other projects' caches (upstream)               | H          | M      | Dangling check plus a repair hint; file upstream ([INFERENCE] an omp bug, not documented)            |
| The new `steps.sh` hooks regress existing targets                        | L          | H      | Hooks are optional (`declare -F`); the existing suites run unchanged in `test-install-sync.sh`       |
| Concurrent omp writers (no lock)                                         | L          | M      | Documented; ycc makes serial calls only                                                              |

## Notes

- **Open questions (non-blocking, reversible):**
  - **D4:** should `--target all` include omp before listing? Proposed: no.
  - **D11:** should migrate delete `~/.agents/skills` copies? Proposed: no; YAN-1176 owns this.
- **Hand-off to YAN-1173–1175:** flipping an omp row to `included` needs no installer change apart from a
  `CARRIERS["omp"]` entry for the new component (`mcp`, `hooks` or `rules` → `base`). The restart message
  follows from the `hooks` component automatically.

## Implementation Notes (deviations from this plan)

Recorded during implementation (2026-10-20). Live omp 18.12.3 re-probed in an `env -i` sandbox; the fake
was diffed against the real binary (identical normalized stdout, stderr and rc over the lifecycle sequence).

- **Live facts beyond the spec table:**
  - `install --dry-run` on an already-installed scope exits 1, so the helper previews only planned new
    installs (`install --dry-run`), planned force reinstalls (`install --force --dry-run`) and planned
    uninstalls. A fresh dry-run with no `ycc` marketplace prints only `would run` lines.
  - `upgrade --scope S` always reinstalls, even at the same version, so it runs only when versions differ.
  - `plugin list --json` is cwd-relative: project items appear only from inside that project.
  - omp GCs unreferenced caches on forced reinstall and on uninstall too, so the dangling-project check runs
    after every install-side change and after every real uninstall, not only user-scope ones.
  - `uninstall --dry-run --scope S` exits 1 when the plugin is installed only in the other scope; remove
    previews only entries that `plugin list --json` reports in that exact scope.
- **Shell (1.4/1.5):**
  - `--dry-run` and `--mode repo` skip the generate/validate build passes, so a preview never rewrites repo
    files.
  - Extra optional hooks `omp_all_skip_reason` and `omp_repo_mode_hint` keep omp text out of `steps.sh`.
  - The `--target all` skip notice prints only for install, sync and remove; `list-mcps` and completions skip
    omp silently, which keeps their output stable.
  - `remove --target omp` also requires an available omp (preflight).
- **Helper (1.1):** dry-run builds its staging export in a `TMPDIR` temp dir that is deleted afterwards.
  `migrate` with omp missing prints `[ok] omp: nothing to migrate (omp not found on PATH)`; through
  `install_migrate.py` the preflight stops first with `[err] migration stopped: omp unavailable: …`.
- **Types (2.5):** `scripts/tests/install/fake_omp.py` is also in `[tool.mypy] files` (it passes `--strict`).
- **Docs (2.6):** flipping `INSTALL_PATH:omp` to `partial` made the compatibility-audit check OM1 fail
  while `.omp-plugin/` is absent, so `audit-install-assumptions.sh` OM1 and `reading-the-report.md` now
  accept `partial` with no root catalog.
- **Live harness (2.4):** the upgrade step bumps a sandbox copy of the checkout (`ycc/.claude-plugin/plugin.json`)
  and runs that copy's `install.sh`, because the helper rebuilds the export each run and refuses an edited
  export. The migration link also targets that copy, so omp never touches the real checkout.
- **Pre-PR review fixes:**
  - Test isolation: `scripts/tests/install/lib.sh` unsets every `git rev-parse --local-env-vars` variable,
    so a sandbox `git init` under the lefthook pre-push hook cannot write into this repository; the
    `migrate.sh` omp fixture helpers drop `OMP_PROFILE`, `OMP_BIN` and `FAKE_OMP_LOG`.
  - Same-version content changes: when the export changed but a package version did not, install prints
    a `rerun with --force` hint instead of `up to date` (omp upgrades by version only); docs say so.
  - `migrate` is split into `plan_migrate` (read-only; every refusal, plus an export build and validation
    under `--apply`) and `apply_migrate`. `install_migrate.py` runs the plan in its shared preflight, so
    `--target claude,omp --apply` refuses before claude mutates.
  - `migrate` refuses (no mutation) while a legacy checkout-root install is disabled (a native reinstall
    would be enabled and ycc never toggles plugins) or has no native OMP package (`ycc-mcp` and friends);
    the message names the omp commands to run first.
  - `migrate --apply` records the owed native-install scopes in the state file (`migrate_pending`, keyed
    by profile) before the first uninstall; `install` clears its entry on success, a re-run finishes the
    rest, and a failure prints each `./install.sh install --target omp [--project]` still needed.
  - `migrate` uses the installer's project root (`project_root`: git toplevel, else cwd) through
    `--project-root`, not omp's `.omp`-first lookup, so migrated project installs stay removable.
  - `remove` checks the `ycc` marketplace source before uninstalling: a foreign source (not the recorded
    marketplace, export or repository) drops the records without uninstalling.
  - Install rollback restores the previous export whenever it was moved aside, even if the new export
    never landed (`moved_out`).
