# Plan: YAN-1176 + YAN-1291 — OMP coexistence with other ycc runtimes, and linear-personal on OMP

- **Linear:** YAN-1176 and YAN-1291. **GitHub:** #417 and #418, one PR.
- **Target release:** ystack v6.1.0 (trunk only; state it in the PR body).
- **Spec:** [`docs/research/yan-1176-omp-coexistence/feature-spec.md`](../../research/yan-1176-omp-coexistence/feature-spec.md)
  (decisions D1–D14). The live evidence is
  [`research-live-probes.md`](../../research/yan-1176-omp-coexistence/research-live-probes.md).
- **Contract:** [ADR 0002](../../internal/adr/0002-omp-runtime-contract.md). This plan amends its
  Consequences bullet on `~/.agents` duplicates and its YAN-1176 follow-up row, and closes spike §5
  "Dedupe policy".
- **Mirrors:**
  - YAN-1175 (`docs/plans/yan-1175-omp-rules-settings/plan.md`): the `omp-config` merge profile,
    opt-in steps and the live harness.
  - YAN-1173: the `ycc-mcp` generator/validator and the `mcp-listed` harness check.

## Summary

Duplicates appear by default only through `~/.agents/skills`. The agents target puts ycc skills there,
and so does skills consolidation for Codex, Cursor and opencode. OMP loads them next to the native
`ycc` package as 41 `agents/<name>` aliases. Everything else already loads once.

This plan makes four changes:

1. **`dedupe` step.** `install --target omp` gains this default-on step. It merges the
   **ledger-owned** aliases (`agents/<n>`, `codex/<n>`, `opencode/<n>`) into the user `config.yml`
   `skills.ignoredSkills`, through the existing hash-owned `list-union` merge.
   - `remove --target omp` (`--only base` or `--only dedupe`) takes them back.
   - OMP globs match only the alias. When the native package is disabled or removed, the other copy
     loads again under its bare name.
2. **Warnings.** One `omp_install.py coexistence` helper prints the actionable warnings W1–W5. It
   replaces `warn_agents_overlap`, whose advice ("remove the agents skills") breaks consolidated
   Codex, Cursor and opencode installs. The agents target calls it when OMP ycc is recorded.
3. **Project residue.** `remove --project` deletes the empty omp project residue
   (`.omp/plugins/{installed_plugins.json,omp-plugins.lock.json,node_modules/}`).
4. **YAN-1291.** The generated `packages/omp/ycc-mcp/.mcp.json` appends `?ycc-server=<name>` to a later
   HTTP server whose connection equals an earlier one. `linear-personal` then loads beside `linear`
   with its own OAuth credential id. `mcp-configs/mcp.json` and the other runtimes stay byte-identical.

A new opt-in live harness, `scripts/test-omp-coexistence.sh`, proves once-each loading, precedence,
the untrusted-project boundary and uninstall restore. Docs gain a "Coexistence with other runtimes"
section.

## User Story

As a ycc user running OMP alongside Claude, Codex, Cursor or opencode, I want each ycc skill, agent,
rule, command and MCP server to load exactly once in OMP, from the OMP package. When something
overlaps, I want one clear line telling me what to do. Removing ycc should put OMP back the way it was,
and both of my Linear servers should work.

## Problem → Solution

- **Problem:**
  - 41 `agents/<name>` duplicates and 41 collision warnings; the prompt grows 17 % (probe B).
  - `warn_agents_overlap` recommends deleting a directory other tools depend on.
  - `ycc-mcp:linear-personal` is shadowed and would share `linear`'s OAuth row anyway.
  - Project uninstall leaves untracked `.omp/plugins/` residue.
  - There is no test of mixed-runtime precedence or of the trust boundary.
- **Solution:**
  - An owned, reversible alias filter in the user OMP config.
  - One coexistence helper for every warning.
  - A generator-only URL disambiguation for equivalent HTTP connections.
  - Residue cleanup on remove.
  - A live mixed-runtime harness.
  - Coexistence docs, a precedence table, and the untrusted-repo invocation.

## Metadata

| Field            | Value                                                                                                                                                     |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Complexity       | Large (≈22 files: Python + Bash + docs)                                                                                                                   |
| Source of truth  | `scripts/*.py`, `scripts/lib/install/**`, `mcp-configs/mcp.json` (unchanged), docs. Never hand-edit `packages/omp/**` or matrix copies                    |
| Languages        | Python 3.11+ (mypy --strict files listed in `pyproject.toml`), Bash, Markdown                                                                             |
| New runtime deps | none (`urllib.parse`; PyYAML is already lazy in `merge_managed_config.py`)                                                                                |
| Research         | Done: the spec, 7 research files and the live log. External: OMP v18.12.5 source (`/tmp/omp-src-18125`) and Linear MCP (`https://linear.app/docs/mcp.md`) |

