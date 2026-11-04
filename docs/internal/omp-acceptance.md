# OMP live acceptance report (YAN-1178)

Target: ystack v6.1.0. Live runtime acceptance for the generated OMP (oh-my-pi) packages
`ycc`, `ycc-mcp` and `ycc-rules` and the `install.sh --target omp` lifecycle. Every row below
was run on 2026-10-22 against real omp binaries in clean isolated homes. Contract:
[ADR 0002](adr/0002-omp-runtime-contract.md). Install guide: [docs/install/omp.md](../install/omp.md).

## Environment

| Item        | Value                                                                                        |
| ----------- | -------------------------------------------------------------------------------------------- |
| Checkout    | `main` at `e877f67c` plus this change (packages at lockstep `6.0.0`)                         |
| omp, floor  | `omp/18.12.2`: upstream release `v18.12.2` `omp-linux-x64`, checked against `SHA256SUMS.txt` |
| omp, stable | `omp/18.12.6` (latest release, 2026-10-21), `~/.local/bin/omp`                               |
| Platform    | Linux 7.0.0-34-generic x86_64                                                                |
| Sandbox     | `bwrap-netns`: bubblewrap 0.11.1, private network namespace, real home hidden behind a tmpfs |
| Tools       | Python 3.14.4, git 2.53.0, herdr 0.8.2                                                       |

Each harness runs every omp call under `env -i` with HOME, XDG and TMPDIR inside a fresh
`mktemp` tree under `/tmp`. No credentials are present and no request leaves the sandbox. The
models are either a null provider on `127.0.0.1:9` or the scripted loopback provider below.

## How to reproduce

```bash
for omp in /path/to/omp-18.12.2 "$(command -v omp)"; do
  for h in native-packages install-lifecycle coexistence rules-settings runtime-contract-spike \
    scripted-sessions; do
    OMP_BIN=$omp ./scripts/test-omp-$h.sh
  done
  OMP_BIN=$omp ./scripts/test-omp-herdr-hooks.sh --herdr-pane
done
```

Add `--keep` to keep a sandbox and its `transcript.log` (argv, exit status and output of every
command). A failing run always keeps them.

`scripts/test-omp-scripted-sessions.sh` (new here) runs real omp sessions against
`scripts/omp_scripted_smoke.py`. That is a loopback OpenAI-compatible provider that answers each
request from a fixed tool-call script. Real tools, task subagents, MCP calls, TTSR rules and
approval prompts run, and no model reasons. Stub stdio servers stand in for `ycc-mcp:context7`
and add `ycc-mcp:smoke` through a user `mcp.json` override.

## Results

`18.12.2` and `18.12.6` give the same result in every row.

