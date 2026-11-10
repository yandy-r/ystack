# Plan: YAN-1175 — ycc rules, instructions, settings, model roles and approvals on OMP

- **Linear:** YAN-1175. **GitHub:** #412. **Target release:** ystack v6.1.0 (trunk only; state it in the PR body).
- **Spec:** [`docs/research/yan-1175-omp-rules-settings/feature-spec.md`](../../research/yan-1175-omp-rules-settings/feature-spec.md)
  (evidence, live probes, decisions D1–D10; all accepted by Main on 2026-10-21, D7 (a) included).
- **Contract:** [ADR 0002](../../internal/adr/0002-omp-runtime-contract.md). This plan amends: required adapter 4, the
  package-matrix rows for `ycc-rules`, `installer-fallback`, settings and status line, and the YAN-1175 follow-up row.
- **Mirrors:**
  - YAN-1173 commit `749f155` (new native OMP package: generator, validator, model flip, docs).
  - YAN-1174 plan (`docs/plans/yan-1174-omp-hooks-extension/plan.md`).

## Summary

ycc ships a native `ycc-rules` OMP package. It holds 31 flat rules named `ycc-<family>-<stem>.md`, with
`paths` mapped to `globs` and `description` kept. `alwaysApply` is emitted only when true. The package is
included and installed by default, and stays unlisted until YAN-1180.

`install.sh --target omp` gains two opt-in steps:

- `--settings` merges ycc-owned leaves into the user `<agentDir>/config.yml`:
  - `modelRoles.default`, `modelRoles.slow` and `modelRoles.task`;
  - `tools.approvalMode: write`.
  - Ownership is tracked by hash (`merge_managed_config.py`, new YAML format). User edits win, and a symlinked or
    invalid config is refused.
- `--rules` symlinks `ycc/settings/rules/AGENTS.md` to `<agentDir>/AGENTS.md`, and refuses to replace a real file.

`ycc/settings/models.json` gains `targets.omp`. A new `scripts/omp_model_policy.py` validates role names, selector
grammar, thinking levels, alias closure and snippet parity. The same module feeds the agent generator's
`opus`→`@slow` / `sonnet`→`@task` map. The status line is documented as unsupported. Project scope is rejected for
settings and rules.

## User Story

As an OMP user, I want the ycc rule families loaded natively. I also want ycc's model and approval defaults
available as an opt-in that never overwrites my edits, and my project's `.omp/` config and rules to always win.

## Problem → Solution

- **Problem:**
  - `ycc-rules` (OMP) and `installer-fallback` (OMP) are `deferred`.
  - The generator fails closed on `rules` ("owned by YAN-1175").
  - `models.json` has no OMP target, and the agent model map is hard-coded.
  - The OMP installer writes no config; `--intent settings` is "not supported".
- **Solution:**
  - Add a rules flattener plus generator and validator support.
  - Add a YAML managed-merge profile and OMP `settings`/`rules` installer steps (user scope only).
  - Add a model policy module with validation.
  - Flip both rows to `included`.
  - Update the docs: ADR, spike, capability matrix, install guide.

## Metadata

| Field            | Value                                                                                                                                         |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Complexity       | Large (≈30 files; Python + Bash + docs)                                                                                                       |
| Source of truth  | `ycc/rules/**`, `ycc/settings/{packages.json,models.json,omp/config.yml}`, `scripts/*.py`; never hand-edit `packages/omp/**` or matrix copies |
| Languages        | Python 3.11+ (mypy --strict files), Bash, Markdown                                                                                            |
| New runtime deps | none. PyYAML is already on the OMP path (`generate_codex_common`); `merge_managed_config.py` imports it lazily, in the YAML branch only       |
| Research         | Done (spec). External: OMP v18.12.5 source (`/tmp/omp-src-1175`)                                                                              |

## Batches

| Batch | Tasks              | Depends On | Parallel Width |
| ----- | ------------------ | ---------- | -------------- |
| B1    | 1.1, 1.2, 1.3, 1.4 | —          | 4              |
| B2    | 2.1, 2.2           | B1         | 2              |
| B3    | 3.1, 3.2           | B2         | 2              |
| B4    | 4.1                | B3         | 1              |
| B5    | 5.1                | B4         | 1              |

- **Totals:** 10 tasks in 5 batches; maximum parallel width is 4.
- **Ownership:** each file has exactly one owning task per batch (see "Files to Change"). A task may read, but never
  edit, files owned by a sibling in the same batch.

## Worktree Setup

- **Parent:** `.omp/worktrees/ystack-yan-1175-omp-rules-settings/`
  (branch `feat/yan-1175-omp-rules-settings`). All implementers work here; no child worktrees.

## UX Design

### Before

- `./install.sh install --target omp` installs `ycc@ycc` and `ycc-mcp@ycc`.
- `--package ycc-rules` → `package 'ycc-rules' is deferred or opt-in for target 'omp'`.
- `sync --target omp --intent settings` → `intent 'settings' is not supported by target 'omp'`, and no steps run.

### After

- `./install.sh install --target omp` installs `ycc@ycc`, `ycc-mcp@ycc` and `ycc-rules@ycc`.
  - The restart hint says rules apply to new sessions (`/new` or restart).
- `./install.sh install --target omp --settings` merges into `$(omp config path)/config.yml`:
  - `modelRoles.{default,slow,task}` and `tools.approvalMode: write`.
  - Per-leaf output reads `wrote`, `updated` or `kept (changed locally; --force to replace)`.
- `./install.sh install --target omp --rules` links `$(omp config path)/AGENTS.md`.
  - A real file is refused with the `link_rules_file` message.
- `--project` with `--settings` or `--rules` is rejected by the existing gate (`scripts/lib/install/steps.sh:475-476`):
  `--project is not supported by step 'settings' for target 'omp' (project scope currently supports: mcp; omp: base)`.
- `remove --target omp --intent settings,rules` deletes only unchanged ycc leaves and the owned symlink.

### Interaction Changes

| Touchpoint                       | Before                  | After                                                                |
| -------------------------------- | ----------------------- | -------------------------------------------------------------------- |
| Default OMP install              | 2 packages              | 3 packages (`ycc-rules` added)                                       |
| `--settings` / `--rules` on omp  | silently no step        | opt-in, user-scope merge and link                                    |
| `--intent settings,rules` on omp | "not supported" warning | maps to the `settings` / `rules` steps                               |
| `install.sh --help`              | omp: ycc, ycc-mcp       | omp: ycc, ycc-mcp, ycc-rules; `--settings`/`--rules` scopes list omp |

## Mandatory Reading