## Batches

| Batch | Tasks              | Depends On | Parallel Width |
| ----- | ------------------ | ---------- | -------------- |
| B1    | 1.1, 1.2, 1.3, 1.4 | —          | 4              |
| B2    | 2.1, 2.2           | B1         | 2              |
| B3    | 3.1                | B2         | 1              |
| B4    | 4.1                | B3         | 1              |

- **Totals:** 8 tasks in 4 batches; maximum parallel width is 4.
- **Ownership:** each file has exactly one owning task (see "Files to Change"). Tasks may read, but
  never edit, a sibling's files in the same batch.

## Worktree Setup

Not used: the plan runs with `--no-worktree`. All implementers work in the existing feature worktree
`.omp/worktrees/ystack-yan-1176-omp-coexistence/`
(branch `feat/yan-1176-omp-coexistence`), with no child worktrees.

## UX Design

### Before

- `./install.sh install --target all` prints
  `[!!] ~/.agents/skills holds 49 ycc skills that OMP also loads; remove them with ./install.sh remove --target agents --only base`.
  - OMP then lists 91 skills (41 `agents/*`), and `omp skill list` prints 41 warnings.
- `/mcp list` in OMP shows no `ycc-mcp:linear-personal`.
- `remove --target omp --only base --project` leaves `.omp/plugins/` untracked in the repo.

### After

- `./install.sh install --target all` prints
  `[ok] OMP: hid 41 ycc duplicate skills (agents/…) via skills.ignoredSkills in ~/.omp/agent/config.yml; ./install.sh remove --target omp --only dedupe restores them`.
  - OMP lists 50 skills, and `omp skill list` stderr is empty.
- `/mcp list` shows `ycc-mcp:linear` and `ycc-mcp:linear-personal`. Each logs in separately.
- `remove --target omp --only base` takes back the dedupe entries. With `--project`, it also removes
  the empty `.omp/plugins/` tree.
- The agents target after OMP prints:
  `[!!] OMP also loads these skills; run ./install.sh install --target omp --only dedupe to hide the ~/.agents copies in OMP`.

### Interaction Changes

| Touchpoint                             | Before                                | After                                                                    |
| -------------------------------------- | ------------------------------------- | ------------------------------------------------------------------------ |
| `install --target omp` steps           | `base` (+ opt-in `settings`, `rules`) | `base`, `dedupe` (default on), opt-in `settings`, `rules`                |
| `--only` values for omp                | `base,settings,rules`                 | `base,dedupe,settings,rules`                                             |
| `--intent base`/`plugins` on omp       | `base`                                | `base,dedupe`                                                            |
| `install --target agents` with OMP ycc | no OMP message                        | W5 line                                                                  |
| `remove --target omp --only base`      | packages only                         | packages + owned dedupe entries (+ empty project residue at `--project`) |
| OMP `ycc-mcp` servers                  | 9 (linear-personal shadowed)          | 10                                                                       |

## Mandatory Reading

| File                                                                      | Why                                                                                                            |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `docs/research/yan-1176-omp-coexistence/feature-spec.md`                  | Decisions D1–D14, precedence contract, W1–W5 text, edge cases                                                  |
| `docs/research/yan-1176-omp-coexistence/research-live-probes.md`          | Probe setup (bwrap shape, probe extension), the observed counts the harness must reproduce                     |
| `docs/research/yan-1176-omp-coexistence/research-technical.md`            | Data models, step contract, generator transform                                                                |
| `scripts/omp_install.py:59-190,521-690,834-945,1140-1160`                 | `omp_bin`/`clean_env`, `agents_overlap`/`warn_agents_overlap`, `install`, `remove`, migrate call site          |
| `scripts/install_slices.py:58-85,136-160`                                 | `SPECS` (dirs per target) and the ownership ledger `state_path`/`load_state`                                   |
| `scripts/merge_managed_config.py:66-80,196-215,488-496,642-700,1052-1097` | Policy docs, the `omp-config` profile, `union_lists`, `plan_merge` list-union, `plan_list_removals`            |
| `scripts/lib/install/targets/omp.sh:15-60,100-200`                        | Step contract, `omp_agent_dir`, `omp_config_dest`, `omp_merge_settings`, sync/remove                           |
| `scripts/lib/install/steps.sh:20-51,175-190,465-480`                      | `step_enabled` defaults, `config_groups_for_target`, project gate                                              |
| `scripts/lib/install/targets/agents.sh:51-78,100-122`                     | `agents_skills_present`, `agents_duplicate_hint`, `sync_agents_target`                                         |
| `scripts/generate_omp_packages.py:55-56,196-260`                          | `SOURCE_MCP_PATH`, `MCP_CONFIG`, `mcp_source`, `mcp_payloads`, `build_output`                                  |
| `scripts/validate_omp_native.py:53,220-250,380-402`                       | `MCP_ROOT_ENTRIES`, `hook_surface_errors`, `mcp_closure_errors`                                                |
| `scripts/omp_native_smoke.py:248-320,370-384`                             | `mcp_probe`, `connection`, `check_mcp_listed`, check dispatch table                                            |
| `scripts/test-omp-native-packages.sh:84-200,257-340,373-412`              | Sandbox (`clean`, `run`, `o`, `host`, `check`), null model, MCP probe, the `mcp-listed` block                  |
| `scripts/test-omp-install-lifecycle.sh:40-130`                            | Sandbox variant that runs the real `install.sh` (`--ro-bind "$repo"`, `YCC_INSTALL_SKIP_BUILD=1`, `extra_env`) |
| `scripts/tests/install/fake_omp.py:1-60,1770-1800`                        | Fake omp contract, the `config` dispatcher to extend                                                           |

