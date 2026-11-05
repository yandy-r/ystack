# Install Guides

This directory has the install guides for `ycc`, one per runtime. The root
[`README.md`](../../README.md) stays short and links here. This page is the one
reference for the `install.sh` installer. The [`v6/`](v6/README.md) pages are
reference material: package IDs, marketplace shape, tested versions, and
evidence.

## Runtime Guides

| Runtime  | Guide                        | Route                                                                                                          | Package reference                  |
| -------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| Claude   | [`claude.md`](claude.md)     | Native: `claude plugin install` of `ycc@ycc`, `ycc-mcp@ycc`, `ycc-hooks@ycc` (or `ycc-all@ycc`)                | [`v6/claude.md`](v6/claude.md)     |
| Codex    | [`codex.md`](codex.md)       | Native: `codex plugin add` of `ycc@ycc` and `ycc-mcp@ycc`; custom agents, settings and rules from `install.sh` | [`v6/codex.md`](v6/codex.md)       |
| Cursor   | [`cursor.md`](cursor.md)     | Native: `agent plugin marketplace add`, then pick the packages in `/plugins`                                   | [`v6/cursor.md`](v6/cursor.md)     |
| OMP      | [`omp.md`](omp.md)           | Native: `omp plugin install` of `ycc@ycc`, `ycc-mcp@ycc`, `ycc-rules@ycc`                                      | [`omp.md`](omp.md)                 |
| opencode | [`opencode.md`](opencode.md) | File copy and config merge (the npm package is experimental and opt-in)                                        | [`v6/opencode.md`](v6/opencode.md) |
| agents   | [`agents.md`](agents.md)     | File copy of skills into `~/.agents/skills` (Zed and others)                                                   | [`v6/agents.md`](v6/agents.md)     |

Every native package can also be installed straight from the published
repository with the runtime's own CLI; each runtime guide shows the commands.

## Installer Model

Run `install.sh` from the repository root, or `ycc` once it is on `PATH`. Every
invocation starts with a command: `install`, `sync`, `remove`, `list`, `cli`, or
`completion`. A bare `./install.sh --target ...` is rejected. `install` is the
first-time setup (the `base` step plus the opt-in `--settings`, `--rules`,
`--mcp` and `--hooks` flags, or `--only`). After that, `sync` is the
recommended entry point:

```bash
./install.sh sync --target <claude|cursor|codex|opencode|agents|omp|all> --intent <intents>
```

You say **what** you want synced. Each target maps the intent onto the steps it
supports and reports anything it cannot do instead of silently substituting.

```bash
./install.sh sync --target claude --intent base,mcp,hooks
./install.sh sync --target all --intent settings,rules --global
./install.sh sync --target cursor --intent base,rules,mcp
./install.sh remove --target claude --only mcp
```

Two install routes exist, depending on the target:

- **Native packages: claude, codex, cursor, omp.** `install` and `sync` install
  ycc only through the runtime's own plugin CLI, from the `ycc` marketplace in
  this repository. Claude gets `ycc@ycc`, `ycc-mcp@ycc` and `ycc-hooks@ycc`.
  Codex gets `ycc@ycc` and `ycc-mcp@ycc`. Cursor gets the marketplace
  registration plus a `/plugins` hint, because its CLI cannot install plugins
  non-interactively. OMP gets `ycc@ycc`, `ycc-mcp@ycc` and `ycc-rules@ycc`.
  The installer still delivers what no plugin can carry: settings, rules and
  instructions, the Claude statusline, Codex custom agents, and the Claude mods.
- **File copy: opencode, agents.** These targets have no native route. The
  installer copies their bundles and merges their config, and the selection
  flags (`--skills`, `--agents`, `--commands`, `--mcps`, `--with-deps`,
  `--skills-home`) apply to them only.

