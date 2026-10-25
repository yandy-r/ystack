# Install Guides

This directory contains the runtime-specific install guides for `ycc`. The root
[`README.md`](../../README.md) stays short and links here instead of duplicating
every target's installer behavior.

## Runtime Guides

| Runtime  | Guide                        | Best for                                                                   |
| -------- | ---------------------------- | -------------------------------------------------------------------------- |
| Claude   | [`claude.md`](claude.md)     | Claude Code plugin installs, Claude rules/config, Claude Desktop MCP setup |
| Cursor   | [`cursor.md`](cursor.md)     | Cursor-native skills, agents, rules, and MCP sync                          |
| Codex    | [`codex.md`](codex.md)       | Codex plugin installs, custom agents, Codex Desktop setup                  |
| opencode | [`opencode.md`](opencode.md) | opencode-native skills, agents, commands, config, and rules                |
| agents   | [`agents.md`](agents.md)     | Cross-tool skills in `~/.agents/skills` (Zed and others)                   |
| OMP      | [`omp.md`](omp.md)           | OMP (oh-my-pi) native packages via `omp plugin` and the repository catalog |

Since v6.0.0 `ycc` is also published as native packages in the Claude, Codex,
and Cursor marketplaces. The v6 guides cover the package IDs, the marketplace
commands, and what stays on `install.sh`:

| Runtime  | Native package guide               | Native install                                                                                                            |
| -------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Claude   | [`v6/claude.md`](v6/claude.md)     | `claude plugin marketplace add yandy-r/ystack`, then `claude plugin install ycc-all@ycc` (or `ycc`/`ycc-mcp`/`ycc-hooks`) |
| Codex    | [`v6/codex.md`](v6/codex.md)       | `codex plugin marketplace add https://github.com/yandy-r/ystack.git`, then `codex plugin add ycc@ycc` and `ycc-mcp@ycc`   |
| Cursor   | [`v6/cursor.md`](v6/cursor.md)     | `agent plugin marketplace add https://github.com/yandy-r/ystack`, then `/plugins`                                         |
| opencode | [`v6/opencode.md`](v6/opencode.md) | Experimental, opt-in npm package; the file copy stays primary                                                             |
| agents   | [`v6/agents.md`](v6/agents.md)     | None — file copy only                                                                                                     |