## External Documentation

OMP v18.12.5, tag commit `d5cd750e`:

- `docs/skills.md:91-135`: collision aliases, and `ignoredSkills` matching both the raw and final name.
- `docs/settings.md:267,310-340`: arrays replace across layers; path-scoped provider arrays.
- `docs/mcp-config.md:111,236-249,501-511`: `requestIdFormat` is native-only, OAuth credential keying,
  precedence.
- Source:
  - `src/extensibility/skills.ts:62-199,289-470`;
  - `src/capability/mcp.ts:77-129`;
  - `src/mcp/oauth-flow.ts:16-34`;
  - `src/discovery/helpers.ts:1222-1450` (plugin roots);
  - `src/capability/index.ts:51-60,363-373` (foreign gate).

Linear MCP: <https://linear.app/docs/mcp.md> documents `/mcp` and `/mcp/readonly`, and OAuth 2.1 with DCR.

## Patterns to Mirror

### MERGE_PROFILE

```python
# scripts/merge_managed_config.py:200-210 — add a second group beside "settings"
"omp-config": {"format": "yaml", "refuse_symlink": True, "backup_original": True,
    "groups": {"settings": [...], "dedupe": [{"path": ["skills", "ignoredSkills"], "policy": "list-union"}]}},
```

### LEDGER

```python
# scripts/install_slices.py:136-151 — ownership ledger, keyed by the install dir
units = install_slices.load_state(install_slices.state_path())
owned = set(units.get(str(Path.home() / ".agents/skills"), [])) - {"ycc-shared"}
```

### OVERLAP (to generalize, then delete)

```python
# scripts/omp_install.py:167-186 — agents_overlap / warn_agents_overlap (replaced by coexistence_plan)
names.update(path.name for path in skills.iterdir() if (path / "SKILL.md").is_file())
```

### CONNECTION_KEY

```python
# scripts/omp_native_smoke.py:267-273 — mirrors isSameMCPConnection; move into generate_omp_packages
def connection(server): ...  # stdio: command,args,env,cwd; http: url,headers
```

### SHELL_MERGE_CALL

```bash
# scripts/lib/install/targets/omp.sh:146-157 — omp_merge_settings; dedupe mirrors it with group "dedupe"
merge_settings_config omp-config "${src}" "$(omp_config_dest "${agent_dir}")" "${groups}" "${extra[@]}"
```

### LIVE_HARNESS

```bash
# scripts/test-omp-install-lifecycle.sh:80-112 — bwrap --tmpfs "$real_home" --ro-bind "$repo"; env -i; YCC_INSTALL_SKIP_BUILD=1
# scripts/test-omp-native-packages.sh:300-338 — probe extension via -e, RPC get_available_commands + get_state
```

## Files to Change