`mcp`, Claude `hooks`, and `settings` on Claude, Codex and opencode default to
project scope. Cursor and OMP settings, and Codex MCP, are global only. See
[Project Vs Global Scope](#project-vs-global-scope). To undo any of it, see
[Removing Installed Config](#removing-installed-config).

### Automatic Legacy Cleanup

Older ycc releases installed Claude, Codex, Cursor and OMP through copied files,
merged MCP and hook config, and links. A successful native install on those
targets retires that legacy state automatically, in the same `install` or
`sync` run; `remove` of the `base` step runs the same cleanup on Claude, Codex
and Cursor. There is no separate command to run.

The cleanup removes only entries it can prove the installer wrote: a recorded
ownership hash, an entry recorded in `~/.config/ycc/installed-units.json`, a
byte-identical copy of the shipped source, or a symlink that points at this
checkout. It never deletes user data. Edited, foreign or uncertain entries stay
and are reported with a `[!!] kept <path>: <reason>` line. Symlinked config files
are kept rather than written through. The cleanup installs nothing, is safe to
repeat, and `--dry-run` previews it.

| Target | What the cleanup retires                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| claude | Standalone copies in `~/.claude/skills` and `~/.claude/agents`, and the legacy `~/.claude/commands` wrappers ycc recorded. The installer-written `WorktreeCreate` hook commands in `~/.claude/settings.json` and the `~/.claude/hooks` link, once `ycc-hooks@ycc` is enabled there. The managed MCP servers in `~/.claude.json`, once `ycc-mcp@ycc` is enabled there. Old `local-ycc-plugins` entries. Global files only; project files stay. |
| codex  | The `ycc@local-ycc-plugins` enablement and the managed `[mcp_servers.*]` in `~/.codex/config.toml`, the `~/.codex/plugins/ycc` and `~/.agents/plugins/ycc` links, the `~/.codex/plugins/cache/local-ycc-plugins/ycc` snapshot (also when it matches an older release in this checkout's git history), the legacy catalog entry, and installer copies in `~/.codex/skills`. Everything under `~/.codex/agents` is kept.                        |
| cursor | Recorded command wrappers in `~/.cursor/commands`, the owned `sessionStart` hook (script and `~/.cursor/hooks.json` entry), byte-identical copies in `~/.cursor/{skills,agents,rules}`, the managed servers in `~/.cursor/mcp.json`, and `~/.cursor/CLAUDE.md` / `AGENTS.md` links to this checkout. Project `<project>/.cursor/mcp.json` files are not touched.                                                                              |
| omp    | An `omp plugin link` of a ycc package from this checkout and a `ycc` marketplace registered at the checkout root. They are retired before the native install, which reinstalls the packages in the same scopes. See [omp.md](omp.md#legacy-cleanup).                                                                                                                                                                                          |

On Claude, the hook and MCP cleanup needs explicit proof that the native
package replaced them: `ycc-hooks@ycc` or `ycc-mcp@ycc` set to `true` in
`enabledPlugins` of `~/.claude/settings.json`. Enabling `ycc-all@ycc` alone is
not that proof. Until then the cleanup prints
`Claude hooks retained: ycc-hooks@ycc is not explicitly enabled` (or the MCP
equivalent) and leaves those entries. User hook commands in the same event
stay. A plugin hook and a leftover settings hook for the same event both run,
so install `ycc-hooks@ycc` at user scope (`--global`) to retire the legacy
global hook.

On Codex, the cleanup runs only when this checkout carries an eligible native
`ycc` catalog; otherwise it prints `Codex native gate failed: …`, leaves the
legacy files intact, and the installer warns `legacy cleanup skipped` without
failing the run. A shallow clone that lacks the commit of an older snapshot
keeps that snapshot and prints `git fetch --unshallow`.

### `ycc` Command On PATH

Project-scoped runs happen from inside the other project, where `./install.sh`
does not exist. Link the installer onto `PATH` once:

```bash
./install.sh cli                 # symlink install.sh as `ycc`
ycc completion --install         # shell completion for $SHELL
cd ~/code/other-project && ycc sync --target claude --intent mcp
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

### Intents

| Intent     | Meaning                                                                                                                                                                                       |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `base`     | Install the target's ycc package or bundle. claude/codex: the `ycc` plugin from the `ycc` marketplace. cursor: register the marketplace. omp: the native packages. opencode/agents: the copy. |
| `skills`   | claude, codex, cursor: part of the `ycc` package (maps to `base`). opencode: standalone skills in its skills dir. agents: the whole `~/.agents/skills` target.                                |
| `agents`   | claude, cursor: part of the `ycc` package (maps to `base`). codex: custom agents in `~/.codex/agents` (no native carrier). opencode: standalone agents in its agents dir.                     |
| `commands` | claude, cursor: part of the `ycc` package (maps to `base`). opencode: one thin generated command per public skill.                                                                            |
| `settings` | Merge repo-managed config keys (models, effort levels, statusline, ...). Project scope by default on Claude, Codex and opencode; `--global` for user config. Cursor and OMP: `--global` only. |
| `rules`    | Link the global instructions file each runtime reads (Claude `CLAUDE.md`, Codex `default.rules` + `AGENTS.md`, opencode/OMP `AGENTS.md`). Cursor: the `ycc-rules` package (maps to `base`).   |
| `mcp`      | claude: `claude plugin install ycc-mcp@ycc`. codex: `codex plugin add ycc-mcp@ycc` (user scope). cursor: the `ycc-mcp` package (maps to `base`). opencode: merge MCP server definitions.      |
| `hooks`    | claude: `claude plugin install ycc-hooks@ycc` (Claude Code 2.1.300 or later). cursor: the `ycc-hooks` package (maps to `base`). Others: no-op.                                                |
| `plugins`  | Merge plugin enablement and marketplace entries. Global-only (pass `--global`), except opencode catalog plugins. Add `base` for CLI-side registration too. OMP: maps to `base`.               |
| `mods`     | Install the Claude Code mods under `ycc/mods` (claude only).                                                                                                                                  |

Per-target mapping (intents a target cannot execute are skipped with a notice):

| Intent     | claude     | cursor     | codex      | opencode   | agents   | omp           |
| ---------- | ---------- | ---------- | ---------- | ---------- | -------- | ------------- |
| `base`     | `base`     | `base`     | `base`     | `base`     | `base`   | `base,dedupe` |
| `skills`   | `base`     | `base`     | `base`     | `skills`   | `skills` | no-op         |
| `agents`   | `base`     | `base`     | `agents`   | `agents`   | no-op    | no-op         |
| `commands` | `base`     | `base`     | no-op      | `commands` | no-op    | no-op         |
| `settings` | `settings` | `settings` | `settings` | `settings` | no-op    | `settings`    |
| `rules`    | `rules`    | `base`     | `rules`    | `rules`    | no-op    | `rules`       |
| `mcp`      | `mcp`      | `base`     | `mcp`      | `mcp`      | no-op    | no-op         |
| `hooks`    | `hooks`    | `base`     | no-op      | no-op      | no-op    | no-op         |
| `plugins`  | `settings` | no-op      | `settings` | `settings` | no-op    | `base,dedupe` |
| `mods`     | `mods`     | no-op      | no-op      | no-op      | no-op    | no-op         |

`sync` is exclusive: it never implicitly runs `base`. On Claude, `skills`,
`agents` and `commands` run `base`, because those components ship only inside
the `ycc` plugin. On Cursor, every package intent runs the one marketplace step,
and the `/plugins` hint names the packages the requested intents need (`ycc`,
`ycc-rules`, `ycc-mcp`, `ycc-hooks`).

Global instructions are linked as `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, or
`~/.config/opencode/AGENTS.md`, not both filenames. Cursor rules ship as the
`ycc-rules` package. See each target page for official loading references.
Install and sync keep older rule links; `remove` unlinks only links to this
checkout.

### Standalone Slices (opencode, agents, Codex agents)

The `skills`, `agents` and `commands` steps of the file-copy targets install
entries one by one into each tool's own user directories, with no plugin or
marketplace registration. Codex custom agents use the same mechanism, because
Codex plugins cannot carry them:

| Target   | Destinations                                                            |
| -------- | ----------------------------------------------------------------------- |
| opencode | `~/.config/opencode/{skills,agents,commands}/<name>` (+ `shared/`)      |
| agents   | `~/.agents/skills/<name>` (+ `~/.agents/ycc-shared/`)                   |
| codex    | `~/.codex/agents/<name>.toml` (custom agents only; always the full set) |

- Entries are copied with plugin-root paths re-pointed at the new location and
  `ycc:` prefixes dropped, so each works without the plugin.
- What ycc installed is recorded in `~/.config/ycc/installed-units.json`. An
  existing entry is replaced only when ycc installed it or it is identical;
  your own skills or agents with the same name need `--force`. Entries the
  bundle no longer ships are pruned on the next sync.
- `--only` / `--intent` skip a slice a target has no home for (for example
  `commands` on codex), so `--target all --only agents` just works. With
  `--target all`, `--only` also skips any other step a target lacks (for
  example `--only mcp` on the agents target); a step no target has is an error.

### Selecting Skills, Agents, Commands And MCP Servers

`--skills`, `--agents`, `--commands` and `--mcps` (comma-separated) narrow a
step to the named entries; `--with-deps` and `--skills-home` refine the skills
install. They apply to **opencode and agents only**. The native-package targets
(claude, codex, cursor, omp) install whole packages, so:

- with only native targets selected, these flags are an error;
- with `--target all` (or another mix), they apply to opencode and agents, and
  the native targets skip them with one notice.

```bash
ycc list skills --target opencode               # what --skills accepts there
ycc sync --target opencode --intent skills --skills code-review,git-workflow
ycc sync --target agents --intent skills --skills prp-plan
ycc sync --target opencode --intent agents --agents implementor,code-reviewer
ycc remove --target opencode --intent skills --skills visual-recap
ycc sync --target opencode --intent skills,commands --skills clean --commands clean
ycc sync --target opencode --intent mcp --mcps github,linear
```

- Selection narrows, it never prunes: entries ycc installed earlier stay
  installed and recorded, and a later full sync without the flag changes
  nothing for them. `remove --skills a` takes back only `a`.
- Agent names are file stems (`implementor`, not `implementor.md`).
- Shared helpers (opencode `shared/`, `~/.agents/ycc-shared/`) always ship with
  any selected skill. A selective remove keeps them while another ycc skill
  remains in that directory.
- Unknown names stop the run before any target writes.
- After a selective install, the installer scans the selected skills and
  agents for `ycc:<name>` references and warns about the ones not installed
  there (with the command that adds them). Warnings never fail the run.
- `--with-deps` (`install` / `sync` only, with `--skills` or `--agents`) adds
  those dependencies instead of warning about them. It walks the `ycc:<name>`
  references transitively and adds every one the target ships, prints
  `<target>: --with-deps adds ...`, and skips dependencies you already have
  from elsewhere unless ycc owns them. `remove --with-deps` is rejected.

  ```bash
  ycc sync --target opencode --intent skills,agents --skills code-review --agents implementor --with-deps
  ```

- `--commands` narrows opencode's `commands` step. Each command loads the skill
  of its own name; after a selective install, the installer warns (never
  fails) for each command whose skill is not available.
- `--mcps` narrows opencode's `mcp` step. Servers not named are left alone; a
  partial remove takes only the named ones. Each name must be a managed
  server. The native targets ship the whole server list as the `ycc-mcp`
  package; disable a single server in the runtime itself.
- `--skills-home agents|native` resolves duplicate skills when opencode would
  install ycc skills into its own skills dir and `~/.agents/skills` (it reads
  both). `agents` installs the skills once into `~/.agents/skills` and keeps
  opencode's agents, commands and config native; `native` keeps both copies.
  Without the flag a terminal run prompts, and a non-terminal run warns and
  proceeds as requested. See [agents.md](agents.md#duplicate-skills).
- opencode per-agent model pins live in the `agents` block of the managed
  `opencode.json` (settings step); pins for agents you did not select are
  harmless.
- Shell completion offers the names after each flag, narrowed to the
  `--target` already on the command line (via `ycc list <kind>`).

### Merge Semantics

Structured config files (`~/.claude/settings.json`, `~/.codex/config.toml`,
`~/.config/opencode/opencode.json`, `~/.cursor/cli-config.json`, and their
project counterparts) are **merged**, not copied:

- Only keys this repository declares as managed are written; every other key
  in your file is preserved.
- A managed value the installer previously wrote is updated automatically on
  later runs.
- A managed value **you** changed is preserved with a warning; `--force` takes
  the repo value instead.
- Ownership is tracked by hash in `~/.config/ycc/managed-config-state.json`
  (hashes only, never values, so tokens never leak into state), separately per
  destination file, so a project file and the global file never share state.
- Plugin list items (opencode `plugins`, claude `pluginMarketplaces`) are
  keyed by package name (version stripped) or `name`. When the repo bumps a
  version (`pkg@1.0.0` → `pkg@1.1.0`), the item the installer added is
  replaced in place, never duplicated. A same-name item you wrote yourself is
  kept with a warning; `--force` replaces it.

This is what makes new-machine setup reliable: run the same
`sync --global` command on any machine and repo-managed settings land without
clobbering machine-local trusted projects, provider credentials, or CLI-written
marketplace entries.

### Project Vs Global Scope

`--project` and `--global` (mutually exclusive) work with `install`, `sync`,
and `remove`. Without either flag, steps that support project scope use it and
every other step stays global. The project is the git root of the current
directory, else the current directory. Project-capable by default: Claude
`mcp` and `hooks`, opencode `mcp`, and `settings` on Claude, Codex and
opencode. The omp `base` step accepts an explicit `--project` (omp's own default
stays user scope). `install --package` keeps `mcp`, `hooks` and `settings`
global.

| Target   | Step    | `--project` (default)                                                                            | `--global`                                         |
| -------- | ------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------- |
| claude   | `mcp`   | `claude plugin install ycc-mcp@ycc --scope project`                                              | `claude plugin install ycc-mcp@ycc --scope user`   |
| claude   | `hooks` | `claude plugin install ycc-hooks@ycc --scope project` (writes `<project>/.claude/settings.json`) | `claude plugin install ycc-hooks@ycc --scope user` |
| opencode | `mcp`   | `<project>/opencode.json`                                                                        | `~/.config/opencode/opencode.json`                 |
| codex    | `mcp`   | none: `--project` is an error                                                                    | `codex plugin add ycc-mcp@ycc` (the default)       |
| cursor   | all     | none: Cursor plugins are installed in `/plugins`                                                 | marketplace registration (the default)             |
| omp      | `base`  | `omp plugin install --scope project <package>@ycc` (refused at `$HOME`)                          | `--scope user` (default)                           |

Both Claude `hooks` scopes need Claude Code 2.1.300 or later. Claude project
plugins are refused at `$HOME`. An explicit Claude selection stops before any
writes when the `hooks` step lacks the Claude CLI or finds an older version;
`--target all` warns and skips that hooks step instead.

The `settings` step writes a project file with preference keys only:

| Target   | `settings --project` (default)                                                                                                        | `settings --global`                                                  | Project keys                                                                                                                                                                       |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| claude   | `<project>/.claude/settings.json`                                                                                                     | `~/.claude/settings.json` + copied `~/.claude/statusline-command.sh` | `env`, `attribution`, `model`, `modelSettings`, `alwaysThinkingEnabled`, `effortLevel`                                                                                             |
| codex    | `<project>/.codex/config.toml` (loaded only for trusted projects)                                                                     | `~/.codex/config.toml`                                               | `personality`, `model`, `model_reasoning_effort`, `model_context_window`, `model_auto_compact_token_limit`, `plan_mode_reasoning_effort`, `service_tier`, `[agents]`, `[features]` |
| opencode | `<project>/opencode.json`; [catalog plugins](opencode.md#third-party-plugins) also ship companions in `<project>/.opencode/`          | `~/.config/opencode/opencode.json`                                   | `$schema`, `model`, `agents`, `providers`, `experimental.subagent_depth`; catalog plugins                                                                                          |
| cursor   | none: skipped with a notice unless `--global`; `--project` is rejected (Cursor's project `.cursor/cli.json` carries permissions only) | `~/.cursor/cli-config.json`                                          | —                                                                                                                                                                                  |
| omp      | none: skipped with a notice unless `--global`; `--project` is rejected (ycc never writes `.omp/config.yml`)                           | `<agentDir>/config.yml`                                              | —                                                                                                                                                                                  |

- **Global-only keys.** Claude `statusLine` (and the statusline script),
  `permissions`, `skipAutoPermissionPrompt` and
  `skipDangerousModePermissionPrompt`; Codex `approval_policy`,
  `approvals_reviewer`, `sandbox_mode` and `[sandbox_workspace_write]`, so a
  project file never widens the approval or sandbox posture. Codex provider,
  auth, profile, `notify` and `otel` keys are ignored by Codex at project
  level and never written there.
- **Global-only group.** The `plugins` config group (Claude, Codex, and
  opencode bundle plugins with `./ycc-sensitive-guard`). At default scope a
  requested group is skipped with
  `<target>: the plugins group is global-only — skipped at project scope. Pass --global to merge it.`;
  an explicit `--project` with `--intent plugins` or `--plugins` is rejected
  before anything runs. opencode catalog plugins are the exception and install
  per project.
- **Committed files.** `<project>/.claude/settings.json`,
  `<project>/.codex/config.toml` and `<project>/opencode.json` are usually
  committed and shared with everyone who works in the repository. Project
  values also outrank each user's global ones there. Review the diff before
  committing, or keep these preferences global with `--global`.
- **Codex trust.** Codex loads `<project>/.codex/config.toml` only when the
  project is trusted in `~/.codex/config.toml`; the installer warns when it
  writes the file and never writes `[projects]` trust entries itself.
- **`$HOME`.** Project settings need a project directory. From `$HOME`, a
  default run skips the step with a notice, and an explicit `--project` is
  rejected.
- **Removal.** `remove --intent settings` takes managed keys back from the
  project file, and only keys ycc recorded writing: a key you added yourself
  stays even when its value matches the repo exactly. A file left empty is
  deleted. Add `--global` to clean the user files.

A defaulted settings run warns while the global file still holds ycc-managed
keys from earlier syncs:
`<target>: settings now default to project scope; <global dest> still holds ycc-managed keys from earlier syncs — pass --global to update or remove them.`

#### Claude Project Plugins

The project-scope `mcp` and `hooks` steps run `claude plugin install
<plugin>@ycc --scope project`. They reuse a `ycc` marketplace this project
already declares (in `<project>/.claude/settings.json` or
`<project>/.claude/settings.local.json`) without repointing it, so a committed
or pinned declaration (a `ref`, a fork) is never rewritten.

The CLI never creates a registration from a declaration alone, and
`claude plugin marketplace add` rewrites the entry it writes from its
arguments (dropping keys such as `autoUpdate`, turning a relative directory
path into an absolute one, appending `.git` to a git url). So when the machine
has no `ycc` registration (a fresh clone, or another project's `remove` dropped
it), the installer re-registers a project or local declaration with
`claude plugin marketplace add <source> --scope <declaration scope>` only when
that add reproduces the declaration's content: the entry holds nothing but
`source`, and the source is github (`repo[#ref]`), a directory with an absolute
normalised `path`, or a git url ending in `.git` (https, http or `git@`, with
an optional `#ref`). Any other declaration is left untouched: the installer
warns `ycc is declared in <file> but not registered on this machine;
re-registering would rewrite that declaration` and skips the plugin install.

A declaration in `~/.claude/settings.json` (the `settings` step writes one) is
not a registration, but the CLI rejects a project or local add whose source
differs from it (directory sources excepted). With no registration and no
project or local declaration, local mode adds the checkout directory with
`--scope local`, and repo mode adds the user declaration's own source (for
example `yandy-r/ystack#main`) with `--scope project`; the user file stays
byte-identical. When no declaration is visible, the machine registration
decides: absent, or exactly the unpinned source the installer would declare,
local mode declares the absolute checkout path with `--scope local` in
`<project>/.claude/settings.local.json` (machine-specific and gitignored by
Claude) and repo mode declares `yandy-r/ystack` with `--scope project` in
`<project>/.claude/settings.json` (portable). Registered from any other source
(a fork, a `ref` pin, a subpath), or with an unreadable list, the installer
warns and skips the plugin install rather than repoint anything. Every
`marketplace add` is guarded: when the CLI rejects it, the installer warns with
the CLI's reason line and skips the plugin install without aborting the run.
Plugin enablement always goes in the project's `settings.json`.

Removing project `mcp` or `hooks` uninstalls the project plugin. Only a
declaration exactly matching what the installer writes (the local directory
shape pointing at this checkout, the unpinned upstream `yandy-r/ystack` project
shape, or that repo pinned exactly as the user declaration repo mode copies) is
removed, and only when no other `@ycc` plugin is enabled in either project
settings file and no other project or user scope still has a `@ycc` install
(removing the declaration drops the CLI's machine-wide registration). Other
pins and forked declarations are kept.

An explicit `--project` combined with a step that has no project scope (for
example `./install.sh install --target claude --only rules,mcp --project`) is
rejected before anything runs: the error is about `rules`, not `mcp`. Drop
`--project` to get project MCP plus global rules in one run. The same applies to
Cursor and OMP `settings`, Codex `mcp`, and to an explicitly requested
global-only group (opencode project plugins accept catalog `--plugins` names
only). An OMP project install shadows the user install inside that project, and
`--project` at `$HOME` is refused (see [`omp.md`](omp.md#project-scope)).

### MCP Servers

`mcp-configs/mcp.json` is the single list of managed servers. The native
targets ship it as the `ycc-mcp` package (Claude, Codex, Cursor and OMP), so the
whole list installs at once. opencode merges it into `opencode.json`, and only
there does `--mcps` select servers. Codex's package uses a generated
translation (`.codex-plugin/config/mcp-servers.json`); a server defined under
`[mcp_servers.*]` in `.codex-plugin/config/config.toml` replaces its translation
(Codex-only extras such as `bearer_token_env_var` and per-tool `approval_mode`).
OMP users disable a single server with `disabledServers` (see
[omp.md](omp.md#mcp-servers)).

#### GitHub MCP prerequisite

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

On opencode, `ycc sync --intent mcp` rewrites recognized older
`github-mcp-server stdio`, `npx @modelcontextprotocol/server-github`, and
`https://api.githubcopilot.com/mcp` entries even without ownership state.
Obsolete transport and auth fields are removed; unrelated settings, servers and
tools remain. Custom GitHub connections stay untouched unless `--force` is
explicit. `--mcps` selection and `--dry-run` apply to that rewrite too.

### Selecting Plugins

By default the `plugins` intent merges every plugin entry the repo manages for
a target. `--plugins <names>` (comma-separated) narrows `install`, `sync`, and
`remove` to just those entries. The `plugins` config group is global-only, so
pass `--global`; only opencode catalog plugins also install per project:

```bash
ycc sync   --target claude   --intent plugins --plugins superpowers@claude-plugins-official,context7@claude-plugins-official --global
ycc remove --target codex    --intent plugins --plugins cloudflare@openai-curated --global
ycc sync   --target opencode --intent plugins --plugins @prevalentware/opencode-goal-plugin --global
ycc sync   --target opencode --intent plugins --plugins oh-my-opencode-slim            # current project
ycc sync   --target opencode --intent plugins --plugins oh-my-opencode-slim --global   # user config
ycc list plugins --target claude
```

| Target   | Names                                                         | What a name selects                                                                                                                             |
| -------- | ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| claude   | `enabledPlugins` keys (`name@mkt`)                            | the `enabledPlugins` key plus its marketplace (`extraKnownMarketplaces` entry, `pluginMarketplaces` item)                                       |
| codex    | `[plugins."name@mkt"]` table names                            | that table in `~/.codex/config.toml`                                                                                                            |
| opencode | `plugins` package names (version dropped), then catalog names | that `plugins` item (`./ycc-sensitive-guard` also ships or removes its guard directory); a catalog name installs that opt-in third-party plugin |

- Entries not named are left alone, along with their state. `settings` keys in
  the same run stay whole: `--intent settings,plugins --plugins x` still merges
  every managed setting.
- Marketplaces follow their plugins and are never listed or selected on their
  own (`--plugins claude-plugins-official` is an unknown name). `remove`
  (selective or full) keeps a marketplace while an enabled plugin in your
  `settings.json` still uses it, and says so.
- `--plugins` requires the `plugins` config group: `--intent plugins` on
  `sync`/`remove`, or `install --only settings --global`.
  `--intent settings --plugins x` and `install --package … --plugins x` are
  rejected before anything is written.
- Without `--global`, the group is skipped with
  `<target>: the plugins group is global-only — skipped at project scope. Pass --global to merge it.`,
  and an explicit `--project` rejects it. opencode catalog names are the
  exception: they install into the project at default scope or `--project`.
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

### Selecting Mods

On claude, `--mods <names>` (comma-separated) narrows the `mods` step:

```bash
ycc list mods --target claude                   # what --mods accepts (status-bar)
ycc sync    --target claude --intent mods --mods status-bar
ycc install --target claude --only mods --mods status-bar
ycc remove  --target claude --intent mods --mods status-bar
```

- `--mods` registers the `ycc-mods` marketplace and installs only the named
  mods. `remove --mods` uninstalls only the named mods and keeps the `ycc-mods`
  marketplace (and says why) while another `*@ycc-mods` key is still listed in
  `enabledPlugins` in `~/.claude/settings.json`. Without `--mods`, `remove`
  uninstalls every mod and the marketplace.
- `--mods` needs the `mods` step (`--intent mods`, `--only mods`). Unknown
  names, or a run where no selected target has the step, stop before anything
  is written.

The Claude `ycc-hooks` package always installs its whole hook set; there is no
per-event selection.

### Removing Installed Config

```bash
./install.sh remove --target claude --only mcp                  # project plugin
./install.sh remove --target claude,opencode --intent mcp --global
./install.sh remove --target codex --intent settings,rules      # project settings + global rules
./install.sh remove --target codex --intent settings,plugins,rules --global
./install.sh remove --target all --intent base,settings,rules,hooks,plugins,mods
./install.sh remove --target opencode --intent agents,commands
./install.sh remove --target opencode --intent plugins --plugins oh-my-opencode-slim --purge-cache --global
```

The example removing every intent above still uses project scope for Claude
`mcp` and `hooks` and for Claude, Codex, and opencode settings; it skips the
global-only `plugins` group and Cursor and OMP settings with a notice. Global
settings and plugins need a separate `--global` run, for example
`./install.sh remove --target claude,codex,opencode --intent settings,plugins --global`
(add `./install.sh remove --target cursor,omp --intent settings --global` for
those two).

`remove` undoes any intent on any target, using the same intent → step mapping
as `sync` (an intent a target does not support is reported and skipped). It
requires `--only` or `--intent`, and rejects `--mode` and the additive
`--settings`/`--rules`/`--mcp`/`--hooks` flags. Only what the installer owns is
taken back:

| Step / intent                  | What `remove` does                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `settings`, `plugins`          | Strips repo-managed keys from the structured config (`settings.json`, `cli-config.json`, `config.toml`, `opencode.json`). List entries lose only the items the installer appended. A claude marketplace stays while an enabled plugin still uses it. opencode catalog plugins (the selected ones, else every one ycc installed) also lose their companion files when unchanged; `--purge-cache` also deletes their package cache. |
| `mcp`                          | claude: `claude plugin uninstall ycc-mcp@ycc` at the step's scope. codex: `codex plugin remove ycc-mcp@ycc`. opencode: strips managed MCP servers, including ones the repo has since dropped; servers you added are never touched.                                                                                                                                                                                                |
| `hooks` (claude)               | `claude plugin uninstall ycc-hooks@ycc` at the step's scope. At project scope, a marketplace declaration goes only as described under [Claude Project Plugins](#claude-project-plugins).                                                                                                                                                                                                                                          |
| `rules`                        | Removes the symlinks, only while they still point at this checkout. A real file you put there is never deleted.                                                                                                                                                                                                                                                                                                                   |
| claude statusline script       | Removed (with `--global` only) while identical to the repo copy; an edited copy needs `--force`.                                                                                                                                                                                                                                                                                                                                  |
| `base`                         | claude: `claude plugin uninstall ycc@ycc` + marketplace remove. codex: the `ycc@ycc` and `ycc-mcp@ycc` plugins, the `ycc` marketplace, and the custom agents ycc recorded. cursor: `agent plugin marketplace remove ycc` (uninstall the packages themselves in `/plugins`). opencode: the bundle's entries in the synced dirs. omp: the recorded installs for the scope, then the `ycc` marketplace and export once unused.       |
| `skills`, `agents`, `commands` | opencode, agents, and Codex custom agents: the standalone entries ycc recorded (or that are still identical to the bundle). Never your own entries without `--force`.                                                                                                                                                                                                                                                             |
| `mods` (claude)                | Uninstalls each mod and the `ycc-mods` marketplace. With `--mods`, only the named mods; the marketplace stays while another ycc mod is still listed in `enabledPlugins`.                                                                                                                                                                                                                                                          |

- `remove` on the `base` step of claude, codex and cursor also runs the
  [legacy cleanup](#automatic-legacy-cleanup) for that target (omp retires its
  legacy state on install, before the native packages go in).
- A managed value you edited is kept with a warning; `--force` removes it.
- `--purge-cache` is valid only with `remove`. It deletes the
  `${XDG_CACHE_HOME:-~/.cache}/opencode` `npm/`, `packages/` and `node_modules/`
  copies of each catalog plugin removed from `opencode.json`.
- A config file left empty is deleted. Codex TOML removal keeps comments,
  trusted projects and unrelated tables.

### Previewing With `--dry-run`

```bash
./install.sh sync --target claude --intent base,mcp,hooks --dry-run
./install.sh remove --target all --only settings --dry-run
./install.sh remove --target claude --intent settings,hooks,rules --dry-run
./install.sh remove --target claude,codex,opencode --only base --dry-run
```

`--dry-run` works with `install`, `sync` and `remove` and writes no config,
file, plugin install or ownership state. Each target previews the steps it can:
`settings`, `rules` and opencode `mcp` preview their managed-key and link
changes; Claude `mcp` and `hooks` print the plugin calls they would run; Cursor
`base` prints the marketplace call and the `/plugins` hint; `remove --only base`
previews on Claude, Codex and opencode; every OMP step previews itself (see the
[OMP guide](omp.md)). Each preview includes the legacy cleanup it would run.
Any step without a preview prints
`dry-run: <target> <step> step has no preview — skipped` and does not run.
Scope applies as usual: a default settings preview targets the project file and
creates no directories, and Cursor and OMP settings print the
`settings have no project scope` notice instead of a preview.

### Step Flags And Packages

`install` takes step flags instead of intents:

```bash
./install.sh install --target <claude|cursor|codex|opencode|agents|omp|all> [flags]
```

Without `--only`, the target's `base` step runs, and the additive flags run
additional steps: `--settings`, `--rules`, `--mcp`, `--hooks`. `--settings`
follows the same scope rules as the `settings` intent. `--hooks` is a boolean
on `install` only; `sync` and `remove` use `--intent hooks`.

```bash
./install.sh install --target claude --settings --rules --mcp --hooks
./install.sh install --target cursor --rules --mcp --hooks
./install.sh install --target codex --settings --rules
./install.sh install --target opencode --settings --rules
./install.sh install --target all --settings --rules --mcp
./install.sh install --target all --settings --rules --global   # new machine: user-global settings
```

Use `--only <steps>` to run exactly the listed steps and skip the default `base`
step:

```bash
./install.sh install --target claude --only rules
./install.sh install --target claude --only mcp,hooks --global
./install.sh install --target codex --only settings,rules
```

`--package <ids>` (`install` only) installs package closures from the package
model and cannot be combined with `--intent`, `--only` or the additive flags:

| Target | Accepted ids                               | Steps                                                                                                                                    |
| ------ | ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| claude | `ycc`, `ycc-mcp`, `ycc-hooks`, `ycc-all`   | `ycc` → `base`, `ycc-mcp` → `mcp`, `ycc-hooks` → `hooks`, `ycc-all` → all three, at user scope; plus the `settings` and `rules` fallback |
| codex  | `ycc`, `ycc-mcp`                           | `ycc` → `base` (`ycc@ycc` + `ycc-mcp@ycc`), `ycc-mcp` → `mcp`; plus the custom agents (local mode), `settings` and `rules`               |
| cursor | `ycc`, `ycc-rules`, `ycc-mcp`, `ycc-hooks` | every package → `base` (the `/plugins` hint names them); plus `settings`                                                                 |
| omp    | `ycc`, `ycc-mcp`, `ycc-rules`              | each package → one `omp plugin install`; `--settings` and `--rules` stay opt-in                                                          |

```bash
./install.sh install --target claude --package ycc-all
./install.sh install --target cursor --package ycc,ycc-hooks
```

A package unavailable for a target fails before any writes; `--target all`
warns and skips that target. No catalog entries are ever created.

## Source Modes

`--mode local` is the default. Claude adds this checkout as a directory
marketplace, Codex registers the checkout with `codex plugin marketplace add`,
OMP exports the checkout's packages, and opencode and agents copy the bundles.
Cursor rejects filesystem marketplaces, so it registers the published GitHub
catalog in both modes.

`--mode repo` registers the upstream GitHub repository instead of the local
checkout. It is supported by the `claude`, `codex`, `cursor` and `omp` targets:

```bash
./install.sh install --target claude --mode repo
./install.sh install --target codex --mode repo
./install.sh install --target omp --mode repo
./install.sh install --target all --mode repo
```

With `--target all --mode repo`, opencode and agents are skipped with a warning
because they have no remote-source install surface. `--target all` (any mode)
also skips omp unless `omp >= 18.12.2` is on `PATH`.

## Regenerate And Validate

When editing source-of-truth files under `ycc/`, regenerate derived bundles and
validate them before committing:

```bash
./scripts/sync.sh
./scripts/validate.sh
```

Both scripts accept `--only <targets>` for narrower runs, such as
`./scripts/sync.sh --only codex`.
