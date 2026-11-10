# Feature Spec: OMP coexistence with other ycc runtimes, plus linear-personal on OMP

- **Tickets.** Linear YAN-1176 (GitHub #417) and YAN-1291 (GitHub #418), in one PR.
- **Target release.** ystack v6.1.0, trunk only.
- **Runtime.** oh-my-pi (`omp`) 18.12.5, upstream `can1357/oh-my-pi` tag `v18.12.5` (commit
  `d5cd750e41fede277f9eb933455da92a0738915e`). The supported floor stays `>=18.12.2` (ADR 0002).

Evidence tags:

- **[V-live]**: observed with the installed `omp 18.12.5` in the throwaway sandbox `/tmp/yan1176-exp`
  (bwrap with the real home hidden, `--unshare-net`, `env -i`, a null model at `127.0.0.1:9`). Never
  the user's `~/.omp`. Full log: [`research-live-probes.md`](research-live-probes.md).
- **[V-src]**: upstream source at the tag above. `src/` = `packages/coding-agent/src/`.
- **[INFERENCE]**: not verified.

## Executive Summary

On OMP, ycc duplicates by default only through `~/.agents/skills`: 41 `agents/<name>` aliases. ycc
will hide its own copies with owned, reversible `skills.ignoredSkills` entries, and replace the
harmful warning with actionable lines. It will document and test the one safe invocation for
untrusted repos and make uninstall restore the prior state. For YAN-1291, the OMP-only generated URL
`?ycc-server=linear-personal` lets both Linear servers load with separate OAuth tokens.

### Findings

- **Agents-target copies.** OMP loads `~/.agents/skills` by default. The agents-target copies (also
  where Codex, Cursor and opencode skills are consolidated) differ in text from the OMP package. OMP
  keeps the package copy under the bare name and adds **41 `agents/<name>` aliases**, with 41
  collision warnings and +17 % prompt [V-live probe B].
- **Everything else stays single.** Agents, rules, global instructions, hooks and MCP stay single by
  OMP's own dedupe. A Claude marketplace `ycc@ycc` never duplicates either, because OMP's registry is
  authoritative per plugin id [V-live L, W].
- **Opt-in imports.** Only explicit `enabledProviders` widening adds more aliases (`codex/`, `opencode/`).
  It also lets standalone `~/.claude/skills` outrank the package at priority 80 [V-live C].

### Solution

ycc fixes this without touching other targets' files:

1. **`dedupe` step.** It is default-on with `install --target omp`. It merges the ledger-owned aliases
   (`agents/<n>`, `codex/<n>`, `opencode/<n>`) into the user `config.yml` `skills.ignoredSkills`, using
   the existing hash-owned `list-union` merge.
   - OMP globs hide only the alias, so the other tool's copy reappears by itself once the OMP package
     is disabled or removed [V-live M′, V].
   - User-authored skills are never hidden. `remove --target omp` takes the entries back.
2. **One `coexistence` helper.** It prints actionable lines W1–W5 (hidden, skipped, unowned, Claude
   opt-in outranks, agents-after-omp). It replaces today's warn-only line, which tells users to delete
   `~/.agents/skills` and so breaks Codex, Cursor and opencode.
3. **Trust boundary.** ycc ships no OMP-executable code (existing guard). OMP has no trust gate, and a
   project config can override user kill switches [V-live]. Docs and a live case record the one tested
   safe invocation, `omp --no-extensions --config <user overlay: mcp.enableProjectConfig: false>`: no
   project hook, extension, MCP or plugin MCP runs, and ycc still loads [V-live].
4. **Uninstall restores prior state.** Dedupe entries are taken back. `--project` removal also deletes
   the empty `.omp/plugins/` residue that omp leaves [V-live G].
5. **YAN-1291 ships.** The OMP generator appends `?ycc-server=linear-personal` to the later equivalent
   HTTP server, in `packages/omp/ycc-mcp/.mcp.json` only.
   - OMP then keeps both servers, and their OAuth credential ids differ.
   - Linear ignores the parameter: same challenge, same `resource` [V-live].
   - `mcp-configs/mcp.json` and the Claude, Codex and Cursor packages are byte-unchanged.

## External Dependencies

### APIs and Services

#### OMP discovery and dedupe (all [V-src], confirmed [V-live])

| Component         | Key                                                                                                                        | Precedence                                                                                                                                               | Duplicate behavior                                                                                                                                                                             |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Skills            | frontmatter `name`                                                                                                         | native 100 > skillshare 95 > omp-plugins 90 > claude 80 > agent-plugins 75 > claude-plugins (OMP registry) = agents = codex 70 > opencode 55 > github 30 | Identical body+frontmatter → dropped silently. Differing → `<ns>/<name>` alias + `name collision` warning (`src/extensibility/skills.ts:140-199`). The only surface is `omp skill list` stderr |
| Skill filters     | `skills.ignoredSkills` (glob on the raw **and** final name), `disabledExtensions: skill:<n>`, `skills.enable*User/Project` | Arrays replace across user/project/overlay layers                                                                                                        | `agents/*` hides aliases only [V-live M]                                                                                                                                                       |
| Slash commands    | `name`                                                                                                                     | native > omp-plugins > claude 80 > claude-plugins (`<plugin>:<cmd>`) = agents = codex > opencode                                                         | First-wins, silent. Bare opencode `<cmd>` and `ycc:<cmd>` both load under opt-in [V-live P]                                                                                                    |
| Task agents       | `name`                                                                                                                     | project `.omp/agents` > user > extension pkgs > plugin roots (project first) > bundled                                                                   | Foreign agent dirs are never read [V-live C]                                                                                                                                                   |
| Rules             | `name`                                                                                                                     | native > omp-plugins > claude-plugins = agents > cursor …                                                                                                | First-wins, silent                                                                                                                                                                             |
| MCP               | `name` + `isSameMCPConnection`                                                                                             | native > omp-plugins > claude 80 > agent-plugins > claude-plugins = codex > gemini > opencode > cursor > mcp-json 5                                      | A same name or equivalent connection is shadowed. `disabledServers` (user `mcp.json`) wins over all                                                                                            |
| Context files     | level + basename                                                                                                           | native `<agentDir>/AGENTS.md` > claude `CLAUDE.md` > codex > opencode                                                                                    | One loads [V-live N, X]                                                                                                                                                                        |
| Extensions/hooks  | absolute path                                                                                                              | all providers' `hooks/{pre,post}/*.ts`, `.omp/extensions`, `extensions:`, `-e`                                                                           | Path-only dedupe (YAN-1174 herdr note)                                                                                                                                                         |
| Plugin roots      | plugin id                                                                                                                  | `--plugin-dir` > project registry > OMP user registry > Claude registry (dropped per id)                                                                 | `helpers.ts:1355-1442`                                                                                                                                                                         |
| Foreign user dirs | –                                                                                                                          | Opt-in through `enabledProviders` (`index.ts:51-60,363-373`). `~/.agents` and native are always on                                                       | –                                                                                                                                                                                              |

#### Profiles, reload, trust

- **Profiles.** `--profile`/`OMP_PROFILE` move plugins, `config.yml`, `mcp.json` and `agent.db`.
  `PI_CODING_AGENT_DIR` moves only the default agent dir, **not** the plugins dir [V-live]. `~/.agents`,
  `~/.claude`, `~/.codex` and project dirs are shared [V-live J].
- **Reload.**
  - Discovery runs at session start.
  - `/reload-plugins` refreshes agents, skills, commands and MCP.
  - `/plugins enable|disable` refreshes at once.
  - Hooks, tools and extensions need a restart [V-src].
- **Trust.** `isProjectTrusted: () => true`. Project extensions, hooks, MCP, plugin registries and the
  `extensions:` setting execute at session start [V-live]. A project `.omp/config.yml` beats a user
  `disabledProviders` or `mcp.enableProjectConfig` [V-live]. A `--config` overlay beats project config.

#### MCP identity and OAuth (YAN-1291)

- **Equivalence** compares `auth`, `oauth`, `requestIdFormat`, the transport, the exact `url` string and
  `headers` (`src/capability/mcp.ts:77-106`).
- **OAuth id** is `mcp_oauth:profile:<profile>:<url verbatim, query included>` (`src/mcp/oauth-flow.ts:16-34`).
- **Variants** [V-live]:

  | Variant                                   | Effect                                            |
  | ----------------------------------------- | ------------------------------------------------- |
  | query                                     | both load; distinct ids                           |
  | header                                    | both load; **shared** id                          |
  | `requestIdFormat` in a plugin `.mcp.json` | dropped, still shadowed                           |
  | trailing `/`                              | Linear advertises a different resource (`…/mcp/`) |

- **Linear** documents `https://mcp.linear.app/mcp` (OAuth 2.1 + DCR) and `/mcp/readonly`
  (<https://linear.app/docs/mcp.md>). A `?ycc-server=linear-personal` request returns the identical
  401 and protected-resource document (`resource: https://mcp.linear.app/mcp`) [V-live].

### Libraries and SDKs

- No new dependencies.
- **Reused:**
  - `merge_managed_config.py` (`omp-config` YAML profile, `list-union`, `ADDED_ITEMS_KEY`);
  - `install_slices.state_path`/`load_state` (`installed-units.json`);
  - `urllib.parse` (stdlib);
  - the existing bwrap harness shape.

### External Documentation

- Upstream docs: `docs/skills.md:91-135`, `docs/settings.md:267,310-340`, `docs/mcp-config.md:111,236-249,501-511`,
  `docs/slash-command-internals.md`, `docs/task-agent-discovery.md`, `docs/extension-loading.md`,
  `docs/marketplace.md`, `docs/plugin-manager-installer-plumbing.md:247-249`.
- Linear MCP: <https://linear.app/docs/mcp.md>.
- RFC 9728 (protected-resource metadata) and RFC 8707 (resource indicators).

## Business Requirements

### User Stories

- **US1.** Multi-tool users see each ycc skill once in OMP, from the OMP package.
- **US2.** Each overlap gets one actionable line that names the source and the exact fix.
- **US3.** Removing or disabling ycc on OMP restores what OMP showed before.
- **US4.** A documented, tested way to open an untrusted repo with ycc loaded and nothing from the repo
  executing.
- **US5.** Both `ycc-mcp:linear` and `ycc-mcp:linear-personal` load on OMP with separate logins, with
  no change for Claude, Codex or Cursor.

### Business Rules

- **BR1.** Native beats fallback: the OMP package is the ycc source on OMP.
- **BR2.** The OMP target never edits other targets' files (`~/.agents`, `~/.claude`, `~/.codex`, …).
- **BR3.** Config writes are hash-owned, reversible and user-scope only. Project config is never written.
- **BR4.** Precedence is deterministic and documented (§ Precedence contract).
- **BR5.** No parity or coexistence claim without a live or hermetic test.
- **BR6.** Only ledger-owned ycc entries are ever hidden.
- **BR7.** YAN-1291 changes only the generated OMP `ycc-mcp` package.

### Edge Cases

| Case                                                  | Handling                                                                                                                  |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| User-authored `~/.agents/skills/plan`                 | Not in the ledger → never hidden; W3 names it                                                                             |
| Pre-ledger agents install                             | No record → W3. The fix: re-run `install --target agents` once                                                            |
| Agents installed after OMP                            | Agents hint W5 → `install --target omp --only dedupe`                                                                     |
| ycc OMP disabled or uninstalled                       | The alias entry no longer matches, so the agents copy keeps its bare name and loads [V-live M′]                           |
| Project `.omp/config.yml` sets `skills.ignoredSkills` | It replaces the user list in that project; documented                                                                     |
| `--project` install                                   | Dedupe writes the **user** `config.yml` (the duplicate is user-level)                                                     |
| Two profiles                                          | Per `omp config path`; run per profile (existing note)                                                                    |
| `PI_CODING_AGENT_DIR`                                 | `config.yml` follows it; plugins do not; entries follow `omp config path`                                                 |
| `enabledProviders: [claude]` and Claude slices        | Claude holds the bare names at 80 → W4 (remove the slices or drop the opt-in). No ycc write                               |
| Claude marketplace `ycc@ycc`                          | No duplicate (OMP registry wins per id). After an OMP uninstall plus opt-in, the Claude plugin serves [V-live T]          |
| Codex/Cursor `~/.claude.json` MCP with opt-in         | Claude names shadow `ycc-mcp:*` (one copy). The docs give the `disabledServers` recipe that restores `ycc-mcp:*` [V-live] |
| Symlinked or invalid `config.yml`                     | The merge refuses; nothing changes                                                                                        |
| A stdio duplicate connection in `mcp.json` (future)   | The generator fails closed                                                                                                |

### Success Criteria (AC mapping)

| Acceptance criterion                                                        | Proof                                                                                                                                                              |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Mixed-runtime fixture: each component loaded once, deterministic precedence | Live `scripts/test-omp-coexistence.sh` C2–C6 (counts per component, winner paths, empty `omp skill list` stderr); hermetic `test_omp_install.py` coexistence cases |
| Actionable warnings                                                         | Hermetic exact-text assertions for W1–W5 (`test_omp_install.py`, `scripts/tests/install/{omp,agents}.sh`)                                                          |
| Untrusted project resources do not execute                                  | `hook_surface_errors` (existing); live C7 (no marker under the documented invocation; markers present without it, proving the fixture is live)                     |
| Uninstall/disable restores prior state                                      | Live C8 snapshot diff (`config.yml`, `installed_plugins.json`, project tree); hermetic remove tests                                                                |
| YAN-1291: both load, shadowed empty, separate OAuth                         | `test-omp-native-packages.sh` `mcp-listed` (`shadowed == []`, distinct credential ids); generator and validator unit tests                                         |
| No regression for Claude, Codex, Cursor                                     | `mcp-configs/mcp.json` unchanged; `./scripts/validate.sh`                                                                                                          |

## Technical Specifications

### Architecture Overview

```text
install --target omp            remove --target omp --only base|dedupe
  base    omp_install.py install      dedupe --remove (merge helper, owned items)
  dedupe  omp_install.py coexistence --emit tmp.yml → merge_settings_config omp-config … dedupe
  settings/rules (opt-in, unchanged)
  omp_install.py coexistence --warn   (W1–W4)
install --target agents → agents_duplicate_hint → omp_install.py coexistence --warn --if-installed (W5)
generate_omp_packages.mcp_payloads → omp_mcp_bytes(source)   (YAN-1291)
validate_omp_native.mcp_closure_errors → compares to omp_mcp_bytes(source)
```

#### Precedence contract (documented in `docs/install/omp.md`)

1. Project native `.omp/*`.
2. User native `<agentDir>/*` (`disabledServers` above all MCP).
3. Opt-in Claude user skills and MCP (priority 80; they outrank the plugin; W4).
4. The OMP plugin: project install > user install. It replaces a Claude-registry entry with the same id.
5. `~/.agents/skills` (hidden by dedupe when owned).
6. Opt-in Codex, opencode and Cursor.
7. Built-ins.

Identical skills collapse. Equivalent MCP connections collapse onto the higher priority.

### Data Models

```yaml
# temp source written by omp_install.py coexistence --emit (never committed)
skills:
  ignoredSkills: [agents/backport, agents/blueprint, …] # sorted owned overlaps
```

- **Merge rule.** `PROFILES["omp-config"]["groups"]["dedupe"] = [{"path": ["skills", "ignoredSkills"], "policy": "list-union"}]`.
- **Entry rule.** For `(dir, ns)` in `(~/.agents/skills, agents)`, `(~/.codex/skills, codex)` and
  `(~/.config/opencode/skills, opencode)`, the entries are
  `ledger[dir] ∩ omp_skill_names(selected packages) − {ycc-shared}`.
- **Generated `packages/omp/ycc-mcp/.mcp.json` (only diff vs source):**
  `"linear-personal": {"type": "http", "url": "https://mcp.linear.app/mcp?ycc-server=linear-personal"}`.

### API Design

- **`omp_install.py`:**

  ```python
  @dataclass(frozen=True)
  class CoexistencePlan:
      entries: tuple[str, ...]
      owned: dict[str, tuple[str, ...]]
      unowned: dict[str, tuple[str, ...]]
      claude: tuple[str, ...]

  def coexistence_plan(packages: tuple[str, ...], enabled_providers: frozenset[str]) -> CoexistencePlan: ...
  ```

  - CLI `coexistence --packages CSV (--emit PATH | --warn [--hidden PATH] [--if-installed])`.
  - `--emit` writes the temp YAML and prints the count; it writes nothing when there are no entries.
  - `--warn` prints W1–W5.
  - `enabled_providers` comes from `omp config get enabledProviders --json` (run with `cwd=$HOME`;
    `fake_omp.py` gains `config get`).
  - `warn_agents_overlap` and `agents_overlap` are deleted. Their callers (install, dry-run, migrate)
    call `coexistence_warn`.

- **`generate_omp_packages.py`:**
  - `mcp_connection_key(server) -> str` mirrors `isSameMCPConnection`. `omp_native_smoke.connection`
    imports it.
  - `omp_mcp_bytes(source: bytes) -> bytes` adds `ycc-server=<name>` to a later equivalent http/sse
    URL. A stdio equivalence raises `ValueError`. With no change, it returns the source bytes.
- **`targets/omp.sh`:**
  - `omp_valid_steps` becomes `base,dedupe,settings,rules`; `base|plugins` maps to `base dedupe`; the
    project steps are `base dedupe`.
  - `omp_dedupe_step` and its remove counterpart.
  - `step_enabled dedupe` defaults on (`steps.sh`).
- **`omp_install.py remove --scope project`:** after the uninstalls, delete `.omp/plugins/{installed_plugins.json,omp-plugins.lock.json}` only when they are byte-equal to omp's empty forms, then the empty `node_modules/`, `.omp/plugins/` and `.omp/`.

## UX Considerations

### User Workflows

| Flow                               | Output                                                                                                                                              |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `install --target all`             | `[ok] OMP: hid 41 ycc duplicate skills (agents/…) via skills.ignoredSkills in <cfg>; ./install.sh remove --target omp --only dedupe restores them`  |
| `install --target omp --only base` | `[!!] OMP also loads 41 ycc skills from ~/.agents/skills as agents/<name>; run ./install.sh install --target omp --only dedupe to hide them in OMP` |
| Agents after OMP                   | `[!!] OMP also loads these skills; run ./install.sh install --target omp --only dedupe …`                                                           |
| `enabledProviders` ∋ claude        | W4 (text in [`research-technical.md`](research-technical.md))                                                                                       |
| Verify                             | `omp skill list` (stderr empty); `/mcp list`                                                                                                        |
| Untrusted repo                     | `omp --no-extensions --config ~/.omp/agent/untrusted.yml` (overlay `mcp: {enableProjectConfig: false}`)                                             |
| Remove                             | `remove --target omp --only base` (packages + dedupe + project residue), `--only dedupe` (entries only)                                             |

### Error States

- **Symlinked or invalid `config.yml`.** The merge error is printed and the install exits non-zero.
  Nothing is written.
- **`--dry-run`.** `would add N items to /skills/ignoredSkills`, and no `omp config path` call
  (existing rule).
- **Project `skills.ignoredSkills` replaces the user list.** Documented.

### Performance UX

Hiding 41 aliases removes about 3.6 k characters (−15 %) from every main-session system prompt
[V-live A vs B].

## Recommendations

### Implementation Approach

Ship in this order (parallel batches in the plan):

1. Pure functions: the generator transform and `coexistence_plan`, plus the merge group.
2. Installer wiring and the fake `config get`.
3. Validator and smoke parity.
4. The live harness.
5. Docs.
6. `sync.sh` and `validate.sh`.

### Technology Decisions

Reuse the hash-owned merge and the slice ledger; add no new state file. `skills.ignoredSkills` on the
alias is the only lever that hides exactly ycc's duplicates and self-heals (see Decisions D1–D3).

### Quick Wins

Replacing the current warning removes harmful advice (deleting `~/.agents/skills` breaks consolidated
Codex, Cursor and opencode).

### Future Enhancements

- Upstream OMP issues: show `skillWarnings` in the TUI, and add a project trust gate.
- Possible later: `ycc doctor --target omp` precedence report.

## Risk Assessment

### Technical Risks

| Risk                                                     | L   | I   | Mitigation                                                                                         |
| -------------------------------------------------------- | --- | --- | -------------------------------------------------------------------------------------------------- |
| OMP changes the alias namespace or glob semantics        | Low | Med | Live C2/C4 assert alias names; the version floor is unchanged                                      |
| Default-on dedupe writes `config.yml` on a plain install | –   | Low | Hash-owned; dry-run shows it; `--only base` skips; `remove` reverses (D3)                          |
| Linear starts rejecting unknown query params             | Low | Med | One-function rollback; docs ask for a re-check per release; no network in CI                       |
| Two-account OAuth not run live                           | –   | Med | Proven at the OMP credential-id and Linear metadata level; manual `/mcp reauth` check in the PR    |
| Project config replaces `ignoredSkills`                  | Med | Low | Documented                                                                                         |
| `fake_omp.py` `config get` drift from real omp           | Low | Low | Shape copied from the live `omp config get --json` output (`{"key","value","type","description"}`) |

### Integration Challenges

- `ALL_TARGETS` order runs agents before omp, so dedupe sees the fresh ledger in the same run.
- The validator must compare against the transform, not the raw source. The `cmp` check in
  `scripts/tests/install/omp.sh:49` and the `diff -r` in the harness change accordingly.

### Security Considerations

- **Critical:**
  - never write project config;
  - never delete or rewrite other targets' files;
  - never hide unowned skills;
  - no secrets in the generated `.mcp.json` (the audit runs on the transformed bytes).
- **Warnings:**
  - document the safe invocation and its limits (project plugin skills still load as text;
    `--no-extensions` also drops the user's own extensions, so use `--trusted-extension` to re-allow);
  - `enabledProviders` widening imports foreign MCP commands.

## Decisions Needed

All decisions are final (decision policy: security, UX, data integrity), with rationale. D3 and D11
were confirmed by the user.

| #   | Decision                                | Options                                                                                                                                                 | Chosen                                                                            | Why                                                                                                                                                                                    |
| --- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Duplicate lever for `~/.agents` copies  | (a) **owned `<ns>/<name>` entries in `skills.ignoredSkills`**; (b) delete the agents copies; (c) `skills.enableAgentsUser: false`; (d) warn only        | (a)                                                                               | (b) breaks consolidated Codex/Cursor/opencode and risks user data. (c) hides user-authored skills [V-live O]. (d) fails the AC. (a) hides exactly the alias and self-heals [V-live M′] |
| D2  | Which sources dedupe touches            | (a) **agents, codex, opencode, owned only**; (b) also Claude                                                                                            | (a)                                                                               | Claude holds the bare name at 80, so ignoring `ycc/<n>` would hide the native package. W4 tells the user                                                                               |
| D3  | When dedupe runs                        | (a) **default-on with `base`, `--only base` skips**; (b) opt-in `--dedupe`                                                                              | (a) — **final** (user-confirmed; new config write on a plain install; reversible) | The AC needs a single load by default. The write is hash-owned and removed by `remove`                                                                                                 |
| D4  | Where entries live                      | (a) **user `config.yml`**; (b) project config; (c) `--config` overlay                                                                                   | (a)                                                                               | (b) violates YAN-1175 D10. (c) is not loaded by default                                                                                                                                |
| D5  | Warnings                                | (a) **one `coexistence` helper, W1–W5, replacing `warn_agents_overlap`**                                                                                | (a)                                                                               | One source of truth. The old remedy is harmful                                                                                                                                         |
| D6  | MCP coexistence                         | (a) **rely on OMP equivalence; document the `disabledServers` recipe**                                                                                  | (a)                                                                               | Each server already loads once [V-live C]. A ycc write would fight user opt-in                                                                                                         |
| D7  | Commands, agents, rules, context, hooks | **No ycc change; document and test once-each**                                                                                                          | –                                                                                 | Already single, or opt-in only (opencode bare commands). The only command lever also hides user commands                                                                               |
| D8  | Trust boundary                          | (a) **document and test `--no-extensions --config <overlay>`**; (b) ship a wrapper/alias                                                                | (a)                                                                               | No new executable surface; a project config cannot override an overlay [V-live]                                                                                                        |
| D9  | Uninstall restore                       | **Take back dedupe entries; delete empty omp project residue only**                                                                                     | –                                                                                 | AC "restores prior state" [V-live G]. Byte-exact empty-form match only                                                                                                                 |
| D10 | Profiles / `PI_CODING_AGENT_DIR`        | **Per `omp config path`; document that `PI_CODING_AGENT_DIR` does not move plugins**                                                                    | –                                                                                 | [V-live]                                                                                                                                                                               |
| D11 | YAN-1291                                | (a) **`?ycc-server=<name>` on later equivalent HTTP servers, OMP generator only**; (b) header; (c) `requestIdFormat`; (d) trailing slash; (e) won't-fix | (a)                                                                               | (b) shares the token. (c) is dropped for plugins. (d) changes the RFC 8707 resource. (a) gives both servers, distinct credential ids and an unchanged Linear resource [V-live]         |
| D12 | Stdio equivalence in the source         | **Fail closed in the generator**                                                                                                                        | –                                                                                 | No safe disambiguation exists                                                                                                                                                          |
| D13 | Live proof                              | (a) **new `scripts/test-omp-coexistence.sh`**; extend `test-omp-native-packages.sh` only for YAN-1291                                                   | (a)                                                                               | Keeps the 512-line harness focused; reuses `omp_native_smoke.py`                                                                                                                       |
| D14 | Reload message                          | **Reuse `restart_line`** (new sessions, or `/reload-plugins`)                                                                                           | –                                                                                 | Whether a live `ignoredSkills` change applies without a restart is [INFERENCE]; claim only new sessions                                                                                |

## Task Breakdown Preview

### Phase 1: Pure logic (parallel)

- Generator transform and connection key (`generate_omp_packages.py` + tests).
- `coexistence_plan` and its CLI (`omp_install.py` + tests, `fake_omp.py config get`).
- Merge `dedupe` group (`merge_managed_config.py` + tests).

### Phase 2: Wiring (parallel)

- Installer steps (`targets/omp.sh`, `steps.sh`, `install.sh` help, `targets/agents.sh`, shell suites).
- Validator and smoke parity (`validate_omp_native.py`, `omp_native_smoke.py`, `test-omp-native-packages.sh`).

### Phase 3: Proof

- Live harness `scripts/test-omp-coexistence.sh` plus `validate-scope` wiring.

### Phase 4: Docs and regeneration

- `docs/install/omp.md`, ADR 0002, spike §1.8/§5, matrix, then `./scripts/sync.sh` and `./scripts/validate.sh`.

## Research References

- Live log: [`research-live-probes.md`](research-live-probes.md).
- Technical research: [`research-technical.md`](research-technical.md).
- Prior specs: `docs/research/yan-1175-omp-rules-settings/feature-spec.md`, `docs/research/yan-1174-omp-hooks-extension/`.
- Contract: `docs/internal/adr/0002-omp-runtime-contract.md`; `docs/internal/spikes/omp-runtime-contract.md` §1.8, §2.8, §5.