| File                                                              | Action                                                                                                                           | Task |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ---- |
| `scripts/generate_omp_packages.py`                                | UPDATE: `mcp_connection_key`, `omp_mcp_bytes`, `mcp_payloads`                                                                    | 1.1  |
| `scripts/test_generate_omp_packages.py`                           | UPDATE: transform + validator cases                                                                                              | 1.1  |
| `scripts/omp_install.py`                                          | UPDATE: `coexistence_plan`, `coexistence` CLI, W1–W5, residue cleanup in `remove`; DELETE `agents_overlap`/`warn_agents_overlap` | 1.2  |
| `scripts/test_omp_install.py`                                     | UPDATE: coexistence + residue cases; replace overlap assertion at `:706-712`                                                     | 1.2  |
| `scripts/tests/install/fake_omp.py`                               | UPDATE: `config get <key> --json` (reads `<agent>/config.yml`)                                                                   | 1.2  |
| `scripts/merge_managed_config.py`                                 | UPDATE: `omp-config` `dedupe` group                                                                                              | 1.3  |
| `scripts/test_merge_managed_config.py`                            | UPDATE: dedupe merge/remove cases                                                                                                | 1.3  |
| `docs/install/omp.md`                                             | UPDATE: "Coexistence with other runtimes" section; replace `:420-422`; MCP Duplicates bullet (`:129-137`)                        | 1.4  |
| `docs/install/agents.md`                                          | UPDATE: "Duplicate skills" adds the OMP note (W5)                                                                                | 1.4  |
| `docs/internal/adr/0002-omp-runtime-contract.md`                  | UPDATE: Consequences `:124-126`, YAN-1176 row `:150`                                                                             | 1.4  |
| `docs/internal/spikes/omp-runtime-contract.md`                    | UPDATE: §1.8 note, §5 dedupe question closed                                                                                     | 1.4  |
| `ycc/skills/_shared/references/target-capability-matrix.md`       | UPDATE: `SKILLS:omp`, `MCP:omp` (drop linear-personal gap), `INSTALL_PATH:omp`                                                   | 1.4  |
| `scripts/lib/install/targets/omp.sh`                              | UPDATE: `dedupe` step (sync + remove), steps/intents/project steps                                                               | 2.1  |
| `scripts/lib/install/steps.sh`                                    | UPDATE: `step_enabled dedupe` default on                                                                                         | 2.1  |
| `scripts/lib/install/targets/agents.sh`                           | UPDATE: `agents_duplicate_hint` calls `coexistence --warn --if-installed`                                                        | 2.1  |
| `install.sh`                                                      | UPDATE: help (`omp base→base,dedupe`, `--only` list)                                                                             | 2.1  |
| `scripts/tests/install/omp.sh`                                    | UPDATE: dedupe install/remove/`--only base`/dry-run; `cmp` at `:49` → transformed bytes                                          | 2.1  |
| `scripts/tests/install/agents.sh`                                 | UPDATE: W5 case                                                                                                                  | 2.1  |
| `scripts/validate_omp_native.py`                                  | UPDATE: `mcp_closure_errors` compares to `omp_mcp_bytes(source)`                                                                 | 2.2  |
| `scripts/omp_native_smoke.py`                                     | UPDATE: import `mcp_connection_key`; credential-id distinctness in `check_mcp_listed`                                            | 2.2  |
| `scripts/test-omp-native-packages.sh`                             | UPDATE: probe reports credential ids; PASS line (no linear-personal shadow)                                                      | 2.2  |
| `scripts/test-omp-coexistence.sh`                                 | CREATE: live mixed-runtime harness C1–C8                                                                                         | 3.1  |
| `scripts/lib/validate-scope.sh`, `scripts/test-validate-scope.sh` | UPDATE: map the new harness to `omp`                                                                                             | 3.1  |
| `packages/omp/ycc-mcp/.mcp.json`, matrix copies                   | REGENERATE (sync)                                                                                                                | 4.1  |

## NOT Building

- No edits to `~/.agents`, `~/.claude`, `~/.codex`, `~/.cursor` or opencode files from the OMP target (BR2).
- No dedupe for Claude slices (`ycc/<n>` would hide the native package; W4 instead) or opencode commands.
- No change to `mcp-configs/mcp.json` or the Claude/Codex/Cursor/opencode MCP outputs.
- No project-config writes; no hostile-repo wrapper/alias; no OMP extension.
- No upstream OMP changes (TUI collision warnings, trust gate): follow-up issues only.

## Step-by-Step Tasks

### Task 1.1: OMP MCP connection disambiguation (YAN-1291) — Depends on [none] — **Done**