Overview of all runtimes: [`v6/README.md`](v6/README.md). To move an existing
`install.sh` setup onto the native packages, see
[Migrating To Native Packages](#migrating-to-native-packages).

## Installer Model

Use `install.sh` from the repository root (or `ycc` once it is on `PATH`). Every
invocation starts with a command — `install`, `sync`, `remove`, `migrate`, `cli`, or
`completion`; a bare `./install.sh --target ...` is rejected. `install` is the
first-time setup (base step plus opt-in `--settings`/`--rules`/`--mcp`/`--hooks`
or `--only`); `sync` is the recommended entry point after that:

```bash
./install.sh sync --target <claude|cursor|codex|opencode|agents|omp|all> --intent <intents>
```

You say **what** you want synced; each target maps the intent onto the steps it
actually supports, and reports (rather than silently substitutes) anything it
cannot do.

```bash
./install.sh sync --target claude --intent hooks,settings,mcp,plugins
./install.sh sync --target all --intent settings,rules
./install.sh sync --target codex --intent settings,mcp --global
./install.sh remove --target all --only mcp --global
```

`mcp` and Claude `hooks` default to project scope; see
[Project Vs Global Scope](#project-vs-global-scope). To undo any of it, see
[Removing Installed Config](#removing-installed-config).

### Migrating To Native Packages

`migrate` moves an existing file-copy/managed-config install toward the
native packages for one runtime. It is **dry-run by default**: it reports what
it would change and writes no config, state, build output, or CLI state.
Pass `--apply` to make the reported changes:

```bash
./install.sh migrate --target claude           # dry-run
./install.sh migrate --target claude --apply
./install.sh migrate --target codex            # dry-run
./install.sh migrate --target codex --apply
./install.sh migrate --target cursor           # dry-run
./install.sh migrate --target cursor --apply
./install.sh migrate --target omp              # dry-run
./install.sh migrate --target omp --apply
```

- `--target` accepts `claude`, `codex`, `cursor`, or `omp`; `--target all`
  resolves to exactly `claude`, `codex` and `cursor` and prints a reminder to
  run `migrate --target omp` separately. `opencode` and `agents` have no
  migration and are rejected when named explicitly — their file-copy installs
  stay as they are.
- Migration preserves user edits and data. It removes only entries it can
  prove are installer-owned, and it reports anything uncertain as a conflict
  instead of deleting it. Proof is managed-config ownership, a byte-identical
  copy, a symlink that points at this checkout, or a legacy Codex cache
  snapshot whose git tree matches a committed `.codex-plugin/ycc`. It is safe
  to run repeatedly. `--force` is rejected for `migrate` and never widens
  what migration deletes. Symlinked configuration files are retained with a
  notice rather than replaced, preserving dotfiles links.
- **Claude:** settings hooks are pruned only when `ycc-hooks@ycc` is
  explicitly enabled, and managed MCP entries only when `ycc-mcp@ycc` is
  explicitly enabled; enabling `ycc-all@ycc` alone proves neither. User hooks
  in the same event groups are preserved, link cleanup removes only owned
  symlinks, and only global config files are touched.
- **Codex:** the default source is this checkout's `ycc` catalog, which lists
  `ycc@ycc` and `ycc-mcp@ycc`. If the selected source is not an eligible native
  `ycc` catalog, dry-run prints a `Codex native gate` reason and keeps the
  legacy `ycc@local-ycc-plugins` install, and apply fails before any cleanup or
  CLI call. `--marketplace-source <dir>` (Codex only) points migration at a
  staged directory carrying an eligible native `ycc` catalog and payloads,
  validated by the same checks — it is not a bypass.
  On apply, the marketplace is registered and each package is installed and
  verified installed and enabled **before** any legacy entry is retired,
  including exact installer matches in the standalone `~/.codex/skills/`
  slice. Edited skills stay, and shared helpers stay while any skills remain.
  A snapshot under `~/.codex/plugins/cache/local-ycc-plugins/ycc` is also
  retired when its git tree equals a committed `.codex-plugin/ycc` tree in
  this checkout's history, so an untouched copy of an older release can be
  removed. An edited snapshot stays. A shallow clone that does not contain
  that commit keeps the snapshot and prints `git fetch --unshallow`. If git
  history cannot be read, the snapshot stays. Everything under
  `~/.codex/agents/` is preserved.
- **Cursor:** recorded command wrappers and the owned `sessionStart` hook are
  retired before file-copy skills. An unproven command or hook stops the
  Cursor migration before skills, agents, or rules change. Skill, agent, rule,
  and shared-helper copies are removed only when they match the canonical
  source byte-for-byte, or when they are owned symlinks pointing exactly at
  it. Edited or foreign entries stay, and shared helpers stay while any skills
  remain. Migration prints the interactive `/add-plugin` step. It does not
  install the Cursor plugin.
- **OMP:** retires `omp plugin link` installs of this checkout's packages and a
  `ycc` marketplace registered at the checkout root (Claude-catalog fallback),
  then installs the default native packages (`ycc` and `ycc-mcp`) in the same
  scopes. Foreign links and marketplaces are kept and reported. Needs
  `omp >= 18.12.2`; see [`omp.md`](omp.md#migrate-from-older-installs).

Migration does not install Claude or Cursor packages (enable `ycc-hooks@ycc` /
`ycc-mcp@ycc` first on Claude; Cursor prints the interactive `/add-plugin`
step) and does not establish runtime installation, session, or hook-dispatch
verification. Per-package details are in the [v6 guides](v6/README.md).

### `ycc` Command On PATH

Project-scoped runs happen from inside the other project, where `./install.sh`
does not exist. Link the installer onto `PATH` once:

```bash
./install.sh cli                 # symlink install.sh as `ycc`
ycc completion --install         # shell completion for $SHELL
cd ~/code/other-project && ycc sync --target opencode --intent mcp
```

- `cli` links into the first of `$XDG_BIN_HOME`, `~/.local/bin`, `~/bin` already
  on `PATH` (else `~/.local/bin`, with a warning); `--dir <dir>` overrides.
- `ycc` is the installer itself, reached through a symlink, so it always runs
  this checkout's HEAD. `--project` targets the git root of your current directory.
- `completion --shell bash|zsh|fish` prints the script (default: `$SHELL`);
  `--install` symlinks it into the shell's per-user completion directory:

| Shell | Destination                                                                                     |
| ----- | ----------------------------------------------------------------------------------------------- |
| bash  | `${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-~/.local/share}/bash-completion}/completions/ycc` |
| zsh   | `${XDG_DATA_HOME:-~/.local/share}/zsh/site-functions/_ycc` (must be in `fpath`)                 |
| fish  | `${XDG_CONFIG_HOME:-~/.config}/fish/completions/ycc.fish`                                       |

Both `cli` and `completion --install` refuse to replace an existing file or a
symlink pointing elsewhere unless you pass `--force`. Without bash-completion or
the zsh `fpath` entry, source the script instead: `eval "$(ycc completion --shell bash)"`
or `source <(ycc completion --shell zsh)`.

| Intent     | Meaning                                                                                                                                                                                                          |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `base`     | Install or register the target's native bundle surface.                                                                                                                                                          |
| `skills`   | Standalone skills, one entry each, in the tool's own skills dir (no plugin).                                                                                                                                     |
| `agents`   | Standalone agents, one entry each, in the tool's own agents dir (no plugin).                                                                                                                                     |
| `commands` | Slash commands. Claude aliases this to standalone skills. Cursor installs wrappers in `~/.cursor/commands/`. opencode installs generated commands.                                                               |
| `settings` | Merge repo-managed config keys (models, effort levels, statusline, ...).                                                                                                                                         |
| `rules`    | Symlink the global rules file each runtime reads (Cursor: manual, see its page).                                                                                                                                 |
| `mcp`      | Merge MCP server definitions into the target's MCP surface.                                                                                                                                                      |
| `hooks`    | Install hook support. Claude defaults to the native `ycc-hooks` plugin at project scope; `--global` merges hook configuration and links the scripts directory. Cursor installs the optional `sessionStart` hook. |
| `plugins`  | Merge plugin enablement and marketplace entries. Add `base` for CLI-side registration too.                                                                                                                       |
| `mods`     | Install the Claude Code mods under `ycc/mods` (claude only for now).                                                                                                                                             |

Per-target mapping (intents a target cannot execute are skipped with a notice):

| Intent     | claude                                         | cursor     | codex      | opencode   | omp    |
| ---------- | ---------------------------------------------- | ---------- | ---------- | ---------- | ------ |
| `base`     | `base`                                         | `base`     | `base`     | `base`     | `base` |
| `skills`   | `skills`                                       | `skills`   | `skills`   | `skills`   | no-op  |
| `agents`   | `agents`                                       | `agents`   | `agents`   | `agents`   | no-op  |
| `commands` | `skills` (alias)                               | `commands` | no-op      | `commands` | no-op  |
| `settings` | `settings`                                     | `settings` | `settings` | `settings` | no-op  |
| `rules`    | `rules`                                        | `rules`    | `rules`    | `rules`    | no-op  |
| `mcp`      | `mcp`                                          | `mcp`      | `mcp`      | `mcp`      | no-op  |
| `hooks`    | `hooks` (project); `settings`+`hooks` (global) | `hooks`    | no-op      | no-op      | no-op  |
| `plugins`  | `settings`                                     | no-op      | `settings` | `settings` | `base` |
| `mods`     | `mods`                                         | no-op      | no-op      | no-op      | no-op  |

`sync` is exclusive: it never implicitly runs `base`.

Global instructions are linked as `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, or
`~/.config/opencode/AGENTS.md`, not both filenames. Cursor User Rules are
settings-configured; `rules` prints manual guidance and provisions no files
(file-based user-global provisioning is unsupported/unverified). See each target
page for official loading references. Install/sync preserves legacy rule links;
remove still unlinks only links to this checkout.

### Standalone Slices

`skills`, `agents` and `commands` install entries one by one into each tool's
own user directories, with no plugin or marketplace registration. On claude the
`commands` intent is an alias for `skills` — public skills are native slash
invocations there, so there is nothing separate to copy:

| Target   | Destinations                                                                                   |
| -------- | ---------------------------------------------------------------------------------------------- |
| claude   | `~/.claude/skills/<name>`, `~/.claude/agents/<name>.md` (skills are the slash commands)        |
| cursor   | `~/.cursor/skills/<name>`, `~/.cursor/agents/<name>.md`, `~/.cursor/commands/<name>.md`        |
| codex    | `~/.codex/skills/<name>` (helpers in `~/.codex/skills/_shared`), `~/.codex/agents/<name>.toml` |
| opencode | `~/.config/opencode/{skills,agents,commands}/<name>` (+ `shared/`)                             |

- Entries are copied with plugin-root paths (`${CLAUDE_PLUGIN_ROOT}`,
  `~/.codex/plugins/ycc`) re-pointed at the new location and `ycc:` prefixes
  dropped, so each works without the plugin.
- What ycc installed is recorded in `~/.config/ycc/installed-units.json`. An
  existing entry is replaced only when ycc installed it or it is identical;
  your own skills or agents with the same name need `--force`. Entries the
  bundle no longer ships are pruned on the next sync.
- On claude, older ycc installs wrote wrappers to `~/.claude/commands/`. A
  successful skills install (via `--intent skills` or the `commands` alias)
  retires only wrappers recorded in `~/.config/ycc/installed-units.json`;
  foreign or unrecorded entries stay, even with `--force`.
- With the plugin (`base`) also installed, skills appear twice (`ycc:<name>`
  and `<name>`); the installer warns.
- `--only` / `--intent` skip a slice a target has no home for (e.g.
  `commands` on codex), so `--target all --only agents` just works. With
  `--target all`, `--only` also skips any other step a target lacks (e.g.
  `--only mcp` on the agents target); a step no target has is an error.

### Selecting Skills, Agents And Commands

By default the `skills`, `agents` and `commands` steps install every entry a
target ships. `--skills <names>`, `--agents <names>` and `--commands <names>`
(comma-separated) narrow `install`, `sync`, and `remove` to just those entries:

```bash
ycc list skills --target cursor                 # what --skills accepts there
ycc list agents --target codex                  # agent names are file stems
ycc sync --target claude,opencode --intent skills --skills code-review,git-workflow
ycc sync --target agents --intent skills --skills prp-plan
ycc sync --target claude,codex --intent agents --agents implementor,code-reviewer
ycc remove --target codex --intent skills --skills visual-recap
ycc list commands --target opencode             # what --commands accepts there
ycc sync --target opencode --intent skills,commands --skills clean --commands clean
ycc sync --target cursor --intent skills,commands --skills clean,plan --commands clean
```

- Selection narrows, it never prunes: skills or agents ycc installed earlier
  stay installed and recorded, and a later full sync without `--skills` /
  `--agents` changes nothing for them. `remove --skills a` takes back only `a`.
- Agent names are file stems on every target (`implementor` installs
  `~/.codex/agents/implementor.toml` on codex, `implementor.md` elsewhere).
- Shared helpers (`_shared`, opencode `shared/`, `~/.agents/ycc-shared/`) always
  ship with any selected skill. A selective remove keeps them while another
  ycc skill remains in that directory, whether ycc recorded it or `base`
  mirrored it there.
- Unknown names stop the run before any target writes. A name only some
  targets ship (for example a claude-only skill) is skipped on the others with
  a warning; a target that ships none of the names skips the step.
- After a selective install, the installer scans the selected skills and
  agents for `ycc:<name>` references and warns, per target, about skills or
  agents they call that are not installed there (with the command that adds
  them). Skills and agents the same run installs on that target count as
  installed. Agents meant to be dispatched only by a skill (`review-fixer`,
  `releaser`, ...) warn when none of their dispatching skills is available.
  Warnings never fail the run.
- `--with-deps` (`install` / `sync` only, with `--skills` or `--agents`, or
  `--commands` on claude) adds those dependencies instead of warning about
  them. Per target, before it runs, the installer walks the `ycc:<name>`
  references of the selected skills and agents transitively and adds every
  one that target ships:

  ```bash
  ycc sync --target claude --intent skills,agents --skills code-review --agents implementor --with-deps
  ```

  - It extends only kinds that already have a selection and whose step runs
    on that target. On claude, `--commands` names are skills, so they seed
    the skills walk too, and the added skills install with whichever of
    `--skills` / `--commands` that run uses. A kind without a selection
    already installs whole; a step that does not run is never turned on, and
    its references keep warning. Skills consolidated into `~/.agents/skills`
    (`--skills-home agents`) are not extended and keep warning.
  - Dependencies already available elsewhere (the installed ycc plugin, your
    own unrecorded entries, `~/.agents/skills` for targets that read it) are
    skipped unless ycc owns them, so a sync refreshes ycc-owned ones and never
    conflicts with yours. Their own references are still followed.
  - Each target prints what it added
    (`claude: --with-deps adds skills: review-fix, ...`). The expansion is
    per target: other targets keep the original selection.
  - Agents dispatched only by a skill still warn: picking a dispatching skill
    would be a guess.
  - `remove --with-deps` is rejected; removing dependencies other skills may
    use is destructive.

- `--skills` / `--agents` need the matching step (`--intent skills`,
  `--only agents`, ...). `base` is never filtered: it registers or mirrors the
  whole bundle. On codex, a local-mode `base` still syncs every custom agent
  into `~/.codex/agents`, and a `base` consolidated by `--skills-home agents`
  installs the whole agents slice instead of registering the plugin; both
  warn that `--agents` does not narrow the run. A repo-mode `base` only
  registers the marketplace and ships no custom agents, so `--agents` narrows
  the agents step there. On the agents target `base` ships the whole skills
  slice; `--skills` does not narrow a run that also runs `base` (it warns).
  The agents target has no agents step: with other targets,
  `--target all --intent agents --agents implementor` reports a no-op there
  and installs `implementor` on claude, cursor, codex and opencode; on its
  own, `--target agents --agents ...` is rejected.
- `--commands` narrows the `commands` step. On claude the commands are the
  skills, so on `install` / `sync` it narrows the skills slice; with
  `--skills` as well, the union of both selections installs once. On claude
  `remove`, `--commands a` only retires the recorded legacy wrapper `a.md` and
  never removes skills: only `--skills` narrows a skills removal, and
  `remove --intent skills,commands --commands a` without `--skills` skips the
  skills slice instead of removing all of it. codex, agents and omp have no
  commands step and skip `--commands`; it is an error only when no selected
  target has one (`ycc list commands --target codex` prints nothing).
- Every command loads the skill of its own name. After a selective opencode
  commands install, the installer warns (never fails, never installs it) for
  each command whose skill is not available: a skill ycc installed, a `base`
  mirror, `~/.agents/skills/<name>`, or a skill the same run installs counts.
- Cursor commands reference their skills and fail closed when one is missing
  (checked for the selected commands only; other installed commands are left
  alone). An install or sync that runs cursor's `commands` and `skills` steps
  with `--skills` needs `--commands`, and every selected command must be in
  the `--skills` selection; otherwise it is rejected before any target
  writes. Without `--skills` it installs the full skills slice with the
  commands (`ycc sync --target cursor --intent skills,commands`).
- With `--skills-home agents`, an install or sync's skills selection follows
  the skills into `~/.agents/skills`. `remove` does not follow it: remove
  consolidated skills with `--target agents` (or `all`).
- opencode per-agent model pins live in the `agents` block of the managed
  `opencode.json` (settings step), keyed by agent ID; pins for agents you did
  not select are harmless, so selection needs no config change.
- Shell completion offers the names after `--skills` / `--agents` /
  `--commands`, narrowed to the `--target` already on the command line (via
  `ycc list <kind>`).

### Merge Semantics

Structured config files (`~/.claude/settings.json`, `~/.claude.json`,
`~/.codex/config.toml`, `~/.config/opencode/opencode.json`,
`~/.cursor/cli-config.json`) are **merged**, not copied:

- Only keys this repository declares as managed are written; every other key
  in your file is preserved.
- A managed value the installer previously wrote is updated automatically on
  later runs.
- A managed value **you** changed is preserved with a warning; `--force` takes
  the repo value instead.
- Ownership is tracked by hash in `~/.config/ycc/managed-config-state.json`
  (hashes only, never values, so tokens never leak into state).
- Plugin list items (opencode `plugins`, claude `pluginMarketplaces`) are
  keyed by package name (version stripped) or `name`. When the repo bumps a
  version (`pkg@1.0.0` → `pkg@1.1.0`), the item the installer added is
  replaced in place, never duplicated. A same-name item you wrote yourself is
  kept with a warning; `--force` replaces it.

This is what makes new-machine setup reliable: run the same `sync` command on
any machine and repo-managed settings land without clobbering machine-local
trusted projects, provider credentials, or CLI-written marketplace entries.

### Project Vs Global Scope

`--project` and `--global` (mutually exclusive) work with `install`, `sync`,
and `remove`. Without either flag, steps that support project scope use it and
every other step stays global. The project is the git root of the current
directory, else the current directory. Today the `mcp` step and Claude `hooks`
are project-capable by default, the omp `base` step accepts an explicit
`--project` (omp's own default stays user scope), and so does the opencode
`settings` step for [third-party catalog plugins](opencode.md#third-party-plugins)
only:

| Target   | Step    | `--project`                                                                                                                                                                                                             | `--global`                              |
| -------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| claude   | `mcp`   | `<project>/.mcp.json` (default)                                                                                                                                                                                         | `~/.claude.json`                        |
| claude   | `hooks` | `claude plugin install ycc-hooks@ycc --scope project` (default; needs Claude Code >= 2.1.300). Marketplace declaration, when needed: `.claude/settings.local.json` (local mode) or `.claude/settings.json` (repo mode). | settings merge + `~/.claude/hooks` link |
| cursor   | `mcp`   | `<project>/.cursor/mcp.json` (default)                                                                                                                                                                                  | `~/.cursor/mcp.json`                    |
| codex    | `mcp`   | `<project>/.codex/config.toml` (default)                                                                                                                                                                                | `~/.codex/config.toml`                  |
| opencode | `mcp`   | `<project>/opencode.json` (default); catalog plugins (`--intent plugins --plugins <catalog names> --project`): companions in `<project>/.opencode/`                                                                     | `~/.config/opencode/opencode.json`      |
| omp      | `base`  | `omp plugin install --scope project <package>@ycc` (`ycc`, `ycc-mcp`)                                                                                                                                                   | `--scope user` (default)                |

Claude project hooks reuse a `ycc` marketplace this project or the user
already declares — in `~/.claude/settings.json`, `<project>/.claude/settings.json`,
or `<project>/.claude/settings.local.json` — without repointing it, so a
committed or pinned declaration (a `ref`, a fork) is never rewritten. When no
declaration is visible, the machine registration decides: absent or from the
same source the installer would declare, local mode declares the absolute
checkout path with `--scope local` in `<project>/.claude/settings.local.json`
(machine-specific and gitignored by Claude) and repo mode declares
`yandy-r/ystack` with `--scope project` in `<project>/.claude/settings.json`
(portable); registered from a different source, or the list is unreadable, the
installer warns and skips the plugin install rather than repoint anything.
Adding a same-source declaration never repoints (verified against Claude Code
2.1.310). Re-running sync also re-registers the machine after another
project's `remove` dropped the registration while this project still declares
ycc. Plugin enablement always goes in the project's `settings.json`.

The plugin carries its own activation, so a combined `settings,hooks` sync does
not write the global `hooks` config group. Removing hooks uninstalls the project
plugin; only a declaration exactly matching what the installer writes — the
local directory shape pointing at this checkout, or the unpinned upstream
`yandy-r/ystack` project shape — is removed, and only when no other `@ycc`
plugin is enabled in either project settings file and no other project or user
scope still has a `@ycc` install (removing the declaration drops the CLI's
machine-wide registration); pinned (`ref`) and forked declarations are kept. A
global installer-managed hooks link is left alone and
reported to avoid running `WorktreeCreate` twice. Explicit
Claude selection refuses project hooks at `$HOME`, without the Claude CLI, or
with a version older than 2.1.300; `--target all` warns and skips that hooks step
instead. `install --package` keeps Claude hooks global alongside its package-wide steps.

Codex loads a project `.codex/config.toml` only for trusted projects; the
installer warns when it writes one. An OMP project install shadows the user
install inside that project, and `--project` at `$HOME` is refused (see
[`omp.md`](omp.md#project-scope)). An explicit `--project` combined with a step
that has no project scope (for example `--only settings,mcp --project`) is
rejected before anything runs: the error is about `settings`, not `mcp`. Drop
`--project` to get project MCP plus global settings in one run. opencode
project settings likewise reject bundle plugins, the `settings` group and a run
without catalog `--plugins` (the bundle settings and the guard are global-only).

### Selecting MCP Servers

### GitHub MCP prerequisite

Install [GitHub CLI](https://cli.github.com/) and sign in with `gh auth login`
before enabling GitHub MCP. The runtime's `PATH` must also provide a POSIX `sh`
and [Node.js/npm](https://nodejs.org/) with `npx`.

ycc launches `mcp-remote` through `npx` to bridge the runtime's stdio connection
to GitHub's remote endpoint, `https://api.githubcopilot.com/mcp/`. No
`github-mcp-server` binary or Docker installation is needed. At each server
startup, `gh auth token` supplies the token; a failed authentication lookup stops
startup before launching the bridge. The token is passed through the bridge's
environment-variable header substitution, not written into managed config or
included in process arguments. Restart the MCP server after changing GitHub
accounts or credentials.

Normal `ycc sync --intent mcp` migrates recognized legacy
`github-mcp-server stdio`, `npx @modelcontextprotocol/server-github`, and
`https://api.githubcopilot.com/mcp` entries even without ownership state.
Obsolete transport/auth fields are removed; unrelated settings, servers and tools
remain. Custom GitHub connections stay untouched unless `--force` is explicit.
`--mcps` selection and `--dry-run` apply
to migration too.

By default the `mcp` step merges every server the repo manages for a target.
`--mcps <names>` (comma-separated) narrows `install`, `sync`, and `remove` to
just those servers, for every MCP-capable target (claude, cursor, codex,
opencode):

```bash
ycc list mcps                                   # every managed server
ycc list mcps --target codex                    # just codex's
ycc sync --target opencode --intent mcp --mcps github,linear
ycc sync --target all --intent mcp --mcps playwright --global
ycc install --target claude --only mcp --mcps github
ycc remove --target cursor --intent mcp --mcps stripe
```

- Servers not named are left alone: a partial sync never removes the other
  managed servers, and a partial remove takes only the named ones.
- Each name must be a managed server, else the run stops before writing
  anything. A target that manages none of the named servers skips its MCP step
  with a warning.
- Every MCP-capable target manages the same servers: `mcp-configs/mcp.json` is
  the single list. Codex gets a generated translation
  (`.codex-plugin/config/mcp-servers.json`); a server defined under
  `[mcp_servers.*]` in `.codex-plugin/config/config.toml` replaces its
  translation (Codex-only extras such as `bearer_token_env_var` and per-tool
  `approval_mode`).
- omp ships the whole list as the `ycc-mcp@ycc` package through the `base`
  step, so `--mcps` does not apply there; disable a single server with
  `disabledServers` (see [omp.md](omp.md#mcp-servers)).
- `--mcps` requires the `mcp` step (`--intent mcp`, `--mcp`, or `--only mcp`).
- Shell completion offers the managed server names after `--mcps`, narrowed to
  the `--target` already on the command line (via `ycc list mcps`). `ycc list`
  prints the selectable kinds; `ycc list-mcps` remains an alias of
  `ycc list mcps`.

> **Behavior change:** the `mcp` step used to write only user-global files.
> Pass `--global` to keep that. Cursor MCP is now merged instead of symlinked,
> and Codex/opencode MCP servers moved from the `settings` step to the `mcp`
> step.

### Selecting Plugins

By default the `plugins` intent merges every plugin entry the repo manages for
a target. `--plugins <names>` (comma-separated) narrows `install`, `sync`, and
`remove` to just those entries:

```bash
ycc sync   --target claude   --intent plugins --plugins superpowers@claude-plugins-official,context7@claude-plugins-official
ycc remove --target codex    --intent plugins --plugins cloudflare@openai-curated
ycc sync   --target opencode --intent plugins --plugins @prevalentware/opencode-goal-plugin
ycc sync   --target opencode --intent plugins --plugins oh-my-opencode-slim
ycc list plugins --target claude
```

| Target   | Names                                                         | What a name selects                                                                                                                             |
| -------- | ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| claude   | `enabledPlugins` keys (`name@mkt`)                            | the `enabledPlugins` key plus its marketplace (`extraKnownMarketplaces` entry, `pluginMarketplaces` item)                                       |
| codex    | `[plugins."name@mkt"]` table names                            | that table in `~/.codex/config.toml`                                                                                                            |
| opencode | `plugins` package names (version dropped), then catalog names | that `plugins` item (`./ycc-sensitive-guard` also ships or removes its guard directory); a catalog name installs that opt-in third-party plugin |

- Entries not named are left alone, along with their state. `settings` keys in
  the same run stay whole, and so do `hooks` keys unless `--hooks` narrows them
  (see [Selecting Mods And Hook Events](#selecting-mods-and-hook-events)):
  `--intent settings,plugins --plugins x` still merges every managed setting.
- Marketplaces follow their plugins and are never listed or selected on their
  own (`--plugins claude-plugins-official` is an unknown name). `remove`
  (selective or full) keeps a marketplace while an enabled plugin in your
  `settings.json` still uses it, and says so.
- `--plugins` requires the `plugins` config group: `--intent plugins` on
  `sync`/`remove`, or `install --only settings`.
  `--intent settings --plugins x` and `install --package … --plugins x` are
  rejected before anything is written.
- Each name must be managed for a selected target, else the run stops before
  writing anything. A target that manages none of the named entries skips its
  plugins group with a warning; cursor, agents and omp have no plugins group.
- Shell completion offers the names after `--plugins`, narrowed to the
  `--target` already on the command line (via `ycc list plugins`).
- opencode also lists an opt-in catalog of pinned third-party plugins
  (`ycc/settings/opencode-plugins.json`, for example `oh-my-opencode-slim`).
  Only `--plugins` installs one: its pinned `plugins` item, its managed keys
  and its companion config, plus printed manual follow-ups. See
  [Third-party plugins](opencode.md#third-party-plugins).

### Selecting Mods And Hook Events

On claude, `--mods <names>` and `--hooks <events>` (comma-separated) narrow the
`mods` step and the `--global` `hooks` config group the same way `--plugins`
narrows plugins. Other targets have no mods step or hooks group, so
`ycc list mods` and `ycc list hooks` print nothing for them:

```bash
ycc list mods --target claude                   # what --mods accepts (status-bar)
ycc list hooks --target claude                  # what --hooks accepts (WorktreeCreate)
ycc sync    --target claude --intent mods --mods status-bar
ycc install --target claude --only mods --mods status-bar
ycc remove  --target claude --intent mods --mods status-bar
ycc sync    --target claude --intent hooks --hooks WorktreeCreate --global
ycc remove  --target claude --intent hooks --hooks WorktreeCreate --global
```

- `--mods` registers the `ycc-mods` marketplace and installs only the named
  mods; the sideload warning checks only those. `remove --mods` uninstalls
  only the named mods and keeps the `ycc-mods` marketplace (and says why)
  while another `*@ycc-mods` key is still listed in `enabledPlugins` in
  `~/.claude/settings.json` (enabled or not).
  Without `--mods`, `remove` uninstalls every mod and the marketplace.
- `--hooks` selects whole hook **events** (`settings.json` `hooks` keys), not
  individual scripts, only with Claude's `--global` hooks step; the project
  native plugin always installs its whole hook set. Only the named events are
  merged or removed; the other managed events keep their entries and ownership
  state. Sync with `--hooks` still creates (or keeps) the `~/.claude/hooks`
  directory link; a selective `remove` keeps that link while any managed hook
  event outside the selection is still recorded, and unlinks it once none remains.
- `--hooks` is a selector only on `sync` and `remove`. On `install` it stays
  the boolean "also run the hooks step" flag and takes no value.
- `--mods` needs the `mods` step (`--intent mods`, `--only mods`); `--hooks`
  needs the `hooks` config group (for example `--intent hooks --global`). Another
  target whose `hooks` step has no hook-event selection (cursor) skips that
  step with a warning instead of running it whole. Unknown names,
  or a run where no selected target has the step, stop before anything is
  written.
- Shell completion offers the names after `--mods` and after `sync` /
  `remove` `--hooks`, narrowed to the `--target` already on the command line;
  install's `--hooks` completes no value.

### Removing Installed Config

```bash
./install.sh remove --target claude --only mcp                  # project scope
./install.sh remove --target all --intent mcp --global          # user-global
./install.sh remove --target codex --intent settings,plugins,rules
./install.sh remove --target all --intent base,settings,rules,hooks,plugins,mods
./install.sh remove --target opencode --intent agents,commands
./install.sh remove --target opencode --intent plugins --plugins oh-my-opencode-slim --purge-cache
```

The example removing every intent above still uses project scope for Claude
hooks. Global installer-managed hooks need a separate
`./install.sh remove --target claude --intent hooks --global`.

`remove` undoes any intent on any target, using the same intent → step mapping
as `sync` (an intent a target does not support is reported and skipped). It
requires `--only` or `--intent`, and rejects `--mode` and the additive
`--settings`/`--rules`/`--mcp` flags (there `--hooks <events>` selects hook
events). Only what the installer owns is
taken back:

| Step / intent                      | What `remove` does                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `settings`, `plugins`, `hooks`     | Strips repo-managed keys from the structured config (`settings.json`, `cli-config.json`, `config.toml`, `opencode.json`). List entries (plugin lists, Cursor permissions) lose only the items the installer appended. A claude marketplace stays while an enabled plugin still uses it. opencode catalog plugins (the selected ones, else every one ycc installed) also lose their companion files when unchanged; `--purge-cache` also deletes their opencode package cache. |
| `mcp`                              | Strips managed MCP servers, including ones the repo has since dropped. Servers you added are never touched.                                                                                                                                                                                                                                                                                                                                                                   |
| `rules`, claude global `hooks` dir | Removes the symlinks, only while they still point at this checkout. A real file you put there is never deleted.                                                                                                                                                                                                                                                                                                                                                               |
| claude project `hooks`             | Uninstalls `ycc-hooks@ycc` at project scope; removes only a local marketplace declaration matching this checkout or a project declaration matching `yandy-r/ystack`, when no other `@ycc` plugin is enabled in either project settings file and no other project or user scope has a `@ycc` install.                                                                                                                                                                          |
| claude statusline script           | Removed while identical to the repo copy; an edited copy needs `--force`.                                                                                                                                                                                                                                                                                                                                                                                                     |
| `base`                             | claude: `claude plugin uninstall ycc@ycc` + marketplace remove. cursor / opencode: the bundle's entries in the synced dirs (your own skills stay). codex: plugin links, plugin cache, custom agents, marketplace entry. omp: the recorded `ycc@ycc` and `ycc-mcp@ycc` installs for the scope, then the `ycc` marketplace and export once unused.                                                                                                                              |
| `skills`, `agents`, `commands`     | Removes the standalone entries ycc recorded (or that are still identical to the bundle). Never the plugin, never your own entries without `--force`. On claude, `commands` retires only the recorded legacy `~/.claude/commands/` wrappers.                                                                                                                                                                                                                                   |
| `mods` (claude)                    | Uninstalls each mod and the `ycc-mods` marketplace. With `--mods`, only the named mods; the marketplace stays while another ycc mod is still listed in `enabledPlugins`.                                                                                                                                                                                                                                                                                                      |

- Cursor `hooks` removes the owned session script in `~/.cursor/hooks/` and the managed `sessionStart` entries in `~/.cursor/hooks.json`.
- A managed value you edited is kept with a warning; `--force` removes it.
- `--purge-cache` is valid only with `remove`. It deletes the
  `${XDG_CACHE_HOME:-~/.cache}/opencode` `npm/`, `packages/` and `node_modules/`
  copies of each catalog plugin removed from `opencode.json`.
- A config file left empty is deleted. Codex TOML removal keeps comments,
  trusted projects and unrelated tables.

### Previewing With `--dry-run`

```bash
./install.sh remove --target all --only mcp --dry-run
./install.sh sync --target claude,codex --intent mcp --global --dry-run
```

`--dry-run` works with `install`, `sync` and `remove` on every target and
writes no config, file or ownership state. The `mcp` step prints each
`would set` / `would remove` change. On omp every step previews itself (see
the [OMP guide](omp.md)). Any other step prints
`dry-run: <target> <step> step has no preview — skipped` and does not run.

### Legacy Flag Form

The original flag CLI keeps working unchanged:

```bash
./install.sh install --target <claude|cursor|codex|opencode|agents|omp|all> [flags]
```

Without `--only`, the target's `base` step runs by default, and additive flags
run additional steps.

Common flags:

```bash
./install.sh install --target claude --settings --rules --mcp --hooks
./install.sh install --target cursor --rules --mcp
./install.sh install --target codex --settings --rules
./install.sh install --target opencode --settings --rules
./install.sh install --target all --settings --rules --mcp
```

Use `--only <steps>` to run exactly the listed steps and skip the default `base`
step:

```bash
./install.sh install --target claude --only rules
./install.sh install --target codex --only settings,rules
```

## Source Modes

`--mode local` is the default. It registers or syncs the current checkout so
contributors can iterate locally.

`--mode repo` registers the upstream GitHub repository instead of the local
checkout. It is supported by the `claude`, `codex` and `omp` targets only:

```bash
./install.sh install --target claude --mode repo
./install.sh install --target codex --mode repo
./install.sh install --target omp --mode repo
./install.sh install --target all --mode repo
```

With `--target all --mode repo`, Cursor and opencode are skipped because they do
not have a remote-source install surface. `--target all` (any mode) also skips
omp unless `omp >= 18.12.2` is on `PATH`.

## Regenerate And Validate

When editing source-of-truth files under `ycc/`, regenerate derived bundles and
validate them before committing:

```bash
./scripts/sync.sh
./scripts/validate.sh
```

Both scripts accept `--only <targets>` for narrower runs, such as
`./scripts/sync.sh --only codex`.
