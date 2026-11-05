# opencode Install Guide

ycc installs into opencode as the npm plugin `@yandy-r/ycc-opencode`, an
OpenCode V2 plugin generated under `packages/opencode/ycc-opencode`. Its setup
hook registers the skills, agents, `/ycc:<skill>` commands, shared helpers, MCP
servers, the sensitive-file guard and the `AGENTS.md` instructions. `install.sh`
writes the one `plugins` entry that loads it, and keeps three things the
package does not carry: the managed `opencode.json` settings, the global
`AGENTS.md` link, and the opt-in catalog of third-party plugins.

The package needs opencode **>=2.0.30** (`engines.opencode`). V1 hook plugins
are not supported.

The generated settings file `.opencode-plugin/opencode.json` targets **OpenCode
V2 only**. V1 field shapes (`provider`, `agent`, `permission`, `plugin`, and
server names directly under `mcp`) are rejected by
`scripts/validate-opencode-plugin.sh`. Note that
`https://opencode.ai/config.json` still serves the V1 schema, so an editor
validating against it may flag correct V2 config; the repo validator encodes the
V2 field set from [opencode.ai/v2/docs](https://opencode.ai/v2/docs/config)
instead.

## Quick Start

From the repository root:

```bash
./install.sh install --target opencode               # this checkout's package
./install.sh install --target opencode --mode repo   # the published release
```

The `base` step merges one entry into the `plugins` list of
`~/.config/opencode/opencode.json` (always the user file):

| Mode              | Entry written                                                                                   |
| ----------------- | ----------------------------------------------------------------------------------------------- |
| `local` (default) | `file:///<checkout>/packages/opencode/ycc-opencode` (the package directory, not its `index.js`) |
| `repo`            | `@yandy-r/ycc-opencode@<version>`, pinned to this checkout's product version (lockstep)         |

In local mode the step first regenerates, validates and formats
`packages/opencode/ycc-opencode`, so the entry always loads current sources.
Repo mode skips that build and loads the release npm serves. Restart opencode
after installing or updating.

How the entry is merged:

- Any existing ycc-opencode item is replaced in place, never duplicated: another
  version, `@latest`, the bare name, an `npm:` alias, or a `file://` path to
  another ycc-opencode checkout. An object item (`{"package": …, "options": …}`)
  keeps its other keys, such as `options`.
- Every other `plugins` item is left untouched, and so is every other key.
- The file is read as JSONC, as opencode reads it.
- The installer records the hash of the item it wrote in
  `~/.config/ycc/managed-config-state.json`. A second run with nothing to change
  prints `up-to-date`.

By hand, add the same entry yourself. Pin an exact version: right after a
release the registry can briefly serve stale `latest` metadata, and the early
`0.0.0-*` placeholder versions are not loadable plugins.

```json
{
  "plugins": ["@yandy-r/ycc-opencode@X.Y.Z"]
}
```

## Add Settings And Rules

For the full opencode setup:

```bash
./install.sh sync --target opencode --intent base,settings,rules           # package + project settings + rules
./install.sh sync --target opencode --intent settings,plugins --global     # user opencode.json + plugins
```

The step-flag `install` form is equivalent:

```bash
./install.sh install --target opencode --settings --rules
./install.sh install --target opencode --settings --rules --global
```

opencode has three steps:

| Step       | Effect                                                                                                                                                                                                                               |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `base`     | Local mode: generates and validates the package. Then merges the `@yandy-r/ycc-opencode` entry into `~/.config/opencode/opencode.json` and runs the [legacy cleanup](#legacy-cleanup).                                               |
| `settings` | Merges managed keys from `.opencode-plugin/opencode.json` into `<project>/opencode.json` (default) or `~/.config/opencode/opencode.json` (`--global`), plus any [catalog plugins](#third-party-plugins) you select with `--plugins`. |
| `rules`    | Symlinks `.opencode-plugin/AGENTS.md` into `~/.config/opencode/AGENTS.md`.                                                                                                                                                           |

The `skills`, `agents`, `commands` and `mcp` intents all map to `base` on
`install` and `sync`, because those components ship only inside the package.
There is no separate MCP merge: the package registers the servers from
`mcp-configs/mcp.json` itself. See
[Project Vs Global Scope](README.md#project-vs-global-scope) and
[Removing Installed Config](README.md#removing-installed-config).

## Legacy Cleanup

Earlier releases copied `.opencode-plugin/` units into `~/.config/opencode/`
and merged MCP servers and a `./ycc-sensitive-guard` plugins item into
`opencode.json`. Those copies would shadow the package: opencode applies config
skills, agents and commands after user plugins, so a same-ID file copy wins.

The `base` step retires them automatically after it writes the entry, and
`remove --intent base` runs the same cleanup. There is no command to run by
hand. On install it runs only once `~/.config/opencode/opencode.json` actually
loads the package; otherwise it prints
`opencode file-copy install retained: … does not load @yandy-r/ycc-opencode`
and removes nothing.

| Legacy state                                                        | Removed only when                                                                                    |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Entries under `~/.config/opencode/{skills,agents,commands,shared}`  | Byte-identical to the current `.opencode-plugin/` copy, or to any version in this checkout's history |
| `~/.config/opencode/ycc-sensitive-guard`                            | Byte-identical as above, and `opencode.json` no longer loads `./ycc-sensitive-guard`                 |
| Managed `mcp.servers` entries in `~/.config/opencode/opencode.json` | The managed-config state records ycc writing them, and you have not edited them                      |
| The `./ycc-sensitive-guard` item in `plugins`                       | The managed-config state records ycc appending it                                                    |

- Edited and foreign entries stay and are reported with a
  `[!!] kept <path>: <reason>` line.
- `shared/` stays while a retained skill may still need it.
- A symlinked `~/.config/opencode` or unit directory is skipped.
- The cleanup touches the user files only; project `opencode.json` files stay.
- `--dry-run` previews it. A refusal only warns, so a kept leftover never fails
  the run; resolve it and re-run the same command.

See [Automatic Legacy Cleanup](README.md#automatic-legacy-cleanup).

## Removing

```bash
./install.sh remove --target opencode --intent base                 # the plugins entry + legacy cleanup
./install.sh remove --target opencode --intent settings,rules --global
```

- `remove --intent base` takes back only the entry ycc recorded writing, or the
  exact entry this checkout would write. Any other ycc-opencode entry is kept
  with `not written by ycc (re-run with --force to remove it)`; `--force` takes
  it too. A file left empty is deleted.
- `remove --intent skills`, `agents`, `commands` or `mcp` removes nothing. It
  prints one notice that those components ship inside `@yandy-r/ycc-opencode`
  and that `remove --intent base` drops the whole package entry.

## Settings Scope

The `settings` step defaults to `<project>/opencode.json`, which opencode
merges above `~/.config/opencode/opencode.json`. The project file gets every
managed settings key (`$schema`, `model`, `agents`, `providers`,
`experimental.subagent_depth`) plus any
[third-party catalog plugins](#third-party-plugins) you select. The bundle
`plugins` items stay global-only: `--intent plugins` without `--global` skips
them with a notice. The `@yandy-r/ycc-opencode` entry is not a settings key;
the `base` step always writes it into the user file.

`opencode.json` at the project root is usually committed, so its values apply
to everyone who works in the repository and override their own global model
choices. Review the diff before committing, or keep these preferences global
with `--global`. From `$HOME` a default run skips the step with a notice.

> **Behavior change:** `settings` used to write only
> `~/.config/opencode/opencode.json`. Pass `--global` to keep that; a defaulted
> run warns while the user file still holds ycc-managed keys.

## Global Rules

opencode loads `~/.config/opencode/AGENTS.md`; see the
[official rules guide](https://opencode.ai/docs/rules). The generated bundle copies
the tool-neutral source `ycc/settings/rules/CLAUDE.md` verbatim after a generated
header, without filename or runtime substitutions. The `rules` step refuses to
replace a real user rules file without `--force`. No additional global filename
is linked. This is distinct from repo-local `AGENTS.md` loading and Claude
compatibility fallbacks.

The package delivers the same text through its `context` hook, and skips it
when the request already carries it, so linking the file never injects the
rules twice. Without `--rules` the package alone delivers them.

## Plugins

The generated `opencode.json` declares the bundle's shared OpenCode V2 plugins in
`plugins` (the `settings` step's `plugins` group):

| Plugin                                | Purpose                                                                      |
| ------------------------------------- | ---------------------------------------------------------------------------- |
| `@prevalentware/opencode-goal-plugin` | Goal mode — `/goal` commands, persistent goal state, and the goal tool suite |

The `@yandy-r/ycc-opencode` entry is not part of this group. The `base` step
owns it with its own ownership state, so `--intent plugins` never adds or
removes it.

`--settings --global` installs the server-side half. On opencode v2.0.x the TUI half
(sidebar goal indicator and command-palette entry) was read from the global
`~/.config/opencode/cli.json`, which this repository does not manage. On opencode
v2.1.1, `opencode plugin add` writes only the `opencode.json` `plugins` entry and
the V2 CLI loads TUI halves from `opencode.json` (verified with the catalog's
`oh-my-opencode-slim`). Install both halves on a new machine with:

```bash
./install.sh install --target opencode --settings --rules --global
opencode2 plugin add @prevalentware/opencode-goal-plugin
```

`opencode2 plugin add` is idempotent. Verify with `opencode2 plugin list`. Use
`opencode` instead of `opencode2` when the V2 binary is installed under that name.

The V2 `plugins` array is the correct key (the V1 singular `plugin` key is
rejected). The plugin API spike ran on opencode **v2.0.29**, and the package
declares an `engines.opencode` floor of **>=2.0.30**, the version its package
smoke targets; other versions are unverified. See the
[v6 opencode reference](v6/opencode.md) for the package contract and its
publication evidence.

`--plugins` selects `plugins` items by package name without the version
(`ycc list plugins --target opencode`); only the named items are merged or
removed, and your own items stay:

```bash
ycc sync   --target opencode --intent plugins --plugins @prevalentware/opencode-goal-plugin --global
ycc remove --target opencode --intent plugins --plugins @prevalentware/opencode-goal-plugin --global
```

When the bundle bumps a plugin's version, the item the installer added is
replaced in place instead of duplicated; an item with the same package name
that you wrote yourself is kept with a warning (`--force` replaces it). See
[Selecting Plugins](README.md#selecting-plugins).

### Third-party plugins

Besides the bundle plugins, ycc ships an opt-in catalog of pinned third-party
opencode plugins in `ycc/settings/opencode-plugins.json`. Every entry is off by
default: `--intent plugins` alone never installs one, and only `--plugins <name>`
does. `ycc list plugins --target opencode` lists the catalog names after the
bundle names.

| Plugin                | Package                     | What ycc manages                                                                                                                 |
| --------------------- | --------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `oh-my-opencode-slim` | `oh-my-opencode-slim@3.0.5` | the pinned `plugins` item, `agents.explore.disabled` and `agents.general.disabled`, and the companion `oh-my-opencode-slim.json` |

```bash
ycc sync   --target opencode --intent plugins --plugins oh-my-opencode-slim --global
ycc remove --target opencode --intent plugins --plugins oh-my-opencode-slim --purge-cache --global
```

Sync merges, for each selected catalog plugin:

- the exact-pinned `plugins` item;
- the entry's managed keys. slim drops opencode's built-in `general` and `explore`
  subagents unless the config declares them, and the ycc bundle declares their
  models, so the catalog sets `agents.{general,explore}.disabled: true`;
- its companion config files, copied beside `opencode.json` and owned by hash
  (`opencode-plugin-files.json` beside the managed-config state). A file that
  already equals ycc's copy is adopted; a companion you edited is kept with a
  warning, and `--force` replaces it. When the catalog bumps a version, a
  companion ycc wrote is updated in place.

Each catalog plugin has its own ownership state, and it owns its managed keys
per leaf. slim owns `agents.general.disabled`, while the bundle owns
`agents.general.model` in the same entry. So installing or removing a catalog
plugin never touches another catalog plugin or the bundle's leaves, and the
bundle's own remove still takes its leaves back cleanly. A run of catalog names
only leaves the bundle `plugins` items alone; a mixed selection
(`--plugins @prevalentware/opencode-goal-plugin,oh-my-opencode-slim`) merges
both.

Sync then prints the plugin's manual follow-ups. ycc never automates them:

- slim enables LSP when no `lsp` key exists. ycc leaves `lsp` alone; set
  `"lsp": true` in `opencode.json` if you want it.
- For background subagents and web search, add
  `export OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true` and
  `export OPENCODE_ENABLE_EXA=1` to your shell rc.

Remove takes back the item and the managed leaves when they are unchanged since
ycc wrote them. It deletes a companion only when ycc recorded writing it and the
file is unchanged. It prints the rc lines (and `lsp`) you may delete. With
`--plugins` it acts on the named catalog plugins; without it
(`remove --intent plugins` or `--only settings`) it acts on every catalog
plugin ycc recorded installing into that `opencode.json` and skips the rest, so
a plugin you set up yourself keeps its item, its `agents` keys, its companion
(even one identical to ycc's copy, such as slim's own installer output) and its
cache. While `opencode.json` still loads the plugin
(an item you wrote yourself, read as JSONC like opencode does), remove keeps
its companion and its cache. `--purge-cache` (remove only) also deletes the
plugin's opencode package cache under `${XDG_CACHE_HOME:-~/.cache}/opencode`:
the V2 `npm/<pkg>@<spec>/`, the V1 `packages/<pkg>@<spec>/`, and the legacy
`node_modules/<pkg>`. It refuses any path that resolves outside that directory.

Without `--global` (or with an explicit `--project`) catalog plugins install
into the current project instead: `<project>/opencode.json`, with companions in
`<project>/.opencode/` (where slim looks for its project override). Project
scope takes catalog plugins only: an explicit `--project` rejects bundle
plugins and a `plugins` run without catalog `--plugins` (the bundle plugins
are global-only), while the default scope skips those with a notice. Project
settings keys may ride along in the same run:

```bash
ycc sync   --target opencode --intent plugins --plugins oh-my-opencode-slim
ycc sync   --target opencode --intent settings,plugins --plugins oh-my-opencode-slim --project
ycc remove --target opencode --intent plugins --plugins oh-my-opencode-slim --project
```

ycc does not run a plugin's upstream installer (slim's sets `lsp` and offers
shell-rc exports) and writes no `tui.json`. `tui.json` (singular `plugin`) is the
V1 layer, and on opencode v2.1.1 `opencode plugin add` writes only
`opencode.json`, from which V2 also loads TUI halves. The bundle is V2-only.

### Sensitive-file guard

Some specialists must never handle secret-bearing files: `pr-comment-fixer`,
`release-fix-applier`, `backport-conflict-resolver`, `review-fixer`, and
`db-modifier`. The list of agents and path patterns (`.env` and variants other than
`*.env.example`, keys and certificates, `credentials.json`, `.ssh/`, `.aws/`,
`.kube/config`, `.netrc`, and similar) lives in
[`ycc/settings/sensitive-files.json`](../../ycc/settings/sensitive-files.json).
Three layers enforce it, all shipped inside `@yandy-r/ycc-opencode`:

- **Native rules.** The generated agent `permissions` end with `read` and `edit`
  denies for those paths, and their shell allowlists contain no general
  file-printing commands such as `cat`. The `*.env.example` exception lifts
  only the `.env` patterns, so a key file such as `id_rsa.env.example` stays
  denied. `git diff --no-index` is denied for every restricted agent.
- **Guard plugin.** The package's `ycc-sensitive-guard/` module, registered
  from the package's own setup (no separate `plugins` entry). For the
  restricted agents it resolves paths against the calling session's directory
  (not the server's; when neither can be determined, the call is rejected) on `read`, `edit`, `write`, `patch`,
  `grep`, `glob`, and `shell` calls, following symlinks (including links whose
  target does not exist yet) and the `read` tool's look-alike file-name
  fallback. It rejects calls that name a sensitive path (including git object
  names such as `HEAD:.env`), shell commands it cannot resolve to file names
  (brace expansion, any `$` expansion or backtick substitution such as `$HOME`,
  `${PWD}`, `$(…)` and `$'…'`, tilde prefixes other than `~/` such as `~user`,
  `~+` and `~-`, and `git diff --no-index`), and `git` commands
  that leave the session directory (a path argument or working directory
  outside it, `-C`, `-c`, `--git-dir`, `--work-tree`, or `GIT_*` variables), and
  removes sensitive files from `grep` and `glob` results. Other agents are unaffected.
- **Guarded search.** Built-in `grep` and `glob` permissions match the search
  pattern, not a file path, so native path rules cannot restrict them. The
  restricted agents are therefore not granted `grep` or `glob`. They are granted
  `ycc_grep` and `ycc_glob`, which only the guard plugin provides, and the
  agents see them under the usual `grep`/`glob` names. Each call is first
  checked against the calling agent's own rules: its `ycc_grep`/`ycc_glob`
  permission, and an `external_directory` approval for a search root outside
  the session's directory. The guard then applies its path checks, runs the
  built-in search, and filters the results. The built-in runs as a hidden
  internal agent, `ycc-sensitive-search`, whose rules allow only searching.
  The guard rejects any tool call a session running as that agent makes
  itself. Without the guard, a restricted agent has no search tool at all.
- **Host rules cannot loosen the restricted agents.** OpenCode appends your
  own top-level `permissions` after a package agent's rules, and the last
  matching rule wins. The package therefore re-applies each restricted
  agent's packaged rules on top of the host's decision:
  - A permission request that the packaged rules deny for any resource is
    denied, even with a user-global `read * allow`, `shell * allow`, or
    `* * allow`.
  - A tool whose permission the packaged rules deny outright is not offered to
    the agent, and a call to it is rejected. This also covers tools that never
    request a permission.
  - A restricted agent still asks before it reaches a directory outside the
    project, even with a host-wide `external_directory` allow. A directory
    you approved with "always" is not asked again, also after a restart.
  - The package never loosens a decision, and it turns an allow into a prompt
    only for `external_directory`. Your rules can still make a restricted
    agent stricter.

  OpenCode does not tell plugins which approvals are saved, so the package
  asks OpenCode each time: it creates a short-lived child session, checks the
  directory there against your saved approvals only, and removes the session
  again. The check never prompts. Removing a saved approval in OpenCode
  therefore takes effect at once, and approvals saved before the package was
  installed or loaded are honoured. The same check also asks about a
  directory that no approval should cover. If another plugin approves every
  request automatically, or a saved approval covers `/`, that answer is allow
  too, and the restricted agent asks you instead.

Keep the package entry in your `opencode.json`. A project config that removes
the guard plugin (`"plugins": ["-yandy-r.ycc-sensitive-guard"]`), or a guard
that fails to load, leaves the native rules and the permission floor; the
restricted agents then lose search instead of gaining unguarded search, and
an explicit `grep`/`glob` allow in your own config stays denied. The guard
checks the text of each shell command, so some allowed commands stay outside
it, with or without the guard:

- The fixer specialists (`pr-comment-fixer`, `review-fixer`,
  `release-fix-applier`) may run only their listed type-check, test, and build
  commands, such as `pnpm typecheck`, `pytest`, `cargo check`, or
  `go vet ./...`, plus `ls` and `test` for `review-fixer` and
  `release-fix-applier` and the read-only git commands for `review-fixer`.
  Native rules deny every other shell command, including
  interpreter one-liners, with or without the guard. Those runners still accept
  options and execute project code and config (tests, package scripts,
  `build.rs`) that the agent can edit.
- `db-modifier` runs `psql` and `supabase`, which are interpreters by
  function and can read any file they are pointed at.
- Read-only git history commands print committed file contents without naming
  the file. `backport-conflict-resolver` may run `git show`, `git log`,
  `git blame`, and `git diff`, and `review-fixer` may run `git log` and
  `git diff`. A history-wide `git log -p` or `git show <commit>` can therefore
  show a secret that was once committed.

Maintainers can exercise the guard on an isolated host with
`scripts/test-opencode-sensitive-guard.sh`. It covers the npm package with and
without the guard under host-wide allow rules, guarded search outside the
project under a host-wide external-directory allow, and the standalone guard
module in the shape older file-copy installs loaded (including a lab where both
load). This opt-in check is not part of `validate.sh`.

## Selective Steps

Use `--only` to run exactly the listed steps:

```bash
./install.sh install --target opencode --only base                        # the plugins entry only
./install.sh install --target opencode --only base --mode repo            # pin the published release
./install.sh install --target opencode --only settings                    # <project>/opencode.json
./install.sh install --target opencode --only settings --global           # ~/.config/opencode/opencode.json
./install.sh install --target opencode --only rules
./install.sh install --target opencode --only settings,rules --global
./install.sh remove  --target opencode --only base                        # take the entry back
```

`--only` accepts `base`, `settings` and `rules`. `--only skills`, `agents` or
`commands` is skipped with a notice. `--skills` and `--with-deps` narrow only
the `agents` target; on opencode alone they are an error, and next to `agents`
opencode skips them with one notice.

## Installed Surfaces

| Surface                               | Location                                                                            |
| ------------------------------------- | ----------------------------------------------------------------------------------- |
| Skills, agents, commands, shared, MCP | Registered by `@yandy-r/ycc-opencode` (entry in `~/.config/opencode/opencode.json`) |
| Sensitive-file guard, instructions    | Registered by the package (guard module, `context` hook)                            |
| Settings and bundle plugins           | `<project>/opencode.json` or `~/.config/opencode/opencode.json`                     |
| Rules                                 | `~/.config/opencode/AGENTS.md` (`--rules`)                                          |

Nothing is copied into `~/.config/opencode/{skills,agents,commands,shared}`. Skill
scripts and shared helpers render into a temporary tree at plugin setup, so
their shell snippets run from any working directory.

Rules reach the model through `~/.config/opencode/AGENTS.md`, which V2 loads
first as the global instructions file, and through the package's context hook.
V2 also resolves the config's `instructions` array, but the bundle deliberately
leaves it out. A relative entry such as `AGENTS.md` would resolve from the
workspace and load the project's AGENTS.md a second time.

Invoke skills with the built-in `skill` tool, agents with `@agent-name` mentions
or the native v2 `subagent(agent, description, prompt, sessionID?, background?)`
tool, and commands as `/ycc:<skill>` in the TUI.

Commands are generated from public skills (`user-invocable` not `false`), one
per skill, and namespaced `ycc:` so they never collide with a host built-in
such as `/init` or with your own bare `/<skill>` commands. Each command has no
workflow body of its own: it tells the agent to load the matching skill with the
`skill` tool and passes `$ARGUMENTS` through. Do not chain commands into other
commands; skill logic stays in `SKILL.md`.

A same-ID skill, agent or command in your own `~/.config/opencode` or a
project's `.opencode/` replaces the package definition (agents field-blend over
it), and a config MCP server with the same name wins. Remove stale copies by
hand if the legacy cleanup kept them as edited.

## Model Configuration

The generated `opencode.json` sets the bundle's main model, its reasoning
effort, and a `#subagent` variant carrying the sub-agent reasoning effort.
Beyond that root model, every agent under `ycc/agents/` (plus the built-in
`general` and `explore` subagents) gets its **own** explicit model assignment
in the generated `agents` block — not just `general`/`explore` on the
`#subagent` variant. Assignments are tiered by intended capability:

| Tier                          | Sample Model           | Intended Roles                                                                                                           |
| ----------------------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Deep architecture / high-risk | `openai/gpt-6-astra`   | e.g. `architect`, `code-architect`, `root-cause-analyzer`, `db-modifier`, `go-expert-architect`, `rust-expert-architect` |
| Docs / lookup / routine       | `openai/gpt-5.6-terra` | e.g. `docs-git-committer`, `code-finder`, `api-documenter`, `documentation-writer`, `readme-generator`                   |
| Everything else               | `openai/gpt-5.6-sol`   | General implementation, review, and specialty agents                                                                     |

**These values are placeholders.** Unlike Claude and Codex, opencode's usable
catalog depends on which provider subscriptions and models you have configured,
so the bundle ships portable defaults rather than fixed models. Change the
preferred models in [`ycc/settings/models.json`](../../ycc/settings/models.json)
(`targets.opencode.main`, `.subagent`, and `.agents`), or simply edit your own
`~/.config/opencode/opencode.json` — the merge keeps local model choices and
provider credentials instead of overwriting them.

`scripts/generate_opencode_plugin.py` fails fast if any agent under `ycc/agents/`
(or the built-ins) is missing from `targets.opencode.agents`, so the mapping in
`models.json` must stay in sync whenever agents are added, renamed, or removed
(see `CONTRIBUTING.md` → Adding, Renaming, or Removing Agents).

## Runtime Settings

The generated config sets the experimental subagent depth:

```json
{
  "experimental": {
    "subagent_depth": 2
  }
}
```

The V2 docs do not describe this field, so its detailed runtime semantics are
not documented here. Change it in `scripts/generate_opencode_plugin.py`
(`DEFAULT_SUBAGENT_DEPTH`) or override it in your own
`~/.config/opencode/opencode.json`.

## Hooks

opencode hook guidance is otherwise advisory in this bundle. The only shipped
lifecycle plugin is the sensitive-file guard inside `@yandy-r/ycc-opencode`
(see [Sensitive-file guard](#sensitive-file-guard)).

## Regenerate Only opencode Artifacts

After editing source files under `ycc/`, regenerate opencode artifacts directly
or through the unified sync script:

```bash
./scripts/sync.sh --only opencode
./scripts/validate.sh --only opencode
```