- **BATCH**: B1
- **ACTION**: In `scripts/generate_omp_packages.py` add `mcp_connection_key(server: Mapping[str, Any]) -> str` (port of `omp_native_smoke.connection`, matching `isSameMCPConnection`: auth, oauth, requestIdFormat, transport, url+headers or command/args/env/cwd) and `omp_mcp_bytes(source: bytes) -> bytes`; `mcp_payloads` writes `omp_mcp_bytes(mcp_source(repo_root))`.
- **IMPLEMENT**: Walk `mcpServers` in order; a later http/sse server equivalent to an earlier one gets `ycc-server=<name>` appended to `url` (`urllib.parse`, keep existing query); a stdio duplicate raises `ValueError("<name>: same stdio connection as <first>; OMP would shadow it")`; unchanged input returns the exact source bytes, changed input `json.dumps(indent=2, ensure_ascii=False) + "\n"`; run `audit_no_secret_literals` on the result.
- **MIRROR**: CONNECTION_KEY; `mcp_source` fail-closed style.
- **TESTS** (`test_generate_omp_packages.py`): real source → only `linear-personal.url` differs, equals `https://mcp.linear.app/mcp?ycc-server=linear-personal`; no-duplicate source → bytes identical; existing query keeps both params; stdio duplicate raises; `${VAR}` placeholders untouched; update `test_mcp_package_ships_the_source_bytes…` to expect transformed bytes.
- **GOTCHA**: `requestIdFormat`/headers are NOT used as disambiguators (dropped for plugins / share the OAuth row; spec D11). Trailing slash changes Linear's RFC 8707 resource.
- **VALIDATE**: `python3 scripts/test_generate_omp_packages.py && mypy scripts/generate_omp_packages.py scripts/test_generate_omp_packages.py`

### Task 1.2: Coexistence helper, warnings, residue cleanup — Depends on [none] — **Done**

- **BATCH**: B1
- **ACTION**: In `scripts/omp_install.py` add `CoexistencePlan` and `coexistence_plan(packages, enabled_providers)` plus subcommand `coexistence --packages CSV (--emit PATH | --warn [--hidden N] [--if-installed])`; delete `agents_overlap`/`warn_agents_overlap` and route install, dry-run and migrate (`:616,:682,:1154`) to the W2/W3/W4 warning path.
- **IMPLEMENT**: Scan `(~/.agents/skills, agents)`, `(~/.codex/skills, codex)`, `(~/.config/opencode/skills, opencode)`; owned = ledger (`install_slices.load_state(state_path())[str(dir)]`) ∩ OMP package skill names − `ycc-shared`; unowned = on-disk dirs with a ycc name not in the ledger; claude overlap only when `omp config get enabledProviders --json` (cwd=`$HOME`) contains `claude|*|all` and `~/.claude/skills` holds owned ycc names. `--emit` writes `skills: {ignoredSkills: [...]}` (sorted) or nothing. `--warn` prints W1 (with `--hidden N`), else W2; W3; W4; `--if-installed` prints W5 only when `omp-native-install.json` records ycc for the current profile. `remove --scope project`: after uninstalls, delete `installed_plugins.json` == `{"version":2,"plugins":{}}` (parsed), `omp-plugins.lock.json` with empty `plugins` and `settings`, empty `node_modules/`, then empty `.omp/plugins` and `.omp`. Never under `$HOME`.
- **MIRROR**: OVERLAP, LEDGER; `OmpCli._query` for `config get`; `fake_omp.py` gains `config get <key> --json` returning `{"key","value","type","description"}` from `<agent>/config.yml` (default `[]`).
- **TESTS** (`test_omp_install.py`): owned overlap → entries `agents/<n>`; user-authored dir → W3 and no entry; no ledger → no entries; codex/opencode namespaces; claude opt-in → W4 text; `--if-installed` silent when OMP not recorded; exact W1–W5 strings; migrate preview now prints W2 (replace `:709` line); project remove leaves no `.omp/` when it was created by omp, keeps a pre-existing `.omp/` with other content.
- **GOTCHA**: `omp config path` creates files; use `config get` only in non-dry-run; dry-run assumes `[]` and says so.
- **VALIDATE**: `python3 scripts/test_omp_install.py && mypy scripts/omp_install.py scripts/test_omp_install.py scripts/tests/install/fake_omp.py`

### Task 1.3: `dedupe` merge group — Depends on [none] — **Done**

- **BATCH**: B1
- **ACTION**: Add group `dedupe` to `PROFILES["omp-config"]["groups"]` in `scripts/merge_managed_config.py`: `[{"path": ["skills", "ignoredSkills"], "policy": "list-union"}]`; update the module docstring.
- **IMPLEMENT**: No engine change expected; list-union already records `ADDED_ITEMS_KEY` and `--remove` takes back owned items, deleting the key/file when emptied.
- **MIRROR**: MERGE_PROFILE.
- **TESTS** (`test_merge_managed_config.py`): missing file → created with items; user items preserved and ordered; re-run idempotent; `--remove` removes only owned items, keeps user items, deletes file when only ycc wrote it; `settings` and `dedupe` groups coexist in one file without clobbering; symlinked dest refused.
- **VALIDATE**: `python3 scripts/test_merge_managed_config.py && mypy scripts/merge_managed_config.py`