| Capability                                 | Harness: cases                                               | 18.12.2 | 18.12.6 | Evidence (PASS line summary)                                                                                                                                                                                                                                                  |
| ------------------------------------------ | ------------------------------------------------------------ | ------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Runtime contract (catalog, dialect, roots) | runtime-contract-spike: all                                  | pass    | pass    | `.omp-plugin` catalog preferred; `.omp-plugin` root keeps agent `model`; profile, XDG and `PI_CODING_AGENT_DIR` roots; git-subdir and link sources                                                                                                                            |
| Native package install (marketplace)       | native-packages: catalog, install, discovery                 | pass    | pass    | pinned fork registers `ycc@6.0.0`; `--dry-run` writes nothing; cache equals the package root; `doctor` clean; every `ycc:<skill>` command and agent                                                                                                                           |
| Native upgrade and uninstall               | native-packages: upgrade, uninstall                          | pass    | pass    | `.omp-plugin`-only bump ignored; lockstep bump upgrades `6.0.0 -> 6.0.2`; uninstall leaves no registry, lock, link, cache or command                                                                                                                                          |
| `install.sh` dry-run, user install, re-run | install-lifecycle: dry-run, install                          | pass    | pass    | dry-run writes no state; re-run reports `up to date (user)` with no omp mutation                                                                                                                                                                                              |
| Project scope                              | install-lifecycle: project, disabled; coexistence C5         | pass    | pass    | `--project` install shadows the user install; a disabled project install stays disabled                                                                                                                                                                                       |
| Upgrade, remove, migrate                   | install-lifecycle: upgrade, remove, migrate                  | pass    | pass    | `6.0.0 -> 6.0.1` re-export and upgrade; GC'd project cache reported and repaired; remove leaves nothing; migrate replaces a checkout link                                                                                                                                     |
| Profiles and XDG                           | install-lifecycle: profile, xdg; coexistence C6              | pass    | pass    | `OMP_PROFILE=work` isolated; `XDG_DATA_HOME/omp` honoured                                                                                                                                                                                                                     |
| Coexistence with other runtimes            | coexistence: C1-C4, C7, C8                                   | pass    | pass    | one ycc set loads; `dedupe` hides 41 `~/.agents` duplicates; Claude registry copy adds no duplicate; hostile project markers off under `--no-extensions`                                                                                                                      |
| MCP (`ycc-mcp`)                            | native-packages: ycc-mcp list/start/disable/override/removal | pass    | pass    | every shipped server is `ycc-mcp:<server>`, none shadowed, one OAuth id per URL; stdio stub starts; `disabledServers`/`enabledServers`; user override wins                                                                                                                    |
| Rules and context (`ycc-rules`)            | rules-settings: L1, L1T, L2                                  | pass    | pass    | always-apply bodies in `<generic-rules>`, the rest on demand; project rule wins at its cwd                                                                                                                                                                                    |
| Rule triggers in a live session (YAN-1546) | scripted-sessions: S3                                        | pass    | pass    | two `.py` writes and one `.go` write persist one `ycc-python-trigger` and one `ycc-golang-trigger` `ttsr_injection`; reminder after the first `.py` and the `.go` only                                                                                                        |
| Fallback paths (`--rules`, `--settings`)   | rules-settings: L1 (install), L3, L4                         | pass    | pass    | managed `modelRoles`, `retry.fallbackChains`, `tools.approvalMode` written; user keys kept; project config wins                                                                                                                                                               |
| Models and roles                           | scripted-sessions: S4; rules-settings: L3, L4                | pass    | pass    | 23 `@slow` agents on the slow role, 29 `@task` on the task role, 3 with no `model` on the default role                                                                                                                                                                        |
| All agents                                 | scripted-sessions: S4                                        | pass    | pass    | one `task` batch runs all 55 ycc agents to `status="completed"`                                                                                                                                                                                                               |
| Skills and commands, every category        | scripted-sessions: S5; native-packages: discovery            | pass    | pass    | `/ycc:clean` expands to `skill://clean`; all 50 skills read through `skill://` from the installed `ycc@ycc` cache                                                                                                                                                             |
| Agent scope guard (YAN-1540)               | scripted-sessions: S1, S2                                    | pass    | pass    | `git-cleanup` runs `git --version`; `&& touch` segment blocked with `ycc scope guard`, no file; MCP blocked direct and via `xd://`; `library-docs-writer` gets both context7 tools, is blocked on `smoke`, has no bash; main session unguarded; `--plugin-dir` loads no guard |
| Hooks and extensions (herdr)               | herdr-hooks: L1-L8                                           | pass    | pass    | herdr's own reporter reports startup/new sessions; fail-closed, refused, stalled and cancelled sockets bounded; no ycc extension carries a reporter; real herdr pane ignores a `ycc:omp` report                                                                               |
| Non-interactive modes                      | scripted-sessions: S6                                        | pass    | pass    | `--mode json` ends in `agent_end`; `-p` and `--mode rpc` drive scripted turns                                                                                                                                                                                                 |
| Permission prompts                         | scripted-sessions: S6                                        | pass    | pass    | with `approvalMode: write`, `-p` refuses bash without a UI; RPC asks one `Allow tool: bash` select (`Approve`, `Approve bash for this session`, `Deny`); Deny leaves no file, Approve writes it                                                                               |
| Offline and network failure                | scripted-sessions: S7                                        | pass    | pass    | a refused provider fails `-p` with `Retry budget exhausted ... connection refused`; `retry.fallbackChains.default` moves the prompt to a working model                                                                                                                        |

