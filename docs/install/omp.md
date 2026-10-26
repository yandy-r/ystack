# OMP Install Guide

This guide covers installing `ycc`, `ycc-mcp` and `ycc-rules` into OMP
(oh-my-pi) with `install.sh`, plus the opt-in global instructions, settings,
model roles and approval default.

There are two install paths. Both need `omp` 18.12.2 or newer:

- **Native catalog.** No checkout is needed. The repository publishes
  `.omp-plugin/marketplace.json`, so `omp` installs straight from GitHub
  (see [Install From The Catalog](#install-from-the-catalog)).
- **`install.sh`.** Run from a checkout. It adds ownership records,
  `update`/`remove`/`migrate`, dedupe, and the opt-in `--settings` and
  `--rules` steps.

## Prerequisites

- `omp` 18.12.2 or newer on `PATH` (`omp --version`). The installer stops
  with `omp >= 18.12.2 is required for --target omp` otherwise. The live
  acceptance run passed on 18.12.2 and 18.12.6.

The catalog path needs nothing else. `install.sh` also needs:

- Bash 4 or newer. Some `install.sh` paths (`--intent`, selection flags) use
  `mapfile` and associative arrays, which macOS's `/bin/bash` 3.2 lacks; put
  a newer `bash` (for example Homebrew's) first on `PATH`.
- `python3` with PyYAML (`python3 -c 'import yaml'`). Every omp step imports
  it; without it the installer stops before any write or `omp` call with
  `--target omp needs PyYAML for python3; install it with: python3 -m pip install --user pyyaml`.
- A checkout of this repository.

OMP has no trust prompt: installed plugin code runs with your user privileges.
Install only from a source you trust (see
[Security And Trust](#security-and-trust)).

## Platform Support

| Platform                       | Status                  | Notes                                                                                                                                                                                                                                                                                                      |
| ------------------------------ | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Linux x86_64                   | Supported, tested       | Every live acceptance row passed (see [Known Limitations](#known-limitations)).                                                                                                                                                                                                                            |
| Linux arm64, musl              | Expected, not verified  | The packages hold no native code; `install.sh` needs only Bash 4, `python3` with PyYAML and `omp`.                                                                                                                                                                                                         |
| macOS                          | Supported, tested in CI | Harnesses passed on macos-latest arm64 for omp 18.12.2 and 18.12.6 ([run 40278048271](https://github.com/yandy-r/ystack/actions/runs/40278048271), on `main` at `a7c38144`). That job uses `env -i` and a throwaway HOME; bubblewrap is Linux-only. `install.sh` still needs Bash 4+ ahead of `/bin/bash`. |
| Windows: WSL 2                 | Expected, not verified  | Run `install.sh` and the Linux `omp` build inside WSL; it then behaves as Linux.                                                                                                                                                                                                                           |
| Windows: native, Git Bash/MSYS | Unsupported             | See below.                                                                                                                                                                                                                                                                                                 |

Native Windows is unsupported for `install.sh --target omp` (decided in
YAN-1556): `install.sh` and every OMP test harness are Bash scripts, `--rules`
links `AGENTS.md` with a symlink, and no Windows host has run them. Use WSL 2
with the Linux `omp` build. A WSL install belongs to the WSL `omp`; a Windows
`omp.exe` keeps its own, separate plugin state.

## Package IDs

| Package id      | Ships                                                                               | Installed by default |
| --------------- | ----------------------------------------------------------------------------------- | -------------------- |
| `ycc@ycc`       | 50 skills, `/ycc:<skill>` commands, 55 task agents, the agent scope guard extension | yes                  |
| `ycc-mcp@ycc`   | MCP servers as `ycc-mcp:<server>`                                                   | yes                  |
| `ycc-rules@ycc` | 31 `ycc-<family>-<stem>` rules and 5 `ycc-<family>-trigger` rules                   | yes                  |
| `ycc-hooks`     | Excluded on OMP: ycc ships no OMP hooks                                             | no                   |
| `ycc-all`       | Excluded on OMP: OMP does not read plugin dependencies                              | no                   |

The three packages share one lockstep version (`omp plugin list` shows it).
`@ycc` names the marketplace: the repository catalog, or the export
`install.sh` registers. A `ycc` marketplace pointing at the checkout root is
an older setup; see [Migrate From Older Installs](#migrate-from-older-installs).

## Install From The Catalog

```bash
omp plugin marketplace add https://github.com/yandy-r/ystack.git
omp plugin install ycc@ycc ycc-mcp@ycc ycc-rules@ycc   # add --scope project for this repo only
```

Update with `omp plugin marketplace update ycc` and then `omp plugin upgrade`
with no arguments. That upgrades every marketplace plugin with a newer
version. `omp plugin upgrade` with package arguments upgrades only the first
one, so name one package per call (`omp plugin upgrade ycc-mcp@ycc`).

omp manages these installs on its own. `install.sh` does not record them, so
its `update` and `remove` leave them alone. Use one path per omp profile:
`install.sh` refuses to replace a `ycc` marketplace it did not register (see
[Troubleshooting](#troubleshooting)). To move a catalog install to
`install.sh`, run `omp plugin uninstall` for each package, then
`omp plugin marketplace remove ycc`. `./install.sh install --target omp --mode repo`
registers the same catalog and records the installs.

## Quick Start

```bash
./install.sh install --target omp
```

The `base` step generates and validates the OMP packages, then:

1. exports them to `${XDG_DATA_HOME:-~/.local/share}/ycc/omp-marketplace`;
2. registers that export as the OMP marketplace `ycc`
   (`omp plugin marketplace add`);
3. installs each package with `omp plugin install --scope user <package>@ycc`
   (`ycc@ycc`, `ycc-mcp@ycc` and `ycc-rules@ycc`).

What ycc installed is recorded in `~/.config/ycc/omp-native-install.json`.
`update`, `remove` and `migrate` act only on what that file records; an
install or marketplace you created yourself is reported and left untouched.

After `base`, the default-on `dedupe` step hides the ycc skills OMP would
otherwise load a second time from `~/.agents/skills` (see
[Coexistence With Other Runtimes](#coexistence-with-other-runtimes)). The omp
steps are `base`, `dedupe`, `settings` and `rules`; `--only base` skips
`dedupe` (`--package ycc` runs both; `--package ycc-mcp` or `ycc-rules`
alone ships no skills and runs only `base`).

`ycc@ycc` carries the skills, agents and commands (`/ycc:<skill>`) plus the
shared helpers. `ycc-mcp@ycc` carries the MCP servers (see
[MCP Servers](#mcp-servers)). `ycc-rules@ycc` carries the rules (see
[Rules](#rules)). Without `--package` all three are installed;
`--package ycc`, `--package ycc-mcp` or `--package ycc-rules` selects a
subset. `ycc-hooks` and `ycc-all` are excluded. ycc ships no OMP hooks
(herdr reporting comes from herdr itself, see [herdr](#herdr)), and OMP does
not read plugin dependencies; any other package is rejected with the package
model's reason.

Settings and global instructions are never package-implied. They need the
opt-in `--settings` and `--rules` flags (see
[Settings And Model Roles](#settings-and-model-roles---settings) and
[Global Instructions](#global-instructions---rules)), which cannot be
combined with `--package`.

## Update

Re-run the same command after pulling a new release:

```bash
./install.sh install --target omp
./install.sh sync --target omp --intent base   # equivalent
```

A re-run refreshes the export and runs `omp plugin marketplace update ycc`,
then `omp plugin upgrade --scope <scope> <package>@ycc` only when the exported
version differs from the installed one. When nothing changed, omp is not
touched and the installer prints `<package>@ycc <version> up to date`.

omp upgrades by version only. After you regenerate or edit the packages
without a version bump, the installer prints
`the export changed but its version did not … rerun with --force` instead;
run `./install.sh install --target omp --force` to reinstall the new content.

The `plugins` intent maps to the same `base` and `dedupe` steps
(`./install.sh sync --target omp --intent plugins`). The `settings` and
`rules` intents map to the opt-in `settings` and `rules` steps. Every other
intent is skipped with a notice.

## Reload Or Restart

After an install or update, run `/reload-plugins` in running omp sessions (or
restart them) to pick up skills, commands, agents and MCP servers. Rules and
`AGENTS.md` load at session start: use `/new` or restart. Settings reload
live. A package that ships hooks or extensions needs a session restart; the
installer says so when it applies. `ycc` ships the agent scope guard
extension (see [Agent Scope](#agent-scope)), so a `ycc` install or update asks
for a restart.

## Agent Scope

The `ycc` package ships one OMP extension, the agent scope guard
(`extensions/scope-guard.ts`, with its data in `extensions/agent-scopes.json`).
It only acts in ycc subagents. The main session and other agents are not
affected.

- **Shell.** An agent with command-scoped `Bash(<prefix>:*)` tools may run
  only commands where every pipeline, chain, subshell and `{ }` group segment
  starts with one of its prefixes. Commands the guard cannot verify are
  blocked: `$` expansions, command substitution, here-documents, output
  redirection other than `/dev/null`, leading `VAR=value` and `find -exec`.
- **MCP.** An agent that declares no MCP tools cannot call any. One that
  declares some (such as `library-docs-writer` with context7) can call only
  those, directly or through `write xd://`.

A blocked call returns a tool error that names the segment and the allowed
prefixes. The guard loads from installed packages only: `omp --plugin-dir`
does not load plugin extensions, and `--no-extensions` turns it off.

## MCP Servers

`ycc-mcp@ycc` ships the servers from `mcp-configs/mcp.json` as the package's
`.mcp.json` (only `linear-personal`'s URL differs, see Duplicates below). omp
loads them at session start and names each one
`ycc-mcp:<server>` (for example `ycc-mcp:github`). Generated files hold only
`${VAR}` placeholders, never secret values.

- **Environment.** omp expands `${VAR}` in `env`, `url` and `headers` from
  your environment when it loads the servers. An unset variable arrives
  literally: with `XERO_CLIENT_ID` unset, `ycc-mcp:xero` receives the text
  `${XERO_CLIENT_ID}`. Export the variables before starting omp.
- **OAuth.** The http servers ship without an `auth` block. Sign in with
  `/mcp reauth ycc-mcp:<server>`. omp stores tokens in `agent.db`, keyed by
  profile and URL, never in a config file.
- **Timeouts** are milliseconds. omp ignores a plugin `timeout` below `1000`
  and uses its 30 s default; `OMP_MCP_TIMEOUT_MS` overrides every server.
- **Disable one server.** Add its name to `disabledServers` in the active
  profile's user `mcp.json` (`~/.omp/agent/mcp.json`, or
  `~/.omp/profiles/<name>/agent/mcp.json` under `--profile`). This beats
  every source; `/mcp disable` does the same. `enabledServers` re-enables a
  server whose source sets `enabled: false`, and `disabledServers` wins over
  it.

  ```json
  { "disabledServers": ["ycc-mcp:xero"] }
  ```

- **Disable the whole package** with `omp plugin disable ycc-mcp@ycc` (add
  `--scope project` for a project install), then `/reload-plugins`.
  `omp plugin enable` restores it. `plugin-overrides.json` does not hide
  marketplace MCP servers, so it is not a kill switch.
- **Override a server.** An entry with the same namespaced name
  (`ycc-mcp:github`) in your user or project `mcp.json` wins, because native
  config outranks plugins. A plain `github` entry does not replace it; disable
  `ycc-mcp:github` and define your own name instead.
- **Precedence.** The first definition of a name wins: the project
  `.omp/mcp.json`, then `.omp/.mcp.json`, then the active profile's user
  `mcp.json`, then Claude configs (project `.claude/`; user-level files only
  with `enabledProviders`), then plugins such as `ycc-mcp`, then imported
  Codex, opencode and Cursor configs. `--profile` reads only that profile's
  user file. `mcp.enableProjectConfig: false` drops the project files.
- **Duplicates.** Servers with different names but the same connection (same
  URL and headers, or same command, args and env) collapse to the
  higher-priority one. `ycc-mcp:linear-personal` shares `ycc-mcp:linear`'s
  URL in `mcp-configs/mcp.json`, so the OMP package alone ships it as
  `https://mcp.linear.app/mcp?ycc-server=linear-personal` (YAN-1291). Linear
  ignores the parameter, so both servers load, and each has its own OAuth
  login (`/mcp reauth ycc-mcp:linear-personal`). The Claude, Codex, Cursor and
  opencode packages keep the plain URL. A native or Claude server with the
  same connection shadows the `ycc-mcp` one; an equivalent Codex, opencode or
  Cursor import is itself shadowed by `ycc-mcp`. Foreign user-level configs
  (`~/.claude.json`, `~/.codex/config.toml`, `~/.cursor/mcp.json`, opencode)
  load only when `enabledProviders` lists their provider.
- **Playwright.** omp drops `ycc-mcp:playwright` while `browser.enabled` is on
  (the default), because its built-in browser replaces it. Set
  `browser.enabled: false` to keep the server.
- **Removal.** `./install.sh remove --target omp --only base` uninstalls the
  recorded installs, including `ycc-mcp@ycc`. To drop only the servers, run
  `omp plugin uninstall --scope <scope> ycc-mcp@ycc`.

omp has no `omp mcp` command; use `/mcp list` in a session to see what
loaded.

## Rules

`ycc-rules@ycc` ships the `ycc/rules` families as 31 flat rules named
`ycc-<family>-<stem>.md` (for example `ycc-common-security`,
`ycc-golang-coding-style`), plus 5 `ycc-<family>-trigger.md` rules (golang,
python, rust, typescript, web). OMP scans plugin `rules/` flat and names each
rule after its file stem.

- **Always on.** `ycc-common-security` and `ycc-common-git-workflow` are
  `alwaysApply` rules; their full bodies go into every main-session prompt.
- **On demand.** Every other non-trigger rule is a rulebook entry: a one-line
  `- <name> (<globs>): <description>` listing, with the body read through
  `rule://<name>` (for example `rule://ycc-python-testing`).
- **Glob-triggered.** Rulebook globs alone select nothing, so each
  `ycc-<family>-trigger` is a TTSR rule gated on the family's globs and the
  `edit`/`write` tools, with `interruptMode: never`. The first edit or write of
  a matching file attaches a reminder listing that family's `rule://` rules
  after the tool result, once per session (`ttsr.repeatMode: once`), and once
  in each subagent that edits a matching file. Files written by shell tools
  (`bash`, `eval`) do not trigger it. `.ts`, `.tsx`, `.js` and `.jsx` files
  match both the typescript and web globs, so both reminders attach. Disable
  one with `ttsr.disabledRules: [ycc-python-trigger]`; `ttsr.enabled: false`
  turns all TTSR rules, these included, off entirely.
- **Override a rule.** Copy it under the same name to `<agentDir>/rules/`
  (user) or `<cwd>/.omp/rules/` (project) and edit the copy. Native rules
  outrank plugin rules, so your copy wins and survives ycc updates. OMP
  reports no shadowing.
- **Disable a rule.** List it in `ttsr.disabledRules` in your `config.yml`:

  ```yaml
  ttsr:
    disabledRules: [ycc-web-design-quality]
  ```

- **Project rules apply at the `.omp` cwd only.** OMP reads
  `<cwd>/.omp/rules` and `<cwd>/.omp/config.yml` from the session's working
  directory, with no walk up to ancestors. Start omp in the directory that
  holds `.omp/`.
- **Disable the package** with `omp plugin disable ycc-rules@ycc`, or skip it
  at install with `--package ycc,ycc-mcp`.

`<agentDir>` is the active profile's agent directory; `omp config path`
prints it (`~/.omp/agent` by default).

## Global Instructions (`--rules`)

```bash
./install.sh install --target omp --rules
```

`--rules` symlinks `ycc/settings/rules/AGENTS.md` to `<agentDir>/AGENTS.md`,
OMP's user context file. A project `AGENTS.md` or `.omp/AGENTS.md` still
loads after it.

A real (non-symlink) `<agentDir>/AGENTS.md` is your content, and the installer
refuses to replace it:

```text
refusing to replace user-authored rules file: <agentDir>/AGENTS.md
```

Move it aside or re-run with `--force`. To keep your own file, import the ycc
instructions from it instead; OMP expands `@<path>` lines inline:

```markdown
@/path/to/ystack/ycc/settings/rules/AGENTS.md
```

## Settings And Model Roles (`--settings`)

```bash
./install.sh install --target omp --settings
```

`--settings` merges these ycc-owned leaves from `ycc/settings/omp/config.yml`
into your user `<agentDir>/config.yml` (or an existing `config.yaml`):

```yaml
modelRoles:
  default: 'anthropic/claude-fable-5-1:medium, openai/gpt-5.6-sol:high'
  slow: 'anthropic/claude-opus-5:high, openai/gpt-5.6-sol:high'
  task: 'anthropic/claude-opus-5:high, openai/gpt-5.6-sol:high'
retry:
  fallbackChains:
    default: ['openai/gpt-5.6-sol']
    slow: ['openai/gpt-5.6-sol']
    task: ['openai/gpt-5.6-sol']
tools:
  approvalMode: write
```

Each `modelRoles` entry is an ordered list: OMP uses the first model that
resolves (has a provider and credentials). That list covers model resolution
only. `retry.fallbackChains.<role>` is the request-failure fallback: when a
request to the active model fails, OMP retries it on the next model in the
chain. A chain entry has no thinking suffix, so a fallback keeps the failing
turn's thinking level. `default` is the main chat session's chain; OMP also
uses it for every chat role without its own chain (`smol`, `plan`, `commit`,
custom roles) and for subagents with a single model pattern. Subagents on
`@slow`/`@task` already retry along the role's comma list; the `slow`/`task`
chains apply when the main session runs on that role. Set
`retry.modelFallback: false` to stop OMP switching models. ycc agents use
`@slow` or `@task`, so these roles set their models. Other `modelRoles`,
other chains, other `retry.*` keys and every other key are never written.
ycc never writes `task.agentModelOverrides`. The chains come from
`targets.omp.fallbackChains` in `ycc/settings/models.json`.

- **Ownership.** Each leaf is tracked by hash in
  `~/.config/ycc/managed-config-state.json`. A run prints one summary line,
  `[ok] applied N managed update(s) and M removal(s) to <dest> (omp-config: settings)`,
  or `[ok] up-to-date: <dest> (omp-config: settings)` when nothing changed. A
  leaf you edited is kept on every update, with a warning such as
  `[!!] kept your local value at /modelRoles/slow (re-run with --force to take the repo value)`;
  `--force` replaces it. `--dry-run` lists each planned leaf as
  `would set /modelRoles/default` (or `would remove …`) and writes nothing.
- **`omp config set modelRoles …`** replaces the whole `modelRoles` record,
  so ycc roles you did not set disappear. The next `--settings` run adds them
  back and keeps the roles you set. To keep your own value, set it; to stop ycc
  managing settings, remove them (below).
- **Comments and formatting.** Rewriting the YAML drops comments and
  formatting, as `omp config set` does. Values keep their YAML 1.2 meaning
  (as OMP reads them), so `off`, `12:30` or `1_000` stay strings. Before any
  rewrite that would drop something (the file is not exactly ycc's own
  output), the installer saves the current file to `config.yml.ycc-backup`
  (mode 600) and warns. Backups are never overwritten: when that backup holds
  different bytes, the next one goes to `config.yml.ycc-backup.1`, `.2`, and
  so on. When `remove` deletes an emptied `config.yml`, it also deletes
  backups that hold only ycc's own output and keeps the rest.
- **Refusals.** A symlinked `config.yml` (for example from a dotfiles repo) is
  never written through; the installer prints the keys to add yourself and
  exits non-zero. An invalid YAML file, one whose root is not a mapping, or
  one that uses YAML aliases (`*name`, including `<<: *name` merge keys) is
  left unchanged, since a rewrite would expand them. `--target omp` needs
  PyYAML for `python3`; without it the installer stops before any write or
  `omp` call and prints the install command.
- **Precedence.** OMP layers defaults < user < project < `--config` overlays
  < runtime flags. A project `.omp/config.yml` beats these user values.
- **User scope only.** `--project` with `--settings` or `--rules` is rejected;
  ycc never writes `.omp/config.yml`, `.omp/rules` or `.omp/AGENTS.md`. Edit
  the project file by hand.
- **Missing credentials.** If no listed model resolves, OMP falls back to an
  available model.

Remove only the unchanged ycc leaves and the owned `AGENTS.md` symlink:

```bash
./install.sh remove --target omp --intent settings,rules
```

## Approvals

OMP's default `tools.approvalMode` is `yolo`. `--settings` sets `write`:
read and write tools are auto-approved, and `exec` tools prompt in the main
session. Limits:

- **Subagents run as `yolo`.** OMP forces task subagents to `yolo`, so `write`
  covers main-session prompts only. A per-tool `deny` still applies.
- **Project config wins.** A project `.omp/config.yml` can set any mode,
  including `yolo`, and OMP applies it without a trust prompt. To pin a mode
  for one session above project config, pass `--approval-mode <mode>`.
- **Headless runs.** With no UI, a prompt fails closed, so `omp -p` with
  `write` cannot run shell commands. Use `--approval-mode yolo` for trusted
  automation.

ycc never writes `yolo`, `bash.patterns` or per-tool `allow`/`deny`.

## Status Line

Unsupported. OMP has no command-backed status line, so ycc's
`statusline-command.sh` has no OMP form; the only ycc OMP extension is the
agent scope guard.
OMP's built-in status line already shows the model, path and git state;
customize it with the `statusLine.*` keys (`omp config list`).

## herdr

herdr session reporting on OMP is herdr's own integration, not a ycc
package. ycc ships no OMP hook or extension for it.

1. Run `herdr integration install omp` once. It writes
   `~/.omp/agent/extensions/herdr-omp-agent-state.ts`.
2. For a named OMP profile, copy that file to
   `~/.omp/profiles/<name>/agent/extensions/`; herdr writes only the default
   profile path.
3. Restart your omp sessions; omp loads new extensions at session start.
4. Verify with `herdr integration status` and
   `herdr pane get "$HERDR_PANE_ID"` from an omp pane.

Install it once: a project copy under `.omp/extensions` loads twice, because
OMP dedupes extensions only by path. Do not add a hand-made reporter or port
`herdr-session-start.sh`: herdr records session identity only from `herdr:`
sources, and a `herdr:omp` reporter with the Cursor script's nanosecond `seq`
stalls herdr's own state reports.

## Project Scope

```bash
cd ~/code/my-project && ycc install --target omp --project
```

`--project` installs with `--scope project` in the git root of the current
directory. It is refused at `$HOME`; `cd` into a project or use the default
user scope (`--global`).

A project install shadows your user install inside that project. To return to
the user copy there, disable the project install:

```bash
omp plugin disable --scope project ycc@ycc
```

ycc never enables or disables plugins: a disabled install stays disabled
across updates and reinstalls.

A user-scope upgrade can make omp garbage-collect the cache a project install
still points at. The installer detects this and prints the repair command,
using the absolute path of the checkout's `install.sh`:

```bash
cd <project-root> && <checkout>/install.sh install --target omp --project
```

`--project` runs the `base` and `dedupe` steps. `dedupe` still writes the
**user** `<agentDir>/config.yml`, because the duplicates it hides come from
user-level directories.

## Coexistence With Other Runtimes

With ycc also installed for Claude, Codex, Cursor, opencode or the `agents`
target, OMP loads each ycc component once, from the OMP packages:

- **Skills.** OMP reads `~/.agents/skills` by default, where the `agents`
  target and consolidated Codex, Cursor and opencode skills live. A same-named
  skill whose text differs from the OMP package becomes an `agents/<name>`
  alias; the `dedupe` step hides those aliases (below). Identical copies are
  dropped by OMP itself.
- **Agents, rules, commands, global instructions.** One copy each. OMP never
  reads `~/.claude/agents` or the other tools' agent directories, and one
  user context file wins (`<agentDir>/AGENTS.md`, else Claude's).
- **Hooks.** ycc ships no OMP hooks, and OMP never runs the Claude `*.sh`
  hooks.
- **MCP.** Each server loads once: OMP collapses equivalent connections onto
  the higher-priority source (see [MCP Servers](#mcp-servers)).
- **Claude plugin.** A Claude marketplace install of `ycc@ycc` never
  duplicates: OMP's own plugin registry replaces a Claude registry entry with
  the same plugin id. Once the OMP `ycc@ycc` is uninstalled and
  `enabledProviders` lists `claude`, the Claude plugin serves instead.

### Precedence

When two sources define the same skill, command, rule or MCP server, the
first in this list wins:

1. Project native `.omp/*`.
2. User native `<agentDir>/*` (`disabledServers` beats every MCP source).
3. Opt-in Claude user skills and MCP servers (priority 80, see
   [`enabledProviders`](#enabledproviders)): they outrank the OMP plugin,
   which then shows a skill as `ycc/<name>` (W4).
4. The OMP plugin: a project install beats the user install.
5. `~/.agents/skills` (hidden by `dedupe` when ycc installed them).
6. Opt-in Codex, opencode and Cursor imports.
7. Built-ins.

Identical skills collapse to one. Equivalent MCP connections collapse onto
the higher-priority one. `omp skill list` prints OMP's own `name collision`
lines on stderr, so it is the check: after `dedupe` its stderr is empty.

### The `dedupe` Step

`./install.sh install --target omp` (and `--package ycc`) runs `dedupe`
after `base`. It adds one `skills.ignoredSkills` entry per duplicate alias
to your user `<agentDir>/config.yml`:

```yaml
skills:
  ignoredSkills: [agents/backport, agents/blueprint, …]
```

- **What it hides.** `agents/<name>`, `codex/<name>` and `opencode/<name>`
  entries, only for ycc skills that ycc itself installed in
  `~/.agents/skills`, `~/.codex/skills` or `~/.config/opencode/skills` (as
  recorded in `~/.config/ycc/installed-units.json`). Skills you wrote are
  never hidden. Claude copies are not hidden (see W4).
- **Other tools are untouched.** The entries match only the OMP alias, so
  Codex, Cursor and opencode keep reading their copies. When the OMP package
  is disabled or removed, the alias no longer exists and OMP loads the
  `~/.agents` copy under its bare name again.
- **Ownership.** Entries are tracked by hash in
  `~/.config/ycc/managed-config-state.json`, merged as a list union: items
  you added stay, and only items ycc added are ever taken back. A re-run
  takes back the entries whose ycc copies are gone (for example after
  `remove --target agents`), so a skill you later write under that name is
  not hidden. The same refusals as `--settings` apply (symlinked or invalid
  `config.yml`); a removal with no ycc entries never reads the file.
- **User config only.** ycc never writes the project `.omp/config.yml`. A
  project `skills.ignoredSkills` list replaces the user list in that project,
  so the aliases come back there; add `agents/*` to the project list or drop
  it.
- **Per profile.** Entries go to the active profile's `config.yml`
  (`omp config path`); run the installer once per profile.
- **Skip it** with `./install.sh install --target omp --only base` (W2 then
  reports the duplicates). `--dry-run` shows the planned
  `would set /skills/ignoredSkills` merge and the
  `[dry-run] OMP: would hide N ycc duplicate skills …` line, and writes
  nothing (it reads `enabledProviders` and `skills.ignoredSkills` as `[]`,
  because `omp config get` is not run).
- **Undo it.** `./install.sh remove --target omp --only dedupe` takes back
  only the entries. `./install.sh remove --target omp --only base` (or
  `--intent base` / `plugins`) takes them back with the last recorded ycc
  install of the profile, before the packages are uninstalled; removing a
  project install while the user install remains keeps them
  (`omp: kept the skills.ignoredSkills entries …`).

New sessions pick the change up; in a running session, run `/reload-plugins`
or restart.

### Warnings

Every install prints at most one line per finding, each naming one command:

| Id  | Meaning                                                                                           | Line                                                                                                                                                                                                                                   |
| --- | ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| W1  | `dedupe` hid ycc's own duplicates                                                                 | `[ok] OMP: hid N ycc duplicate skills (agents/…, codex/…) via skills.ignoredSkills in <config>; ./install.sh remove --target omp --only dedupe restores them`                                                                          |
| W2  | Duplicates exist and `dedupe` was skipped (`--only base`, `migrate`)                              | `[!!] OMP also loads N ycc skills from ~/.agents/skills as agents/<name>; run ./install.sh install --target omp --only dedupe to hide them in OMP`                                                                                     |
| W3  | A directory ycc did not install has a ycc skill name                                              | `[!!] ~/.agents/skills/<a>[, …] share ycc skill names but were not installed by ycc; OMP lists them as agents/<name> (left as is)`                                                                                                     |
| W4  | `enabledProviders` lists `claude`, `*` or `all`, and ycc Claude skills are in `~/.claude/skills`  | `[!!] enabledProviders includes claude: N ycc skills in ~/.claude/skills outrank the OMP package (it shows as ycc/<name>); remove them with ./install.sh remove --target claude --intent skills, or drop claude from enabledProviders` |
| W5  | `install --target agents` ran while ycc is installed on OMP and the new copies are not hidden yet | `[!!] OMP also loads these skills; run ./install.sh install --target omp --only dedupe to hide the ~/.agents copies in OMP`                                                                                                            |

W1 lists the namespaces it actually hid, for example
`[ok] OMP: hid 41 ycc duplicate skills (agents/…) via skills.ignoredSkills in /home/u/.omp/agent/config.yml; ./install.sh remove --target omp --only dedupe restores them`.
W3 is usually a skill from before ycc recorded its installs: run
`./install.sh install --target agents` once, then
`./install.sh install --target omp`.

### `enabledProviders`

By default (`enabledProviders: []`) OMP reads no foreign user directories
except `~/.agents`. Widening it changes what wins:

- **Claude skills outrank ycc.** With `claude`, `*` or `all`, standalone
  skills in `~/.claude/skills` load at priority 80, above the OMP package, so
  they take the bare names and the package copy shows as `ycc/<name>` (W4).
  Remove the Claude copies with
  `./install.sh remove --target claude --intent skills`, or drop `claude`
  from `enabledProviders`. ycc writes nothing for this case.
- **Codex and opencode aliases.** `codex/<name>` and `opencode/<name>`
  aliases appear; `dedupe` hides the ones ycc installed. opencode commands
  also load under their bare names next to `/ycc:<skill>`.
- **Claude MCP shadows `ycc-mcp:*`.** Servers in `~/.claude.json` with the
  same connections as the ycc servers outrank the plugin, so they serve
  instead of `ycc-mcp:*` (still one copy each). To get the `ycc-mcp:*`
  servers back, list those Claude server names in `disabledServers` in the
  user `mcp.json`, for example:

  ```json
  { "disabledServers": ["github", "linear", "linear-personal"] }
  ```

### Profiles And `PI_CODING_AGENT_DIR`

`--profile` and `OMP_PROFILE` move plugins, `config.yml`, `mcp.json` and
`agent.db` together, so each profile needs its own install and `dedupe` run.
`~/.agents`, `~/.claude`, `~/.codex` and project directories are shared by
every profile. `PI_CODING_AGENT_DIR` moves only the agent directory: the
`dedupe` entries follow it (they go where `omp config path` points), but
plugins stay in the default plugins directory.

### Untrusted Projects

OMP has no trust gate. A project's hooks, extensions, `.mcp.json` servers,
plugin registry and `extensions:` setting run at session start, and a
project `.omp/config.yml` overrides kill switches set in your user config.
To open a repository you do not trust with ycc still loaded, pass a
`--config` overlay, which a project config cannot override:

```bash
printf 'mcp:\n  enableProjectConfig: false\n' > ~/.omp/agent/untrusted.yml
omp --no-extensions --config ~/.omp/agent/untrusted.yml
```

No project hook, extension, MCP server or project plugin MCP server runs.
ycc skills, commands, agents, rules and `ycc-mcp:*` still load. Limits:

- A project plugin's skills still load as text into the prompt.
- `--no-extensions` also drops your own extensions (such as herdr's); re-allow
  a file with `--trusted-extension <absolute path>`.

## Preview With `--dry-run`

```bash
./install.sh install --target omp --dry-run
./install.sh install --target omp --settings --rules --dry-run
./install.sh remove --target omp --only base --dry-run
```

`--dry-run` builds nothing and changes nothing. It prints each mutation as
`[dry-run] would run: omp …` and runs omp's own `--dry-run` check where omp
has one. `dedupe`, `--settings` and `--rules` print the planned merge and
link against the default agent dir (`$PI_CODING_AGENT_DIR`, else
`~/.omp/agent`), because `omp config path` itself writes files. It works with
`install`, `sync` and `remove`, and only when every `--target` is `omp`.

## Force Reinstall

```bash
./install.sh install --target omp --force
./install.sh install --target omp --project --force
```

`--force` reinstalls the ycc-owned installs (`omp plugin install --force`)
and replaces an export directory that ycc did not record or that was edited.
It never takes over an install ycc did not create.

## Remove

```bash
./install.sh remove --target omp --only base             # user scope
./install.sh remove --target omp --only base --project   # this project
./install.sh remove --target omp --only dedupe           # dedupe entries only
```

`remove` uninstalls only the installs ycc recorded for that scope. When no
recorded ycc install is left in the profile, it first takes back the `dedupe`
entries ycc added to the user `config.yml`; `--only dedupe` takes back only
the entries. With `--project`, it also deletes the empty `.omp/plugins/`
files omp leaves behind (`installed_plugins.json`, `omp-plugins.lock.json`
and `node_modules/`, only while they hold nothing), then `.omp/plugins/` and
`.omp/` when they are empty, but only the ones a ycc project install there
created: each install records the ones missing when it starts, so a later
install that recreates them claims them too. Anything that already existed
when the install that would first claim it started (or that a pre-upgrade ycc
install did not record) is kept.
The `ycc` marketplace and the export are removed only when nothing else still
uses them; otherwise the installer
prints `kept marketplace ycc: <reason>`. When the
`ycc` marketplace now points somewhere ycc did not register (a fork with the
same name), recorded installs are dropped from the ycc record but never
uninstalled (`kept ycc@ycc (<scope>): marketplace ycc now points at …`).

## Migrate From Older Installs

```bash
./install.sh migrate --target omp           # dry-run
./install.sh migrate --target omp --apply
```

Migration retires two older setups without leaving duplicates:

- `omp plugin link` installs that point at this checkout's `packages/omp/`
  tree (foreign links are kept and reported);
- a `ycc` marketplace registered at the checkout root, which OMP falls back
  to the Claude catalog for. Its installs are uninstalled, the marketplace is
  removed, and the default native packages (`ycc`, `ycc-mcp` and `ycc-rules`) are
  installed in the same scopes.

Before anything is uninstalled, migration builds and validates the export.
It refuses (and changes nothing) while a legacy install is disabled, because
the native reinstall would come back enabled and ycc never toggles plugins
for you, or while a legacy install has no native OMP package
(`ycc-hooks`, `ycc-all` are excluded). The message names the exact `omp`
commands to run first. Project scope means the project root `install
--project` uses (the git toplevel, else the current directory).

If `--apply` stops partway (say, an omp install fails), the scopes still owed
a native install are recorded. Re-run `./install.sh migrate --target omp
--apply` to finish them, or run the printed
`<checkout>/install.sh install --target omp [--project]` commands.
A `ycc` marketplace registered at another source (a fork with the same name)
blocks the owed native install; migrate refuses before changing anything until
you remove it.

Migration does not run `dedupe`, so ycc skills OMP also loads from
`~/.agents/skills` are reported with W2. Run
`./install.sh install --target omp --only dedupe` to hide them (see
[The `dedupe` Step](#the-dedupe-step)); never delete `~/.agents/skills`, since
Codex, Cursor and opencode may read their skills from there.

`migrate --target all` does not include OMP; run `migrate --target omp`
separately. Combined with other targets (`--target claude,omp`), every omp
refusal happens in the shared preflight, before any target changes.

## Migrate From Another ycc Target

OMP gets its own packages; you do not convert a Claude, Codex, Cursor,
opencode or `agents` install into an OMP one. Install OMP beside them:

```bash
./install.sh install --target omp            # + --settings --rules if wanted
omp skill list >/dev/null                    # stderr empty: no duplicates
```

- **Keep the other runtimes.** The `dedupe` step hides the copies OMP would
  load from `~/.agents/skills`, `~/.codex/skills` and
  `~/.config/opencode/skills`; the other tools keep reading them. See
  [Coexistence With Other Runtimes](#coexistence-with-other-runtimes).
- **Claude skills.** OMP reads `~/.claude/skills` only when
  `enabledProviders` lists `claude`; then they outrank the package (W4).
  Either drop `claude` from `enabledProviders` or run
  `./install.sh remove --target claude --intent skills`.
- **Leave another runtime.** Remove that target first (for example
  `./install.sh remove --target agents --only skills`), then re-run
  `./install.sh install --target omp` so `dedupe` takes back the entries whose
  copies are gone.
- **Global instructions and models do not carry over.** OMP reads
  `<agentDir>/AGENTS.md` and `<agentDir>/config.yml`, not the other tools'
  files; use `--rules` and `--settings`.
- **MCP logins do not carry over.** OMP keeps OAuth tokens in its own
  `agent.db`; sign in again with `/mcp reauth ycc-mcp:<server>`.

## Uninstall Everything

```bash
./install.sh remove --target omp --only base --project   # in each project that has one
./install.sh remove --target omp --only base             # user scope (+ dedupe entries)
./install.sh remove --target omp --intent settings,rules # --settings / --rules leaves
```

Run it once per OMP profile you installed into. Each command removes only what
ycc recorded; packages, settings or `AGENTS.md` files you created stay. Then run
`/reload-plugins` or restart running omp sessions; the scope guard extension
unloads only on restart. `omp plugin list` should no longer show any
`@ycc` package, and `~/.config/ycc/omp-native-install.json` holds no install
for the profile.

## Security And Trust

- **No trust prompt.** OMP loads plugin extensions and hooks in-process and
  starts plugin MCP servers, all with your user privileges. Install only from
  a checkout you trust; `install.sh` exports the packages from that checkout.
- **What ycc runs.** `ycc@ycc` ships one extension, the agent scope guard,
  which only restricts ycc subagents (see [Agent Scope](#agent-scope)). ycc
  ships no hooks. `ycc-mcp@ycc` connects to the http servers and starts the
  stdio servers listed in its `.mcp.json`; some stdio servers run `npx`, which
  downloads their npm package on first start. Disable any you do not want
  (see [MCP Servers](#mcp-servers)).
- **Secrets.** Generated files hold `${VAR}` placeholders only. Values come
  from your environment; OAuth tokens stay in omp's `agent.db`.
- **Scope guard limits.** The guard is a guard rail for ycc agents, not a
  sandbox. It does not cover the main session or non-ycc agents, and
  `--no-extensions` or a package loaded through `omp --plugin-dir` turns it
  off. Task subagents run as `yolo` whatever `tools.approvalMode` says.
- **Untrusted repositories.** A project's `.omp/` can add extensions, hooks
  and MCP servers and override your user settings. Open one with the overlay
  in [Untrusted Projects](#untrusted-projects).
- **Settings writes.** `--settings` and `--rules` touch only the user
  `<agentDir>`, never project files; a symlinked `config.yml` is never
  written through.

## Troubleshooting

| Symptom                                                                                       | Fix                                                                                                                                                                             |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `omp >= 18.12.2 is required for --target omp`                                                 | Install or upgrade omp; the next line names the reason (for example `omp not found on PATH`).                                                                                   |
| `--target omp needs PyYAML for python3; …`                                                    | `python3 -m pip install --user pyyaml`.                                                                                                                                         |
| `--project at $HOME: omp project scope needs a project directory …`                           | `cd` into a project, or drop `--project`.                                                                                                                                       |
| `omp needs a listed OMP package` (with `--mode repo`)                                         | The checkout's `ycc/settings/packages.json` lists no OMP package (an old checkout). Pull, or use the default `--mode local`.                                                    |
| `runtime package <pkg> is linked (omp plugin link); run ./install.sh migrate --target omp`    | Run `./install.sh migrate --target omp --apply`.                                                                                                                                |
| `marketplace ycc has a different source (…); retained …`                                      | Another `ycc` marketplace is registered. Inspect it with `omp plugin marketplace list`; migrate or `omp plugin marketplace remove ycc` if it is not yours to keep.              |
| `<export> exists but is not the recorded ycc export; rerun with --force to replace it`        | The export directory was edited or not made by ycc. Re-run with `--force`.                                                                                                      |
| `[!!] <pkg>@ycc … the export changed but its version did not …`                               | You regenerated packages without a version bump; re-run with `--force`.                                                                                                         |
| `[!!] <pkg>@ycc project install at <root> lost its cache (omp GC); repair: …`                 | Run the printed `cd <root> && <checkout>/install.sh install --target omp --project`.                                                                                            |
| `[!!] <pkg>@ycc is already installed (<scope>) and not recorded as ycc-owned; left untouched` | You installed it yourself; ycc will not take it over. Uninstall it with `omp plugin uninstall`, then re-run.                                                                    |
| `/ycc:<skill>` or agents missing in a running session                                         | `/reload-plugins`, or restart; restart after a `ycc` install or update so the scope guard loads.                                                                                |
| A skill shows as `agents/<name>` or `ycc/<name>`                                              | See [Warnings](#warnings): W2 means run `--only dedupe`; W4 means Claude skills outrank the package.                                                                            |
| `ycc-mcp:<server>` gets `${VAR}` literally or fails to start                                  | Export the variable before starting omp; use `/mcp list` to see what loaded.                                                                                                    |
| `ycc-mcp:playwright` is missing                                                               | omp drops it while `browser.enabled` is on; set `browser.enabled: false`.                                                                                                       |
| A ycc agent's command fails with `ycc scope guard`                                            | Working as intended: the agent may run only its declared prefixes. Run the command from the main session.                                                                       |
| `-p` refuses shell commands after `--settings`                                                | `approvalMode: write` prompts for exec tools and fails closed without a UI; pass `--approval-mode yolo` for trusted automation.                                                 |
| `…/omp-native-install.json: expected a version 1 JSON object` (or `malformed …`)              | `~/.config/ycc/omp-native-install.json` is damaged. Move it aside; ycc then treats existing installs as foreign and leaves them, so uninstall them with `omp plugin uninstall`. |

Installer errors print as `[err] native OMP install stopped: <message>` (or
`[err] native OMP migration stopped: …`); every refusal happens before any
change. Add `--dry-run` to see each `omp` call before it runs.

## Known Limitations

- **Catalog installs are unmanaged.** Packages installed with `omp plugin`
  straight from the catalog have no `install.sh` ownership record, dedupe,
  `--settings` or `--rules`; run those `install.sh` steps separately.
- **Platforms.** Linux x86_64 has bubblewrap-sandboxed acceptance evidence.
  macOS arm64 passed the same harnesses in CI under `env -i` (no bubblewrap).
  Linux arm64, musl, and WSL 2 are not yet run. Native Windows is unsupported
  (see [Platform Support](#platform-support)).
- **No hooks, no status line.** OMP never runs ycc's shell hooks;
  `WorktreeCreate` has no OMP event; there is no command-backed status line.
  herdr reporting is herdr's own integration.
- **No `--dangerously-skip-permissions` mapping.** Subagents always run as
  `yolo`; project config can override the approval mode.
- **Headless questions.** `ask` exists only in the TUI and `--mode rpc-ui`;
  `-p`, `--mode json`, `--mode rpc` and subagents take each skill's declared
  default. `--team` is unsupported and fails closed. Per-skill status:
  [`omp-workflow-semantics.md`](../internal/omp-workflow-semantics.md).
- **Rule triggers** fire only on `edit`/`write`, not on files written through
  `bash` or `eval`.
- **User-scope settings only.** `--settings` and `--rules` never write
  project `.omp/` files.
- **Upgrades are version-keyed.** Same-version content changes need
  `--force`.
- **Verification scope.** Live acceptance used a scripted model: it proves
  loading and tool plumbing, not workflow reasoning on real models. Evidence:
  [`omp-acceptance.md`](../internal/omp-acceptance.md).

## Profiles And XDG

The installer resolves every path through omp, so OMP profiles
(`OMP_PROFILE` or `omp --profile`) and the `$XDG_DATA_HOME/omp` data root
work unchanged. Ownership state is keyed per profile: run the installer once
per profile you want `ycc` in.

## Source Modes And `--target all`

`--mode local` (the default) exports the packages from your checkout.
`--mode repo` registers `https://github.com/yandy-r/ystack.git` as the `ycc`
marketplace instead and installs the packages listed there (the `main`
branch). Both refuse a `ycc` marketplace with the other source. Remove an
`install.sh` one with `./install.sh remove --target omp --only base`; remove a
catalog install you made with `omp plugin` as described in
[Install From The Catalog](#install-from-the-catalog).

`--target all` includes OMP when `omp >= 18.12.2` is on `PATH`. Otherwise it
prints `--target all: skipping omp (...)` and runs the other targets.

## OMP Notes

- Skills run as `/skill:<name>` and commands as `/ycc:<skill>`; agents are
  OMP task agents with `@role` models.
- OMP never runs shell hooks; `WorktreeCreate` has no OMP event; herdr
  reporting comes from herdr's integration (see [herdr](#herdr)). Rules ship
  in `ycc-rules`; settings, model roles and global instructions are opt-in
  installer steps (`--settings`, `--rules`).
- Details: [ADR 0002](../internal/adr/0002-omp-runtime-contract.md) and the
  [capability matrix](../../ycc/skills/_shared/references/target-capability-matrix.md).