| File                                                                                   | Why                                                                                                                  |
| -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `docs/research/yan-1175-omp-rules-settings/feature-spec.md`                            | Evidence, data models, decisions, edge cases                                                                         |
| `scripts/generate_cursor_rules.py:73-160,271-330`                                      | `parse_frontmatter`, `validate_description`, normalize/dump, lint constants (`:95-96`)                               |
| `scripts/generate_omp_packages.py:61-132,196-260`                                      | Component sets, `COMPONENT_REASONS`, `native_packages`, `mcp_payloads`, `build_output`                               |
| `scripts/validate_omp_native.py:45-61,190-246,375-416`                                 | Root-entry constants, `inactive_root_errors`, `hook_surface_errors`, `mcp_closure_errors`, `validate`                |
| `scripts/merge_managed_config.py:1-31,54-189,300-312,386-445,1238,1341,1440-1456,1501` | Decision table, `PROFILES`, `load_source`, `adopt_matching_values`, `atomic_write`, format dispatch, symlink refusal |
| `scripts/generate_omp_agents.py:60-66,249-257`                                         | `MODEL_MAP`, `map_model`                                                                                             |
| `scripts/validate-model-settings.py` (whole, 101 lines)                                | Cross-target model validator; OMP section is added here                                                              |
| `scripts/omp_install.py:194-270,1203-1250`                                             | `OmpCli.profile_key` (`omp config path`), `available`, CLI dispatch                                                  |
| `scripts/lib/install/targets/omp.sh:19-46,112-175`                                     | Step contract, `sync_omp_target`, `remove_omp_target`                                                                |
| `scripts/lib/install/targets/claude.sh:274-298`, `core.sh:51-65,108-175`               | `merge_settings_config`, `link_rules_file`, `unlink_owned_link`, `remove_settings` call sites                        |
| `scripts/lib/install/steps.sh:25-51,157-190,470-478`                                   | `step_enabled` defaults, `config_groups_for_target` (group names must be intent names), project gate                 |
| `scripts/package_install_plan.py:18-62,128-165`                                        | `CARRIERS`, fallback-component handling (cursor hooks discard at `:144-145`)                                         |
| `scripts/build_package_graph.py:84-93`                                                 | `install_set` = own ∪ included `installer-fallback` components                                                       |

## External Documentation

OMP v18.12.5 docs:

- `docs/rulebook-matching-pipeline.md`: flat `rules/`, name = stem, `globs` advisory at `:248,321`.
- `docs/context-files.md`: `<agentDir>/AGENTS.md`.
- `docs/settings.md`:
  - layers at `:17-30` and `:112-127`; merge at `:165-169`;
  - `config set` writes the user file only, at `:96`.
- `docs/models.md:645-716`: selectors, `@role`, fallback.
- `docs/approval-mode.md:18-25,201`: modes; subagents run as `yolo`.

## Patterns to Mirror

### NAMING_CONVENTION

```python
# scripts/validate_omp_native.py:375 — one *_errors(...) -> list[str] per policy, aggregated in validate() (:400-416)
def mcp_closure_errors(root: Path, source_root: Path, package: Package) -> list[str]:
    rel = generator.package_root(package)
```

### PAYLOAD_PATTERN

```python
# scripts/generate_omp_packages.py:208-213 — per-package payloads from a source under repo_root
def mcp_payloads(packages: Iterable[Package], repo_root: Path = REPO_ROOT) -> dict[Path, Payload]:
    roots = [package_root(package) for package in packages if is_mcp_package(package)]
    if not roots:
        return {}
```

### ERROR_HANDLING

```python
# scripts/generate_omp_packages.py:121-127 — fail closed with the row path and a reason
raise ValueError(f"{where}: no OMP emitter for components {sorted(components)}: {reasons}")
```

### MANAGED_MERGE_PROFILE

```python
# scripts/merge_managed_config.py:166-188 — profile = format + groups of {path, policy}
"opencode-config": {"format": "json", "jsonc": True, "groups": {"settings": [{"path": ["model"], "policy": "scalar"}, ...]}}
```

### INSTALLER_CALL_SITE

```bash
# scripts/lib/install/targets/claude.sh:277-296 — merge, then link rules
merge_settings_config "claude-settings" "${SCRIPT_DIR}/ycc/settings/settings.json" "${HOME}/.claude/settings.json" "${claude_groups}"
link_rules_file "${SCRIPT_DIR}/ycc/settings/rules/CLAUDE.md" "${HOME}/.claude/CLAUDE.md"
```

### TEST_STRUCTURE

```python
# scripts/test_merge_managed_config.py:25-67 — tmp dir, YCC_MANAGED_CONFIG_STATE, subprocess run_merge(...)
# scripts/test_generate_omp_packages.py — fixture repo; model mutated via with_omp(model, key, status=...)
# scripts/test_generate_cursor_rules.py:26-60 — tmp ycc/rules tree; assert SystemExit/ValueError text
```

### LIVE_HARNESS

```bash
# scripts/test-omp-native-packages.sh — mktemp under /tmp, refuse a HOME under the real HOME, env -i, null model provider
```

## Files to Change