## Platform and coverage exclusions

None of these is a release blocker for v6.1.0.

| Cell                                       | Status        | Reason                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ------------------------------------------ | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| macOS (`omp-darwin-*`)                     | pass (env -i) | YAN-1555: `.github/workflows/omp-live.yml` run [39899013205](https://github.com/yandy-r/ystack/actions/runs/39899013205), macos-latest arm64, omp 18.12.2 and 18.12.6: all six harnesses passed (herdr-hooks excluded on every OS, see below). macOS passes `--allow-env-i` explicitly in that step only: bubblewrap is Linux only, so the sandbox is env -i + throwaway HOME/XDG + null/loopback provider, with no netns and the real home not tmpfs-hidden. Linux legs keep bwrap netns. |
| Windows (`omp-windows-*.exe`)              | unsupported   | `install.sh` and the harnesses are Bash and no Windows host was available. Decision (YAN-1556): native Windows is unsupported, WSL 2 expected but unverified; see [Platform Support](../install/omp.md#platform-support).                                                                                                                                                                                                                                                                  |
| Linux arm64 and musl builds                | not run       | No such host. The packages hold no native code, so the result is expected to match x64 `[INFERENCE]`.                                                                                                                                                                                                                                                                                                                                                                                      |
| Public fork install (`--public URL --ref`) | pass          | YAN-1180, omp 18.12.6 (bwrap netns): `test-omp-native-packages.sh --public https://github.com/yandy-r/ystack.git --ref 8e11f232…` passed every catalog, install, discovery, `ycc-mcp`, upgrade and uninstall check.                                                                                                                                                                                                                                                                        |
| Real-model workflow runs                   | not run       | No model credentials are used. The scripted model proves loading and tool plumbing, not workflow reasoning. Per-skill headless behaviour is in `omp-workflow-semantics.md`.                                                                                                                                                                                                                                                                                                                |
| Interactive TUI prompts                    | via RPC       | The same approval path is driven through `--mode rpc` `extension_ui_request` frames. The TUI renderer is not exercised.                                                                                                                                                                                                                                                                                                                                                                    |

## Harness fixes made during this run

Two existing harnesses failed on `main` before this change. Both failures were stale
expectations, not product bugs:

- `test-omp-install-lifecycle.sh` expected `remove --project` to report only `ycc` and
  `ycc-mcp` as kept user installs. Since YAN-1175 the base set also includes `ycc-rules`, so
  the expected line now lists all three.
- `test-omp-herdr-hooks.sh` L7 rejected any ycc package with `omp.extensions`. Since YAN-1250,
  `ycc@ycc` ships the scope guard. L7 now reads each declared extension (it must stay inside the
  package) and fails only when one contains a herdr reporter marker (`herdr`,
  `HERDR_SOCKET_PATH`, `report_agent_session`).

## Live CI (YAN-1552 / YAN-1555)

`.github/workflows/omp-live.yml` is the live gate beside `validate.yml` (which stays
runnable without omp). It downloads a pinned omp release binary from
`can1357/oh-my-pi` (asset per OS/arch: `omp-linux-x64`, `omp-darwin-arm64`, ...),
verifies it against that release's `SHA256SUMS.txt`, fails the job if the download,
checksum or `omp --version` does not match the pin, then runs
`python3 scripts/omp_builtin_commands.py --require`,
`python3 scripts/test_omp_builtin_commands.py`, and the harnesses below. Triggers: weekly
cron, pushes/PRs touching `scripts/*omp*`, `ycc/**`,
`packages/omp/**`, `.omp-plugin/**`, the workflow itself and related paths, and
`workflow_dispatch` (with an optional harness allow-list). Matrix: `ubuntu-latest`
and `macos-latest`, omp `18.12.2` (the `MIN_OMP_VERSION` floor), `18.12.6` and `18.16.0`,
`fail-fast: false`.

| Harness                              | In CI | Notes                                                                                                                                                                                          |
| ------------------------------------ | ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test-omp-native-packages.sh`        | yes   | null provider only                                                                                                                                                                             |
| `test-omp-install-lifecycle.sh`      | yes   | `YCC_INSTALL_SKIP_BUILD=1` inside the harness; checkout never written                                                                                                                          |
| `test-omp-coexistence.sh`            | yes   |                                                                                                                                                                                                |
| `test-omp-rules-settings.sh`         | yes   | needs PyYAML, installed in the workflow                                                                                                                                                        |
| `test-omp-scripted-sessions.sh`      | yes   | scripted loopback provider, no inference                                                                                                                                                       |
| `test-omp-runtime-contract-spike.sh` | yes   | null provider, no prompt sent                                                                                                                                                                  |
| `test-omp-herdr-hooks.sh`            | no    | Needs a real `herdr` binary and, for L8, a live herdr daemon/pane; there is no pinned upstream herdr release to install in CI yet, so it would only SKIP (exit 2). Stays a local/manual check. |

Omp is pinned by version and SHA-256 per asset in the workflow (also cross-checked against
the release's `SHA256SUMS.txt`); a job checks that the lowest matrix version equals
`MIN_OMP_VERSION`. The weekly cron re-tests those pins against runner-image drift; it does
not discover new omp releases.

Linux legs probe `bwrap --dev-bind / / --unshare-net /bin/true`; on Ubuntu 24.04 this fails
until `kernel.apparmor_restrict_unprivileged_userns=0` (a runner-level sysctl, applied only
when the probe fails and re-probed). The legs fail if bwrap still does not work; they never
fall back to `--allow-env-i`.

The harnesses are portable to macOS through `scripts/lib/omp-harness-common.sh`: resolved
sandbox root (`/tmp` is a symlink to `/private/tmp`), a `/bin/sh` directory wrapper instead of
GNU-only `env -C`, bsdtar-compatible options, and an explicit sandbox `PATH` extension
(`YCC_HARNESS_EXTRA_PATH`, validated absolute directories, honoured only with `--allow-env-i`
on Darwin) that carries GNU coreutils and Homebrew bash into the `env -i` sandbox.

A harness that prints `SKIP` (case-insensitive, at line start) fails the CI step: opting out locally must never become
a silent green in CI. On macOS every harness is passed `--allow-env-i` explicitly
(bubblewrap is unavailable there); on Linux the step refuses to run without bwrap
rather than weakening the sandbox.

## Post-release smoke: v6.1.0 (YAN-1560)

Run on 2026-10-23 against tag `v6.1.0` (commit `d59adab9fd904405e6c478bc7070728dba27a85e`).
Host: Linux x86_64, omp 18.12.6. No model was used: only the null provider ran.

| Check                                                                                                                               | Result | Evidence                                                                                                                                                                                                                                                                                                                           |
| ----------------------------------------------------------------------------------------------------------------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/test-omp-native-packages.sh --public https://github.com/yandy-r/ystack.git --ref d59adab9fd904405e6c478bc7070728dba27a85e` | pass   | Exit 0 in a bwrap netns sandbox. The catalog, install, discovery, `ycc-mcp` override, upgrade (6.1.0 → a lockstep bump) and uninstall checks all passed. The `ycc-mcp` start and `enabledServers` checks are documented SKIPs in `--public` mode: they need a fixture stub server, and the shipped servers cannot connect offline. |
| Clean HOME catalog install                                                                                                          | pass   | `env -i` with HOME and every XDG_* dir in a throwaway directory. `omp plugin marketplace add https://github.com/yandy-r/ystack.git` and `omp plugin install ycc@ycc ycc-mcp@ycc ycc-rules@ycc` both exited 0. `omp plugin list` showed `ycc@ycc`, `ycc-mcp@ycc` and `ycc-rules@ycc` at 6.1.0 (user scope).                         |