### Task 1.4: Docs — Depends on [none] — **Done**

- **BATCH**: B1
- **ACTION**: Write `docs/install/omp.md` § "Coexistence With Other Runtimes" (after "Project Scope"): what loads once per component, the precedence contract (spec), the dedupe step and undo, W1–W5 meanings, `enabledProviders` effects (Claude slices outrank, `~/.claude.json` MCP shadows `ycc-mcp:*` + `disabledServers` recipe), Claude plugin never duplicates, profiles/`PI_CODING_AGENT_DIR` (plugins don't move), reload (`/reload-plugins` or new session), "Untrusted projects" (`omp --no-extensions --config <overlay mcp.enableProjectConfig: false>`; limits). Replace `:420-422`; update MCP Duplicates bullet (linear-personal now loads with its own login). Update `docs/install/agents.md`, ADR 0002 (Consequences + YAN-1176 row, note YAN-1291), spike §1.8/§5, matrix `SKILLS:omp`/`MCP:omp`/`INSTALL_PATH:omp`.
- **MIRROR**: existing `docs/install/omp.md` bullet style; matrix note format (`**CAPABILITY:target**`).
- **GOTCHA**: Never use `SHIM_PHRASES` (`validate_omp_native.py:93`); keep matrix cells `supported|partial|unsupported`; never claim OMP has a trust gate.
- **VALIDATE**: `python3 scripts/validate_capability_matrix.py && python3 scripts/test_validate_omp_hooks.py && npm run lint:modified`

### Task 2.1: Installer wiring — Depends on [1.2, 1.3] — **Done**

- **BATCH**: B2
- **ACTION**: `targets/omp.sh`: `omp_valid_steps` → `base,dedupe,settings,rules`; `omp_intent_steps base|plugins` → `base dedupe`; `omp_project_steps` → `base dedupe`; add `omp_dedupe_step` (tmp src via `coexistence --emit`, then `merge_settings_config omp-config <tmp> "$(omp_config_dest "$(omp_agent_dir)")" dedupe`, then `coexistence --warn --hidden N`) and run it after base; when dedupe is skipped run `coexistence --warn`. Remove path: run `... dedupe --remove` before package uninstall when `base` or `dedupe` is selected. `steps.sh` `step_enabled`: `dedupe` defaults on. `agents.sh` `agents_duplicate_hint`: call `python3 scripts/omp_install.py coexistence --packages '' --warn --if-installed` when omp_install helper exists. `install.sh` help text.
- **MIRROR**: SHELL_MERGE_CALL; `omp_settings_step` dry-run handling.
- **TESTS**: `scripts/tests/install/omp.sh`: agents then omp → W1 + config has `agents/backport`; `--only base` → W2, no config; `remove --only dedupe` → entries gone, user item kept; `--dry-run` writes nothing; `--project` writes user config; `cmp` at `:49` compares against transformed bytes (or checks only `linear-personal` URL). `scripts/tests/install/agents.sh`: omp recorded → W5.
- **VALIDATE**: `bash scripts/tests/install/omp.sh && bash scripts/tests/install/agents.sh && shellcheck scripts/lib/install/targets/omp.sh scripts/lib/install/targets/agents.sh scripts/lib/install/steps.sh`

### Task 2.2: Validator and smoke parity (YAN-1291) — Depends on [1.1] — **Done**

- **BATCH**: B2
- **ACTION**: `validate_omp_native.mcp_closure_errors` compares the package bytes to `generator.omp_mcp_bytes(source)`; `omp_native_smoke.connection` → `generate_omp_packages.mcp_connection_key`; `check_mcp_listed` asserts distinct `credentialIds` for distinct http URLs; `test-omp-native-packages.sh` `mcp-probe.ts` adds `credentialIds` via `@oh-my-pi/pi-coding-agent/mcp/oauth-flow` `mcpOAuthCredentialId`, and the PASS line drops "linear-personal shadowed by linear".
- **TESTS**: `test_generate_omp_packages.py` validator case (raw-source bytes now reported as drift) owned by 1.1; here run it.
- **VALIDATE**: `python3 scripts/test_generate_omp_packages.py && mypy scripts/validate_omp_native.py scripts/omp_native_smoke.py && shellcheck scripts/test-omp-native-packages.sh && bash scripts/test-omp-native-packages.sh` (local, opt-in)

### Task 3.1: Live mixed-runtime harness — Depends on [2.1, 2.2] — **Done**

- **BATCH**: B3
- **ACTION**: Create `scripts/test-omp-coexistence.sh` (opt-in, not CI) with the lifecycle-harness sandbox (bwrap, `--ro-bind "$repo"`, `env -i`, null model, `YCC_INSTALL_SKIP_BUILD=1`) and a probe extension like `research-live-probes.md` (skills final names + warnings, agents, commands, mcps/context-files winners and `_shadowed`). Wire in `validate-scope.sh` + `test-validate-scope.sh`.
- **IMPLEMENT** cases: C1 omp only (50/49/55/10 MCP, 0 shadowed); C2 real `install.sh install --target agents` then `--target omp` → 50 skills, 0 `agents/*`, empty `omp skill list` stderr, W1 printed; C3 Claude registry `ycc@ycc` copy → no duplicate; C4 `enabledProviders ["*"]` + claude/codex/cursor/opencode files → MCP each once, one context file, W4 printed, winners per spec precedence; C5 project install + project `.omp/skills/plan` → bare `plan` native:project, user install `[shadowed]`; C6 `--profile work` sees no ycc; C7 hostile project (hooks, extension, `.mcp.json`, project plugin MCP, `extensions:`) → markers present by default, none under `--no-extensions --config <overlay>`, ycc still loads; C8 `remove --target omp --only base` (user and `--project`) → `config.yml` back to pre-install bytes or absent, no `.omp/` residue, `agents` skills bare again.
- **MIRROR**: LIVE_HARNESS; `omp_native_smoke.py` `check` dispatch for assertions.
- **GOTCHA**: fixtures must be copies (symlinks into the real home dangle under bwrap); never touch real `~/.omp`/`~/.config/ycc`.
- **VALIDATE**: `bash -n scripts/test-omp-coexistence.sh && shellcheck scripts/test-omp-coexistence.sh && bash scripts/test-validate-scope.sh && bash scripts/test-omp-coexistence.sh` (paste summary into PR)

### Task 4.1: Regenerate and full validation — Depends on [3.1] — **Done**

- **BATCH**: B4
- **ACTION**: `./scripts/sync.sh` (regenerates `packages/omp/ycc-mcp/.mcp.json`, matrix copies); `./scripts/validate.sh` (~280 s); fix drift; confirm `git diff --stat -- mcp-configs packages/claude packages/cursor .codex-plugin .opencode-plugin` is empty.
- **VALIDATE**: `./scripts/sync.sh && ./scripts/validate.sh && git status --short`

## Testing Strategy

### Acceptance criterion → test

| Acceptance criterion                                                 | Deterministic CI                                   | Opt-in live                                                                        |
| -------------------------------------------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Mixed-runtime fixture: each component once, deterministic precedence | 1.2 plan cases; 2.1 shell suites                   | C1–C6                                                                              |
| Actionable warnings                                                  | Exact W1–W5 strings (1.2, 2.1)                     | C2, C4                                                                             |
| Untrusted project resources do not execute                           | `hook_surface_errors` (existing)                   | C7                                                                                 |
| Uninstall/disable restores prior state                               | 1.2 residue, 1.3 remove, 2.1 remove                | C8                                                                                 |
| YAN-1291 both load, linear not shadowed, OAuth separate              | 1.1 transform tests; 2.2 validator                 | `test-omp-native-packages.sh` mcp-listed (shadowed empty, distinct credential ids) |
| No regression Claude/Codex/Cursor                                    | `validate.sh` byte/parity checks; source unchanged | —                                                                                  |

### Edge Cases Checklist

- [ ] User-authored `~/.agents/skills/<ycc-name>` never hidden (W3).
- [ ] Pre-ledger agents install → warnings only.
- [ ] Project `.omp/config.yml` `skills.ignoredSkills` replaces user list (documented).
- [ ] `--dry-run` runs neither `omp config path` nor any write.
- [ ] Second profile gets its own entries.
- [ ] Existing `?query` on a duplicate URL keeps both params.

## Validation Commands

### Static Analysis

```bash
mypy
./scripts/lint.sh --python --shell --docs
```

### Unit Tests

```bash
python3 scripts/test_generate_omp_packages.py
python3 scripts/test_omp_install.py
python3 scripts/test_merge_managed_config.py
bash scripts/tests/install/omp.sh
bash scripts/tests/install/agents.sh
bash scripts/test-validate-scope.sh
python3 scripts/validate_capability_matrix.py
```

### Full Test Suite

```bash
./scripts/sync.sh
./scripts/validate.sh            # ~280 s; also the lefthook pre-push hook (push async)
```

### Manual Validation

- [ ] `bash scripts/test-omp-coexistence.sh` and `bash scripts/test-omp-native-packages.sh` pass; paste summaries into the PR.
- [ ] Maintainer: `/mcp reauth ycc-mcp:linear` and `ycc-mcp:linear-personal` with two Linear accounts; both stay logged in.

## Acceptance Criteria

- [ ] Default `install --target all` on OMP loads each ycc skill once (50), with no `omp skill list` warnings; agents, commands, rules, MCP and context files once each (C1–C4).
- [ ] W1–W5 print with the exact text and a working command.
- [ ] Untrusted project fixture runs nothing under the documented invocation (C7); ycc ships no OMP code.
- [ ] `remove --target omp --only base` (user and `--project`) restores the prior state (C8).
- [ ] `ycc-mcp:linear-personal` loads beside `ycc-mcp:linear`, shadowed set empty, distinct OAuth credential ids.
- [ ] `mcp-configs/mcp.json` and non-OMP packages unchanged; `./scripts/sync.sh` and `./scripts/validate.sh` pass.

## Completion Checklist

- [ ] New code follows the `*_errors` / fail-closed patterns; no stubs.
- [ ] `warn_agents_overlap` and its old message removed everywhere (grep).
- [ ] Generated trees regenerated, never hand-edited.
- [ ] PR body: target release v6.1.0, `Closes #417`, `Closes #418`, harness summaries, decision log (D3 final).

## Decision Log

| #     | Decision                                                                                                                       | Source     |
| ----- | ------------------------------------------------------------------------------------------------------------------------------ | ---------- |
| D1    | Owned `<ns>/<name>` entries in user `skills.ignoredSkills`                                                                     | spec D1    |
| D2    | Dedupe agents/codex/opencode only; Claude gets W4                                                                              | spec D2    |
| D3    | Dedupe default-on with `base`; `--only base` skips (**final**, confirmed by the user)                                          | spec D3    |
| D4    | User `config.yml` only, never project                                                                                          | spec D4    |
| D5    | One `coexistence` helper, W1–W5                                                                                                | spec D5    |
| D6–D7 | No MCP/commands/agents/rules/hooks writes; document                                                                            | spec D6–D7 |
| D8    | Documented, tested untrusted-repo invocation                                                                                   | spec D8    |
| D9    | Remove takes back entries and empty project residue                                                                            | spec D9    |
| D10   | Per-profile; `PI_CODING_AGENT_DIR` doesn't move plugins                                                                        | spec D10   |
| D11   | YAN-1291: `?ycc-server=<name>` in OMP generator only; the OMP byte-copy validator compares to the transformed file (**final**) | spec D11   |
| D12   | Stdio duplicates fail closed                                                                                                   | spec D12   |
| D13   | New `test-omp-coexistence.sh`; native harness only for YAN-1291                                                                | spec D13   |
| D14   | Reload: new session or `/reload-plugins` only                                                                                  | spec D14   |

## Risks

| Risk                                    | Likelihood | Impact | Mitigation                                                  |
| --------------------------------------- | ---------- | ------ | ----------------------------------------------------------- |
| OMP changes alias namespacing           | Low        | Med    | C2/C4 assert alias names                                    |
| Default-on config write surprises users | Med        | Low    | Hash-owned, dry-run, `--only base`, reversible (D3 flagged) |
| Linear rejects unknown query later      | Low        | Med    | One-function rollback to won't-fix                          |
| Two-account OAuth not exercised live    | —          | Med    | Credential-id + metadata proof; manual check                |
| Parallel B1 tasks drift on W-text       | Low        | Low    | Text fixed in spec; 2.1 integrates                          |

## Implementation Deviations

- **`remove --only base` and dedupe.** The entries go when the last recorded ycc install
  of the profile goes (`omp_install.py recorded --except-scope`). Removing a `--project`
  install while the user install remains keeps them, because the user install still exposes
  the duplicates. `--only dedupe` always takes them back. C8 and `scripts/tests/install/omp.sh` cover both paths.
- **Owned overlap counts only differing copies.** OMP drops a byte-identical copy without a
  warning, so `coexistence_plan` makes no entry for it. Live, that is 41 of the 49 agents
  skills, matching probe B.
- **W5 in a combined run.** When one run has both the agents and omp targets, W5 is not
  printed: the omp target's dedupe step (W1) or its W2 covers the same overlap.
- **Probe settings.** The live probe calls `loadSkills` with the session's
  `cfgSkills`/`cfgDisabledExtensions`, as `session-tools.ts` does. Without them,
  `ignoredSkills` would not apply.

## Notes

- Spec probes used `/tmp/yan1176-exp` (bwrap, no network, null model); the real `~/.omp` was never touched.
- Follow-ups: upstream OMP issues (TUI collision warnings, project trust gate); YAN-1178 may fold the coexistence harness into the live matrix.