| File                                                              | Action | Task | Change                                                                                                                                     |
| ----------------------------------------------------------------- | ------ | ---- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `scripts/generate_omp_rules.py`                                   | CREATE | 1.1  | Flattener: naming, frontmatter, links, forbid-list, budget; `build_rules(src) -> dict[str, str]`, `write_tree(dest, dry_run)`              |
| `scripts/test_generate_omp_rules.py`                              | CREATE | 1.1  | Critical flattener tests (R1–R6)                                                                                                           |
| `scripts/merge_managed_config.py`                                 | UPDATE | 1.2  | YAML format branch (lazy `import yaml`), `omp-config` profile, symlink refusal, comment backup, round-trip check                           |
| `scripts/test_merge_managed_config.py`                            | UPDATE | 1.2  | `OmpYamlMergeTest` (M1–M7)                                                                                                                 |
| `scripts/omp_model_policy.py`                                     | CREATE | 1.3  | Pinned roles and levels, selector grammar, `omp_model_errors(...)`, `agent_model_map()`, `expected_snippet()`                              |
| `scripts/test_omp_model_policy.py`                                | CREATE | 1.3  | Critical policy tests (P1–P5)                                                                                                              |
| `ycc/settings/models.json`                                        | UPDATE | 1.3  | Add `targets.omp`; fix `$comment` (`validate-model-settings.py`, omp consumer)                                                             |
| `ycc/settings/omp/config.yml`                                     | CREATE | 1.3  | Managed snippet (spec "Managed snippet source")                                                                                            |
| `scripts/validate-model-settings.py`                              | UPDATE | 1.3  | Call `omp_model_policy.omp_model_errors`                                                                                                   |
| `scripts/generate_omp_agents.py`                                  | UPDATE | 1.3  | `MODEL_MAP = omp_model_policy.agent_model_map()` (output unchanged)                                                                        |
| `docs/internal/adr/0002-omp-runtime-contract.md`                  | UPDATE | 1.4  | Amendment line; rows `:78,82-84`; adapter 4 delivered; adapter 6 status-line note; YAN-1175 row `:137` delivered                           |
| `docs/internal/spikes/omp-runtime-contract.md`                    | UPDATE | 1.4  | §3 rows `:332-334,340-342,347,352`, §1 summary bullet `:25`                                                                                |
| `ycc/skills/_shared/references/target-capability-matrix.md`       | UPDATE | 1.4  | Packaging row `:76`, `INSTALL_PATH:omp` (`:407-422`), `AGENTS:omp` role-config sentence, `DANGEROUS_MODE:omp` note on `--settings` `write` |
| `docs/install/omp.md`                                             | UPDATE | 1.4  | `:39-46` packages; new sections Rules, Global Instructions, Settings And Model Roles, Approvals, Status Line; OMP Notes `:279-287`         |
| `docs/install/v6/README.md`                                       | UPDATE | 1.4  | `:40`, `:124` (`ycc-rules` on OMP)                                                                                                         |
| `ycc/rules/README.md`                                             | UPDATE | 1.4  | OMP section (flat names, advisory globs, override and disable)                                                                             |
| `CONTRIBUTING.md`, `README.md`                                    | UPDATE | 1.4  | `CONTRIBUTING.md:158`; `README.md:243,307` (`packages/omp/ycc-rules`)                                                                      |
| `scripts/generate_omp_packages.py`                                | UPDATE | 2.1  | `RULES_COMPONENTS`, `is_rules_package`, `rules_payloads`, `build_output`; drop `COMPONENT_REASONS["rules"]`; docstring `:18-21`            |
| `scripts/validate_omp_native.py`                                  | UPDATE | 2.1  | `RULES_ROOT_ENTRIES`, `rules_closure_errors`, wired in `validate()`                                                                        |
| `scripts/test_generate_omp_packages.py`                           | UPDATE | 2.1  | Replace the YAN-1175 fail-closed case (`:193-203`); G1–G3                                                                                  |
| `scripts/omp_install.py`                                          | UPDATE | 2.2  | `agent-dir` subcommand; `restart_line` mentions rules                                                                                      |
| `scripts/lib/install/targets/omp.sh`                              | UPDATE | 2.2  | Steps `base,settings,rules`; intents; `omp_config_groups` → `settings`; settings and rules blocks in sync and remove                       |
| `scripts/package_install_plan.py`                                 | UPDATE | 2.2  | `CARRIERS["omp"]["rules"] = "base"`; OMP drops inherited fallback components (opt-in only); comment `:53-55`                               |
| `install.sh`                                                      | UPDATE | 2.2  | Help: `--settings` `:241-245` and `--rules` `:250-254` scope lists add omp; `--package` `:320-322`                                         |
| `scripts/tests/install/omp.sh`                                    | UPDATE | 2.2  | Replace `:191-194`; add I1–I5                                                                                                              |
| `ycc/settings/packages.json`                                      | UPDATE | 3.1  | `ycc-rules.omp` and `installer-fallback.omp` → included (spec "Data Models")                                                               |
| `scripts/test_package_model.py`                                   | UPDATE | 3.1  | `test_omp_rules_rows_included`                                                                                                             |
| `scripts/test_package_install_plan.py`                            | UPDATE | 3.1  | `:39-40,52-53` closures; drop `ycc-rules`/omp at `:68`                                                                                     |
| `scripts/test_omp_install.py`                                     | UPDATE | 3.1  | `:418-419` default `("ycc","ycc-mcp","ycc-rules")`; `:912` drop `ycc-rules`                                                                |
| `scripts/test-release-bundle.sh`                                  | UPDATE | 3.1  | `MODEL_GENERATED` `:568-573` += 3 `ycc-rules` manifests; notes assertion `                                                                 | ycc-rules | omp | included | native | no  | 6.0.0 | `   |
| `scripts/lib/validate-scope.sh`, `scripts/test-validate-scope.sh` | UPDATE | 3.2  | Map the new scripts                                                                                                                        |
| `pyproject.toml`                                                  | UPDATE | 3.2  | mypy `files` += 4 new modules and tests                                                                                                    |
| `scripts/validate.sh`                                             | UPDATE | 3.2  | omp block `:260-279` += `test_generate_omp_rules.py`; helpers `:187-200` += `test_omp_model_policy.py`                                     |
| `scripts/test-omp-rules-settings.sh`                              | CREATE | 4.1  | Opt-in live harness (L1–L4)                                                                                                                |
| `packages/omp/ycc-rules/**`, matrix copies                        | REGEN  | 5.1  | `./scripts/sync.sh` (never hand-edit)                                                                                                      |

Batch file-disjointness:

- **B1:** 1.1 creates two new files. 1.2 owns the merge helper and its test. 1.3 owns the model files and
  `generate_omp_agents.py`. 1.4 owns docs only.
  - 1.3's snippet path is fixed (`ycc/settings/omp/config.yml`). 1.2's tests use their own tmp sources, so 1.2
    does not read 1.3's files.
- **B2:** 2.1 owns the generator, the validator and their test. 2.2 owns the installer files.
- **B3:** 3.1 owns `packages.json` and the expectations that depend on it. 3.2 owns the validation wiring.
- **B4/B5:** single tasks.

## NOT Building

- TTSR glob-triggered rule variants (spec D2b); a status-line extension or `statusLine.*` keys (D9).
- Writes to project `.omp/config.yml`, `.omp/rules` or `.omp/AGENTS.md` (D10); `task.agentModelOverrides` (D6).
- `bash.patterns`, per-tool `tools.approval`, `secrets.*`, and any `yolo` write.
- A `--config`/`PI_CONFIG_FILES` overlay (D4b).
- Capability-matrix RULES, SETTINGS or MODELS rows (parser change; follow-up).
- Listing `ycc-rules` in `.omp-plugin/marketplace.json` (YAN-1180).
- Separate `generate-omp-rules.sh` / `validate-omp-rules.sh` wrappers: the existing `packages` pass covers rules
  through `generate_omp_packages.py` and `validate_omp_native.py`.
- The spec's post-write `omp config get` check (simplified; see Decision Log P3).

## Step-by-Step Tasks

### Task 1.1: Rules flattener — Depends on [none]

- **BATCH**: B1
- **ACTION**: Create `scripts/generate_omp_rules.py` (typed; mypy --strict).
  - Constants:
    - `SRC_DIR = REPO_ROOT / "ycc/rules"` and `RULE_PREFIX = "ycc-"`.
    - `SKIPPED_RULE_NAMES` and the `ALWAYS_APPLY_MAX_*` limits, imported from `generate_cursor_rules`.
    - `SOURCE_KEYS = {"description", "paths", "alwaysApply"}` and `OUTPUT_KEYS = ("description", "alwaysApply", "globs")`.
    - `FORBIDDEN = ("~/.claude", "CLAUDE_PLUGIN_ROOT", "/ycc:")`.
  - Functions:
    - `flat_name(rel: Path) -> str`:
      - `rel` must be `<family>/<stem>.md`. Anything else raises `ValueError(f"{rel}: OMP rules are flat; nest at most one family directory")`.
      - Returns `f"ycc-{family}-{stem}.md"`.
    - `rule_frontmatter(rel, data, body) -> dict[str, object]`:
      - Unknown source keys raise. `description` is validated with `generate_cursor_rules.validate_description`.
      - `paths` becomes `globs`.
      - `alwaysApply` is emitted only when `is True`, and then `globs` is dropped.
      - A non-`common` rule without `paths` raises.
    - `rewrite_links(body, rel, names) -> str`:
      - `[t](x.md)` and `[t](../fam/x.md)` become `[t](rule://ycc-<fam>-x)`.
      - A link to a missing or skipped rule raises.
      - External `http(s)` links are untouched.
    - `build_rules(src: Path = SRC_DIR) -> dict[str, str]`:
      - Iterates `sorted(src.glob("*/*.md"))`, skipping `SKIPPED_RULE_NAMES`. `README.md` at the root is never
        globbed.
      - Raises on duplicate flat names, naming both sources.
      - Raises on `FORBIDDEN` tokens and when the `alwaysApply` count or line budget is exceeded.
      - Renders the frontmatter with `yaml.safe_dump(sort_keys=False, allow_unicode=True, default_flow_style=False)`.
    - `write_tree(dest: Path, dry_run: bool = False) -> set[Path]`.
- **IMPLEMENT** `scripts/test_generate_omp_rules.py` (unittest; tmp `ycc/rules` fixtures):
  - **R1**: the real tree yields exactly 31 names (list them; no `hooks`, no README).
  - **R2**: `paths` becomes `globs` in list form; `alwaysApply: false` is omitted; `alwaysApply: true` drops `globs`;
    key order is `description, alwaysApply, globs`.
  - **R3**: a collision (`common/foo-bar.md` and `common-foo/bar.md`) raises and names both files.
  - **R4**: nesting deeper than one level raises.
  - **R5**: the link `performance.md` becomes `rule://ycc-web-performance`; a link to a missing target raises.
  - **R6**: a forbidden token raises, and so does a third `alwaysApply` rule.
- **MIRROR**: `generate_cursor_rules.py:73-160`; TEST_STRUCTURE (cursor rules).
- **GOTCHA**:
  - Import `generate_cursor_rules` for `parse_frontmatter`, `validate_description` and the limit constants only.
    Do not call `normalize_rule_frontmatter` (it raises `SystemExit` and always emits `alwaysApply`) or
    `apply_skills_text_transforms` (Cursor-specific).
  - `alwaysApply: "true"` (a string) must count as not-true, matching OMP (`=== true`).
- **VALIDATE**: `python3 scripts/test_generate_omp_rules.py && mypy scripts/generate_omp_rules.py scripts/test_generate_omp_rules.py`

### Task 1.2: YAML managed merge (`omp-config`) — Depends on [none]

- **BATCH**: B1
- **ACTION** in `scripts/merge_managed_config.py`:
  1. Profile:

     ```python
     "omp-config": {"format": "yaml", "refuse_symlink": True, "backup_comments": True, "groups": {"settings": [
         {"path": ["modelRoles"], "policy": "map-entries"},
         {"path": ["tools", "approvalMode"], "policy": "scalar"}]}}
     ```

  2. Format dispatch. Add a YAML branch at every `profile["format"]` site: `:308` (`load_source`, suffix
     `.yml`/`.yaml`), `:399` (`adopt_matching_values`), `:1238`, `:1341` (`remove_yaml`) and `:1501` (`merge_yaml`).
     - Use `import yaml` inside a `_yaml()` helper, so JSON and TOML profiles never need PyYAML.
     - Parse with `yaml.safe_load`. An empty file or `None` becomes `{}`. A non-mapping root raises
       `MergeError(f"{path}: not a valid OMP config (expected a mapping)")`.
     - Render with `yaml.safe_dump(merged, sort_keys=False, allow_unicode=True, default_flow_style=False)`.
     - Re-parse the rendered text and require equality with `merged` before `atomic_write`.
  3. Symlink refusal: generalize the `strict_hooks` check at `:1449` to
     `profile.get("strict_hooks") or profile.get("refuse_symlink")`. Message:
     `refusing to write through symlinked <dest>; add these keys yourself:` followed by the source snippet.
     Exit 1 with no write.
  4. Backup before a lossy rewrite (`backup_original`):
     - When a write is planned and the destination is not exactly ycc's own rendering (it holds comments or other
       formatting the rewrite drops): copy the bytes to `<dest>.ycc-backup` with mode `0o600`, or to the first free
       `<dest>.ycc-backup.N` when existing backups hold different bytes. Never overwrite a backup.
     - Warn on every such rewrite: `comments and formatting in <dest> are not preserved; original saved to <backup>`.
     - When `--remove` deletes an emptied file, delete backups that hold only ycc's own rendering.
     - Refuse documents with YAML aliases (rc 1, no changes made); a rewrite would expand them.
     - Docstring: add YAML to "Formats".
- **IMPLEMENT** `OmpYamlMergeTest(MergeBase)` in `scripts/test_merge_managed_config.py`:
  - **M1**: the destination is missing; the file is created with exactly the managed leaves.
  - **M2**: user keys (`providers`, `modelRoles.smol`, a custom role) survive byte-equal after the merge.
  - **M3**: the user edits `modelRoles.slow`; a repo update to `slow` is kept as the user value, with a warning.
    An untouched `default` still updates. `--force` replaces `slow`.
  - **M4**: `--remove` deletes only leaves equal to last-applied; a user-edited leaf stays.
  - **M5**: a symlinked destination returns rc 1. The link and its target are unchanged, and no state is written.
  - **M6**: invalid YAML, or a list root, returns rc 1 with bytes unchanged.
  - **M7**: a commented destination creates `.ycc-backup` (mode 600); a later commented file rotates to
    `.ycc-backup.1` without overwriting; ycc's own rendering is never backed up; removing an emptied file drops
    ycc-only backups.
- **MIRROR**: MANAGED_MERGE_PROFILE; `test_toml_preserves_comments_and_unmanaged_tables` (`:215`) for shape.
- **GOTCHA**:
  - Do not change the JSON/TOML behaviors or the existing `test_symlink_destination_becomes_real_file` (`:173`).
    The refusal is per profile.
  - `map-entries` flattens `modelRoles` into one leaf per role (`:333`), so other roles are never adopted or deleted.
  - Keep `merge_managed_config.py` importable with no PyYAML installed: no top-level import.
- **VALIDATE**: `python3 scripts/test_merge_managed_config.py && mypy`

### Task 1.3: OMP model policy and data — Depends on [none]

- **BATCH**: B1
- **ACTION**:
  1. `ycc/settings/models.json`: add `targets.omp` exactly as in the spec ("`ycc/settings/models.json` → `targets.omp`").
     Fix `$comment`: name `scripts/validate-model-settings.py`, and add `targets.omp` (consumed by
     `scripts/omp_model_policy.py` → `generate_omp_agents.py`).
  2. `ycc/settings/omp/config.yml`: the managed snippet (spec), with the header comment.
  3. `scripts/omp_model_policy.py` (typed):
     - Constants, citing `src/config/model-roles.ts` `MODEL_ROLES` at v18.12.5:
       - `BUILTIN_ROLES = ("default","smol","slow","vision","plan","commit","tiny","memory","task","advisor","widget")`.
       - `THINKING = ("off","minimal","low","medium","high","xhigh","max","auto","inherit")`.
       - `roles.default` is required and must reference `main`.
       - `SELECTOR = re.compile(r"^[a-z0-9][a-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")`.
       - `SNIPPET_KEYS = {("modelRoles",), ("tools","approvalMode")}` and `APPROVAL_MODE = "write"`.
     - `load_omp(models_path) -> dict`.
     - `role_selector(omp, ref) -> str`: `"<m>:<e>, <fallback.m>:<fallback.e>"`.
     - `expected_snippet(omp) -> dict`.
     - `agent_model_map(models_path=...) -> dict[str, str | None]`.
     - `omp_model_errors(omp, snippet, used_agent_models: set[str]) -> list[str]`. It checks:
       - required keys;
       - each `main`/`subagent`/`fallback` model matches `SELECTOR`, and each effort is in `THINKING`;
       - `roles` keys ⊆ `BUILTIN_ROLES`, and values ∈ {`main`,`subagent`};
       - `agentModels` keys ⊇ `used_agent_models`;
       - values are `None` or `@<role>`, with the role in `roles`. `pi/` and bare ids are rejected with a named
         message;
       - the snippet equals `expected_snippet`, and no keys exist outside `SNIPPET_KEYS`.
  4. `scripts/validate-model-settings.py`:
     - Append an OMP section that loads `ycc/settings/omp/config.yml` (`yaml.safe_load`).
     - Collect the `model:` values from `ycc/agents/*.md` frontmatter. Absent counts as `inherit` only if any agent
       omits it.
     - Extend `errors` with `omp_model_errors`.
  5. `scripts/generate_omp_agents.py:60-65`: `MODEL_MAP: Mapping[str, str | None] = omp_model_policy.agent_model_map()`.
- **IMPLEMENT** `scripts/test_omp_model_policy.py`:
  - **P1**: the repo `models.json` and snippet give no errors.
  - **P2**: an unknown role (`architect`) is rejected.
  - **P3**: a bare id `claude-opus-5`, a missing provider, or an effort of `ultra` is rejected.
  - **P4**: `agentModels.opus: "pi/slow"`, or `"@plan"` when `plan` is unmanaged, is rejected.
  - **P5**: a snippet with an extra key (`tools.approval`) or drifted `slow` is rejected.
- **MIRROR**: `scripts/generate_opencode_plugin.py:92-165` (`validate_agent_models`, `split_model_reference`) for
  message style.
- **GOTCHA**:
  - Generated `packages/omp/ycc/agents/*.md` must be byte-identical after the change (same map values).
    `python3 scripts/test_generate_omp_agents.py` proves it.
  - `validate-model-settings.py` runs under `scripts/test_validate_opencode_config.py:229` with a patched
    `Path.read_text`. Make sure its fake still serves real files for paths it does not patch.
  - YAML: quote the `@`-free selectors as plain strings. The snippet contains no `@` values.
- **VALIDATE**: `python3 scripts/test_omp_model_policy.py && python3 scripts/validate-model-settings.py && python3 scripts/test_generate_omp_agents.py && python3 scripts/test_validate_opencode_config.py && mypy`

### Task 1.4: Docs — Depends on [none]

- **BATCH**: B1
- **ACTION**:
  - **ADR 0002**:
    - Add an "Amendment (YAN-1175)" bullet under the YAN-1174 one.
    - Package-matrix rows:
      - `ycc-rules` `:78`: adapter, included and unlisted; globs are advisory, so parity is partial.
      - `installer-fallback` `:82`: instructions (`AGENTS.md` symlink) and settings (opt-in merge); status line
        unsupported.
      - Settings `:83`: opt-in `--settings` merge of `modelRoles.{default,slow,task}` and `tools.approvalMode: write`
        into the user `config.yml`; project config wins.
      - Status line `:84`: unsupported. No command renderer; the extension path is blocked by the YAN-1174 guard.
        The `ycc-mods` part is unchanged.
    - Adapter 4: delivered (`scripts/generate_omp_rules.py`).
    - Adapter 6: drop the status-line extension and point to the spec's follow-up list.
    - Follow-up row `:137`: "Delivered: …".
  - **Spike §3**: rows `:332-334,340-342,347,352` get the same verdicts plus evidence (the spec path). §1 summary
    bullet `:25`.
  - **Capability matrix source** (`ycc/skills/_shared/references/target-capability-matrix.md`):
    - Packaging row `:76`: "`ycc`, `ycc-mcp`, `ycc-rules` generated, unlisted until v6.1.0; …".
    - `INSTALL_PATH:omp`: 3 packages; `--settings`/`--rules` are user-scope only.
    - `AGENTS:omp`: `@slow`/`@task` resolve through `modelRoles`, which `--settings` can set.
    - `DANGEROUS_MODE:omp`: add that `--settings` sets `write`; subagents still run as `yolo`.
  - **`docs/install/omp.md`**:
    - `:39-46`: three packages.
    - New `## Rules`:
      - the flat names list pattern;
      - two always-on rules; language rules are rulebook entries read via `rule://`, and globs are advisory;
      - override by copying to `<agentDir>/rules/` or `<cwd>/.omp/rules/`, or disable via `ttsr.disabledRules`;
      - project rules apply at the `.omp` cwd only.
    - New `## Global Instructions (--rules)`: symlink, refusal, `@import` alternative.
    - New `## Settings And Model Roles (--settings)`:
      - the snippet and ownership semantics;
      - comments backup; symlinked-config refusal;
      - `omp config set modelRoles` replaces the record;
      - precedence: project > user;
      - `--project` rejected.
    - New `## Approvals`: `write` meaning; subagents run as `yolo`; project override; `--approval-mode` per session;
      headless `-p` note.
    - New `## Status Line`: unsupported; use `statusLine.*`.
    - OMP Notes `:284-285`: delete "no OMP plugin channel yet (YAN-1175)".
  - **`docs/install/v6/README.md`**: `:40` and `:124`.
  - **`ycc/rules/README.md`**: OMP section.
  - **`CONTRIBUTING.md:158`** and **`README.md:243,307`**: add `packages/omp/ycc-rules/`.
- **GOTCHA**:
  - `validate_omp_native.hook_verdict_errors` reads the spike, the ADR and `docs/install/omp.md`. Keep every
    existing hook-verdict anchor row intact, and never write a `SHIM_PHRASES` phrase.
  - Edit only the matrix source; copies regenerate in 5.1.
  - Install docs must use only model-valid package ids (`validate_install_doc_ids.py`).
- **VALIDATE**: `npx markdownlint-cli docs/install/omp.md docs/install/v6/README.md docs/internal/adr/0002-omp-runtime-contract.md docs/internal/spikes/omp-runtime-contract.md ycc/rules/README.md CONTRIBUTING.md README.md`

### Task 2.1: Generator and validator for `ycc-rules` — Depends on [1.1]

- **BATCH**: B2
- **ACTION**:
  - **`scripts/generate_omp_packages.py`**:
    - Add `RULES_COMPONENTS = frozenset({"rules"})`. `native_packages` accepts it at `:122`, alongside the
      workflow and MCP sets.
    - Delete `COMPONENT_REASONS["rules"]`. Other mixes still raise with `NO_PLANNED_EMITTER`.
    - Add `is_rules_package(package)`.
    - Add `rules_payloads(packages, repo_root=REPO_ROOT)`. It calls `generate_omp_rules.build_rules(repo_root / "ycc/rules")`
      and returns `{package_root(p) / "rules" / name: Payload(text.encode())}`.
    - In `build_output`, call `output.update(rules_payloads(selected, repo_root))`.
    - Docstring `:18-21`: "rules ship flat in `ycc-rules` (YAN-1175)".
  - **`scripts/validate_omp_native.py`**:
    - Add `RULES_ROOT_ENTRIES = frozenset({".omp-plugin", ".claude-plugin", "package.json", "rules"})`.
    - Add `rules_closure_errors(root, source_root, package)`:
      - root entries must be in `RULES_ROOT_ENTRIES`;
      - `rules/` holds only regular `ycc-*.md` files, with no subdirectories or symlinks;
      - the file set and bytes equal `generate_omp_rules.build_rules(source_root / "ycc/rules")`.
    - Wire it into `validate()` for `is_rules_package`.
- **IMPLEMENT** in `scripts/test_generate_omp_packages.py`:
  - **G1**: replaces `:193-203`. With `with_omp(model, "ycc-rules", status="included")`, the output has
    `packages/omp/ycc-rules/{.omp-plugin/plugin.json,.claude-plugin/plugin.json,package.json}` with name `ycc-rules`
    and the lockstep version, plus `rules/ycc-common-security.md` and no `hooks` rule.
  - **G2**: `components=["rules","skills"]` still fails closed with `no OMP emitter`.
  - **G3**: the validator flags each of these as a subTest: a nested `rules/x/`, an extra root entry, and a drifted
    rule byte.
- **MIRROR**: PAYLOAD_PATTERN; NAMING_CONVENTION; `mcp_closure_errors`.
- **GOTCHA**:
  - The fixture repo in `test_generate_omp_packages.py` must contain `ycc/rules` (copy a 2-file tree) for G1.
  - `hook_surface_errors` must still pass, because `rules` is not in `CODE_SURFACE_DIRS`.
  - The real-repo sync test only passes after 3.1 flips the row and 5.1 regenerates. Within B2, run the fixture
    tests only.
- **VALIDATE**: `python3 scripts/test_generate_omp_packages.py && python3 scripts/test_validate_omp_hooks.py && mypy`

### Task 2.2: Installer `settings` and `rules` steps for omp — Depends on [1.2, 1.3]

- **BATCH**: B2
- **ACTION**:
  - **`scripts/omp_install.py`**:
    - Add the subcommand `agent-dir`. It calls `available()` and then prints `OmpCli().profile_key()` (`omp config path`).
    - Errors print `[err] …` and return 2.
    - `restart_line`: when a package ships `rules`, append "rules apply to new sessions (/new or restart)".
  - **`scripts/lib/install/targets/omp.sh`**:
    - `omp_valid_steps` → `base,settings,rules`.
    - `omp_intent_steps`: `base|plugins`→`base`, `settings`→`settings`, `rules`→`rules`.
    - `omp_config_groups` → `settings`.
    - Add `omp_config_dest <agent_dir>`. It prints `<agent_dir>/config.yaml` when only that file exists, else
      `<agent_dir>/config.yml`.
    - **Sync:**
      - Run the existing `base` block only when `step_enabled base`.
      - If `step_enabled settings`, run `merge_settings_config omp-config "${SCRIPT_DIR}/ycc/settings/omp/config.yml" "$(omp_config_dest "$agent_dir")" "$(config_groups_for_target omp)"`.
      - If `step_enabled rules`, run `link_rules_file "${SCRIPT_DIR}/ycc/settings/rules/AGENTS.md" "${agent_dir}/AGENTS.md"`.
      - Set `agent_dir` once via `python3 "${OMP_INSTALL_HELPER}" agent-dir`.
      - Warn "omp target ran no steps" only when nothing ran.
    - **Remove:** mirror sync with `remove_settings` and `unlink_owned_link`.
    - `--dry-run`: print the planned merge and link without writing. Reuse the dry-run convention of the
      merge helper (pass through `DRY_RUN`), or print and skip, matching `claude.sh`.
  - **`scripts/package_install_plan.py`**:
    - Add `CARRIERS["omp"]["rules"] = "base"`.
    - After `:143`, add `if target == "omp": selected &= set(pair.provides)`, with the comment "OMP fallback payloads
      (instructions, settings) are opt-in via --rules/--settings, never package-implied".
    - Update the comment at `:53-55`.
  - **`install.sh` help**:
    - `--settings` scope list adds `omp — <agentDir>/config.yml (modelRoles, tools.approvalMode; user scope)`.
    - `--rules` adds `omp — AGENTS.md → <agentDir>/`.
    - `--package` `:321` reads `omp: ycc, ycc-mcp, ycc-rules (ycc-hooks excluded: …)`.
  - **`scripts/tests/install/omp.sh`** (replace `:191-194`):
    - **I1**: `install --target omp --settings` writes `<fake agent>/config.yml` with the managed leaves and makes
      no `omp plugin` call for settings.
    - **I2**: after editing `modelRoles.slow` and re-running, the edit is kept and the output says `kept`.
    - **I3**: `--rules` links `AGENTS.md`. A pre-existing real `AGENTS.md` makes it fail with
      `refusing to replace user-authored rules file`, and the file is unchanged.
    - **I4**: `--project --settings` and `--project --rules` fail with the project-scope message, and nothing is
      written under `<project>/.omp`.
    - **I5**: `remove --target omp --intent settings,rules` removes the unchanged leaves and the link, and keeps
      the user-edited leaf.
- **MIRROR**: INSTALLER_CALL_SITE; `tests/install/codex.sh:152` (`YCC_MANAGED_CONFIG_STATE`); `fake_omp.py` already
  answers `config path` (`:1792-1796`).
- **GOTCHA**:
  - `config_groups_for_target` filters by intent names (`steps.sh:184-187`), so the group **must** be `settings`.
  - `--package` cannot combine with `--settings` or `--rules` (`install.sh:678`). The planner filter keeps
    `--package ycc` on omp at `("base",)`.
  - Do not touch `omp_project_steps` (`base` only), so the existing gate rejects D10.
- **VALIDATE**: `bash scripts/tests/install/omp.sh && python3 scripts/test_omp_install.py && shellcheck scripts/lib/install/targets/omp.sh && mypy`

### Task 3.1: Model flip and dependent expectations — Depends on [2.1, 2.2]

- **BATCH**: B3
- **ACTION**:
  - **`ycc/settings/packages.json`**:
    - `ycc-rules.runtimes.omp`:
      - `status: "included"`, `listed: false`;
      - `gates: ["YAN-1178 live acceptance matrix passes on the real ycc tree"]`;
      - `evidence` += the spec;
      - `notes`: "Generated package under packages/omp/ycc-rules (omp >=18.12.2): 31 flat rules named ycc-<family>-<stem>, paths→globs, description kept, alwaysApply only when true. OMP lists globs as advisory (no auto-attach): language rules are rulebook entries read via rule://. Unlisted until YAN-1180."
    - `installer-fallback.runtimes.omp`:
      - `status: "included"`, `components: ["instructions","settings"]`, `gates: []`;
      - `evidence` += the spec;
      - `notes`: "install.sh --target omp, user scope only: --rules links AGENTS.md into the omp agent dir; --settings merges ycc-owned modelRoles.{default,slow,task} and tools.approvalMode into config.yml (hash-owned; user edits and project config win). Rules ship natively in ycc-rules; the status line is unsupported."
  - **Expectations:**
    - `test_package_model.py`: add `test_omp_rules_rows_included`.
    - `test_package_install_plan.py`:
      - add `("ycc-rules","omp",("base",))` to the closures;
      - the `both` check covers `ycc,ycc-mcp,ycc-rules` with `skipped_components == ()`;
      - remove the `ycc-rules`/omp rejection at `:68`.
    - `test_omp_install.py:419` → `("ycc","ycc-mcp","ycc-rules")`; `:912` drops `ycc-rules`.
    - `tests/install/omp.sh` default-install assertions add `ycc-rules@ycc`. 2.2 is done by now, so B3 owns this
      file for this edit.
    - `test-release-bundle.sh`: add the three manifests to `MODEL_GENERATED` and the notes assertion.
- **GOTCHA**:
  - `build_package_graph.check_closures` runs on included rows. The Cursor `ycc-rules` (rules-only) passes today,
    and OMP must too. If a rules→skill edge appears, record it as a runtime gap only with evidence; do not add
    `skills` to the row.
  - `_evidence_errors` needs the spec path to exist (it is committed).
- **VALIDATE**: `python3 scripts/test_package_model.py && python3 scripts/test_package_install_plan.py && python3 scripts/test_omp_install.py && python3 scripts/test_package_graph.py && bash scripts/tests/install/omp.sh && bash scripts/test-release-bundle.sh`

### Task 3.2: Validation wiring — Depends on [1.1, 1.3, 2.1]

- **BATCH**: B3
- **ACTION**:
  - **`scripts/lib/validate-scope.sh`**, next to `:75-96`:
    - `scripts/generate_omp_rules.py) echo "omp" ;;`
    - `scripts/test_generate_omp_rules.py) echo "omp types" ;;`
    - `scripts/omp_model_policy.py | scripts/test_omp_model_policy.py) echo "omp config types" ;;`
    - `scripts/test-omp-rules-settings.sh) echo "omp" ;;`
    - Add `ycc/rules/*` before `ycc/*` only if it is not already covered: `ycc/*` already selects `omp`, so leave it.
  - **`scripts/test-validate-scope.sh`**: matching `expect_targets`.
  - **`pyproject.toml`** mypy `files` += `scripts/generate_omp_rules.py`, `scripts/test_generate_omp_rules.py`,
    `scripts/omp_model_policy.py`, `scripts/test_omp_model_policy.py`.
  - **`scripts/validate.sh`**:
    - omp block: `echo "== test: omp rules flattener =="` + `python3 …/test_generate_omp_rules.py || fail …`.
    - helpers block: after `validate-model-settings.py`, run `test_omp_model_policy.py`.
- **VALIDATE**: `bash scripts/test-validate-scope.sh && mypy`

### Task 4.1: Opt-in live harness (precedence proof) — Depends on [3.1, 3.2]

- **BATCH**: B4
- **ACTION**: Create `scripts/test-omp-rules-settings.sh`, following the `test-omp-native-packages.sh` sandbox:
  - `mktemp -d /tmp/omp-rules-settings.XXXXXX`, refuse a HOME under the real HOME, `env -i`;
  - seed the null provider `models.yml` plus `mcp.startupTimeoutMs: 0`;
  - needs `omp` and `python3`.

  It drives `omp --mode rpc --no-session --no-title --model …` and reads `get_state`:
  - **L1**: `--plugin-dir packages/omp/ycc-rules` →
    - `<generic-rules>` contains the `ycc-common-security` and `ycc-common-git-workflow` bodies;
    - `<domain-rules>` lists `ycc-golang-coding-style (**/*.go, **/go.mod, **/go.sum)`;
    - no `hooks` rule.
  - **L2**: a project `<cwd>/.omp/rules/ycc-common-security.md` replaces the package body at that cwd, and the
    package body returns from a subdirectory.
  - **L3**: `HOME=<sandbox> ./install.sh install --target omp --settings` (real `omp` on PATH; `YCC_MANAGED_CONFIG_STATE`
    in the sandbox) →
    - `omp config get modelRoles --json` and `omp config get tools.approvalMode` show the managed values;
    - after editing `modelRoles.slow` and re-running, the edit survives.
  - **L4**: a project `.omp/config.yml` with `modelRoles.default: spike-null/null-two` and
    `tools.approvalMode: always-ask` beats the managed user values:
    - `get_state.model` is `null-two`;
    - `config get` returns `always-ask`;
    - both revert from a non-project cwd.

  Use the null provider ids for L4 via a second `models.yml` entry, as the spec probe did.

- **GOTCHA**:
  - L3 needs `install.sh` to skip the package build (`YCC_INSTALL_SKIP_BUILD=1`) and to run `--settings` only.
  - Never touch the real `~/.omp` or real `~/.config/ycc`.
- **VALIDATE**: `bash -n scripts/test-omp-rules-settings.sh && shellcheck scripts/test-omp-rules-settings.sh && bash scripts/test-omp-rules-settings.sh` (local, opt-in; paste the summary into the PR body)

### Task 5.1: Regenerate and full validation — Depends on [4.1]

- **BATCH**: B5
- **ACTION**:
  1. `./scripts/sync.sh` regenerates `packages/omp/ycc-rules/**`, the matrix copies and the inventories.
  2. `./scripts/validate.sh` (~280 s).
  3. Fix drift.
  4. Grep for stale promises. Expect no matches outside research and plans:
     `rg -n "ycc-rules.{0,20}deferred|no OMP plugin channel yet|YAN-1175 rules flattener" -g '!docs/research/**' -g '!docs/plans/**'`.
- **VALIDATE**: `./scripts/sync.sh && ./scripts/validate.sh && git status --short` (only intended files changed)

## Testing Strategy

### Acceptance criterion → test

| Acceptance criterion                                  | Deterministic CI                                                                                                                                           | Opt-in live                                             |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| Generated context and settings validate               | R1–R6 (flattener); G1–G3 (package, fail-closed, validator closure); P1, P5 (snippet parity and keys); `validate-omp-packages.sh` drift                     | L1                                                      |
| Model references use full runtime-valid ids and roles | P1–P4 (`provider/model`, thinking enum, built-in roles, `@role` closure, no `pi/` or bare ids); generated agents unchanged (`test_generate_omp_agents.py`) | L3 (`config get` shows the values)                      |
| User edits survive updates                            | M2–M4, M7 (merge ownership, backup); M5–M6 (symlink and invalid YAML refused, no mutation); I2, I3, I5 (installer)                                         | L3 (edit survives a re-run), L2 (project rule override) |
| Project/user precedence is tested                     | I4 (installer never writes the project layer)                                                                                                              | L2 (rules), L4 (`modelRoles` + `approvalMode`)          |

### Edge Cases Checklist

- [ ] `config.yaml` (not `.yml`) is the merge target when it alone exists (`omp_config_dest`).
- [ ] A missing `<agentDir>` is created by `atomic_write` (`parent.mkdir`).
- [ ] `--package ycc` on omp never runs settings or rules (planner filter).
- [ ] `alwaysApply: "true"` (a string) is not emitted as always-on.
- [ ] A new `ycc/rules/<family>/<x>.md` appears in the package after `sync.sh`, and the validator flags a stale
      commit.
- [ ] The merge helper still runs for JSON/TOML profiles without PyYAML.

## Validation Commands

### Static Analysis

```bash
mypy
./scripts/lint.sh --python --shell --docs
```

### Unit Tests

```bash
python3 scripts/test_generate_omp_rules.py
python3 scripts/test_generate_omp_packages.py
python3 scripts/test_merge_managed_config.py
python3 scripts/test_omp_model_policy.py
python3 scripts/validate-model-settings.py
python3 scripts/test_generate_omp_agents.py
python3 scripts/test_package_model.py
python3 scripts/test_package_install_plan.py
python3 scripts/test_omp_install.py
bash scripts/tests/install/omp.sh
bash scripts/test-validate-scope.sh
```

### Full Test Suite

```bash
./scripts/sync.sh
./scripts/validate.sh            # ~280 s; also run by the lefthook pre-push hook (push async)
```

### Manual Validation

- [ ] `bash scripts/test-omp-rules-settings.sh` passes L1–L4; paste the output into the PR.
- [ ] `./install.sh install --target omp --settings --rules --dry-run` prints the planned merge and link and writes
      nothing.

## Acceptance Criteria

- [ ] `ycc-rules` OMP is generated (31 flat `ycc-*` rules), validated, included, unlisted, and installed by default.
- [ ] `installer-fallback` OMP is included with `instructions` and `settings`. `--settings` and `--rules` are
      opt-in and user scope only.
- [ ] `models.json` `targets.omp` and `ycc/settings/omp/config.yml` validate (roles, selectors, thinking, alias
      closure, parity).
- [ ] User edits to managed leaves, user `AGENTS.md`, and user or project rule overrides survive updates (tests
      M3, I2, I3, L2, L3).
- [ ] Project/user precedence is proven live (L2, L4), and the installer never writes project config (I4).
- [ ] Docs: ADR 0002 amended (adapter 4 delivered, rows, YAN-1175 row), spike, matrix, `docs/install/omp.md`,
      `ycc/rules/README.md`. The status line is documented as unsupported.
- [ ] `./scripts/sync.sh` and `./scripts/validate.sh` pass; the real `~/.omp` was untouched.

## Completion Checklist

- [ ] Validator follows the `*_errors` pattern; the generator stays fail-closed for unknown component mixes.
- [ ] Error messages name the file or leaf and the fix (`--force`, `@import`, edit project config).
- [ ] Generated trees are regenerated, never hand-edited.
- [ ] PR body: target release v6.1.0, the live harness output, and the decision log below.

## Decision Log

Accepted spec decisions:

| #   | Decision                                                       | Source                   |
| --- | -------------------------------------------------------------- | ------------------------ |
| D1  | `ycc-<family>-<stem>.md` flat names                            | spec D1                  |
| D2  | Language rules as rulebook entries (advisory globs); no TTSR   | spec D2                  |
| D3  | `ycc-rules` included, unlisted, installed by default           | spec D3                  |
| D4  | Opt-in hash-owned merge into the user `config.yml`; no overlay | spec D4                  |
| D5  | Per-role `map-entries` + scalar approval                       | spec D5                  |
| D6  | Per-agent models via frontmatter `@role` from `models.json`    | spec D6                  |
| D7  | `tools.approvalMode: write`, opt-in                            | spec D7 (Main confirmed) |
| D8  | `AGENTS.md` symlink via `--rules`                              | spec D8                  |
| D9  | Status line unsupported                                        | spec D9                  |
| D10 | `--project` rejected for settings and rules (existing gate)    | spec D10                 |

Plan-level choices:

| #   | Decision                                                                                          | Rationale                                                                                                                                                                                                               |
| --- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | Model policy lives in a new importable `scripts/omp_model_policy.py`                              | `validate-model-settings.py` is a hyphenated top-level script that cannot be imported. One module feeds both the validator and the agent generator.                                                                     |
| P2  | Single merge group named `settings`                                                               | `config_groups_for_target` filters groups by intent name (`steps.sh:184-187`).                                                                                                                                          |
| P3  | No post-write `omp config get` verification (simplified from the spec; the spec now records this) | A YAML round-trip plus mapping check prevents `.broken-*`. OMP ignores invalid enum values at load. Avoids extending `fake_omp.py`. The L3 live harness covers the real read-back.                                      |
| P4  | OMP planner drops inherited fallback components                                                   | `install_set` adds `installer-fallback` components (`build_package_graph.py:87`). Without the filter, `--package ycc` would run settings and rules, which breaks opt-in. Mirrors the Cursor hooks discard (`:144-145`). |
| P5  | No separate rules wrapper scripts                                                                 | The `packages` pass already generates and validates every OMP root.                                                                                                                                                     |

## Risks

| Risk                                                          | Likelihood | Impact | Mitigation                                                                                         |
| ------------------------------------------------------------- | ---------- | ------ | -------------------------------------------------------------------------------------------------- |
| Release or planner suites assert the old `deferred` rows      | High       | Low    | Enumerated in 3.1; 5.1 runs the full suite                                                         |
| `check_closures` flags rules→skill edges for `ycc-rules@omp`  | Low        | Medium | The Cursor rules-only row passes today; 3.1 gotcha                                                 |
| YAML merge drops user comments                                | Medium     | Low    | `.ycc-backup` (rotating, never overwritten) plus a warning on every lossy rewrite (M7); documented |
| `validate-model-settings.py` test harness patches `read_text` | Medium     | Low    | 1.3 gotcha; run `test_validate_opencode_config.py`                                                 |
| Doc edits break the hook-verdict anchors                      | Low        | Medium | 1.4 gotcha; `test_validate_omp_hooks.py` in 5.1                                                    |
| Parallel B1 tasks drift on the snippet shape                  | Low        | Medium | The shape is fixed in the spec; 1.2 tests use their own sources; 2.2 integrates                    |

## Notes

- Spec probes used `/tmp/omp-yan1175.*` with the null provider; none touched `~/.omp`.
- YAN-1178 may fold `test-omp-rules-settings.sh` into the live acceptance matrix. YAN-1180 lists `ycc-rules`.
- Follow-ups (file in Linear):
  - TTSR rule variants;
  - status-line extension (needs a scoped guard lift);
  - `secrets.*` defaults;
  - RULES, SETTINGS and MODELS matrix rows;
  - managed `smol`, `plan` and `advisor` intent.
