# Codex Install Guide

This guide covers Codex plugin installs, Codex custom agents, and Codex Desktop.

## Quick Start

The Codex marketplace `ycc` lists two packages: `ycc` (skills and shared
helpers) and `ycc-mcp` (MCP server connections). With Codex 0.160+, install
them straight from the published repository:

```bash
codex plugin marketplace add https://github.com/yandy-r/ystack.git
codex plugin add ycc@ycc
codex plugin add ycc-mcp@ycc
```

Pin a commit with `--ref <sha>` on the `marketplace add` command. Codex plugins
cannot carry custom agents, `AGENTS.md`, or `config.toml` settings; those stay
with `install.sh`. The per-package guide is
[Codex native packages](v6/codex.md).

From a checkout, one command installs both plugins and the custom agents:

```bash
./install.sh install --target codex
```

The default `base` step generates and validates the Codex bundle, syncs custom
agents into `~/.codex/agents/`, registers this checkout as the Codex marketplace
`ycc` (`codex plugin marketplace add`), and installs + enables `ycc@ycc` and
`ycc-mcp@ycc` with `codex plugin add` (Codex 0.160+). Codex snapshots each
plugin into `~/.codex/plugins/cache/ycc/<package>/<version>/`, so rerun the base
step after regenerating the bundle.

An older install that used the `local-ycc-plugins` marketplace
(`ycc@local-ycc-plugins`) is left untouched. Preview and then apply
[`./install.sh migrate --target codex`](README.md#migrating-to-native-packages)
to retire it; `~/.codex/agents/` is always kept.

Restart Codex after the install.

## Add Settings And Rules

For the full local Codex setup:

```bash
./install.sh sync --target codex --intent base,settings,mcp,plugins,rules
```

The step-flag `install` form is equivalent:

```bash
./install.sh install --target codex --settings --rules
```

Step behavior:

| Step       | Effect                                                                                                                                                                                                                                                                                                                                                             |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `base`     | Generates and validates the Codex bundle, syncs custom agents from `.codex-plugin/agents/` into `~/.codex/agents/` (local mode; your own agents stay), registers the Codex marketplace `ycc`, and installs + enables `ycc@ycc` and `ycc-mcp@ycc`. Repo mode registers the Git marketplace and skips the agent sync. See [Local Vs Repo Mode](#local-vs-repo-mode). |
| `skills`   | Generates the skills and installs each into `~/.codex/skills/<name>` (helpers in `~/.codex/skills/_shared`), with plugin paths re-pointed. No plugin link, cache or marketplace entry.                                                                                                                                                                             |
| `agents`   | Generates the custom agents and installs each into `~/.codex/agents/<name>.toml`, leaving your own agents alone.                                                                                                                                                                                                                                                   |
| `settings` | Merges managed keys from `.codex-plugin/config/config.toml` into `~/.codex/config.toml`. Plugin enablement lives in the same file, so the `plugins` intent also maps here.                                                                                                                                                                                         |
| `mcp`      | Merges `[mcp_servers.*]` from `.codex-plugin/config/config.toml` into `<project>/.codex/config.toml` (or `~/.codex/config.toml` with `--global`).                                                                                                                                                                                                                  |
| `rules`    | Symlinks `.codex-plugin/config/default.rules` and `AGENTS.md` into `~/.codex/`; Codex reads `AGENTS.md`, not `CLAUDE.md`.                                                                                                                                                                                                                                          |

Settings merge without rewriting the rest of TOML: comments, local trusted
projects, account-specific connectors, tokens, and unknown tables stay intact.
Managed defaults are `gpt-6-astra` at Medium effort for the main agent and
`gpt-5.6-sol` at High effort for spawned agents (`[agents]` defaults). `--rules`
symlinks the global rules so edits stay live.

## Global Rules

Codex loads global instructions from `~/.codex/AGENTS.md` (or an
`AGENTS.override.md` under `CODEX_HOME`); see the
[official AGENTS.md guide](https://learn.chatgpt.com/docs/agent-configuration/agents-md).
The installer uses the default home path, links the complete tool-neutral body
as `AGENTS.md`, and does not alter overrides. `default.rules` is separate command
approval policy. `CLAUDE.md` is not a native global filename: no new link is made.
Existing legacy links stay in place until `remove --intent rules`, which removes
only links owned by this checkout, never real files or foreign links.

## Local Vs Repo Mode

Local mode is the default and is best for contributors:

```bash
./install.sh install --target codex --mode local
```

Local mode runs `codex plugin marketplace add <this checkout>`, installs
`ycc@ycc` and `ycc-mcp@ycc` from the checkout's `.codex-plugin/ycc` and
`.codex-plugin/ycc-mcp`, and syncs the custom agents into `~/.codex/agents/`.
Codex snapshots each plugin into
`~/.codex/plugins/cache/ycc/<package>/<version>/`. When the Codex CLI predates
the plugin commands (before 0.160), the installer copies the same snapshots and
writes `[marketplaces.ycc]` to `~/.codex/config.toml` itself.

After editing source files under `ycc/`, regenerate the Codex bundle and rerun
the base step to refresh the snapshots:

```bash
./scripts/sync.sh --only codex
./install.sh install --target codex --only base
```

Repo mode registers the published Git marketplace instead — Codex clones
`https://github.com/yandy-r/ystack.git` at `main`
(`codex plugin marketplace add https://github.com/yandy-r/ystack.git --ref main`)
and installs the same two packages from it:

```bash
./install.sh install --target codex --mode repo
```

Use repo mode for non-developer installs that should track the published
repository. Repo mode does not sync custom agents on its own; add
`--only agents` (or run local mode) for those. Without the Codex plugin CLI,
repo mode falls back to this checkout's snapshot rather than fetching `main`.

## Selective Steps

Use `--only` to run exactly the listed steps:

```bash
./install.sh install --target codex --only base
./install.sh install --target codex --only settings
./install.sh install --target codex --only rules
./install.sh install --target codex --only settings,rules
./install.sh install --target codex --only mcp                   # <project>/.codex/config.toml
./install.sh install --target codex --only mcp --global          # ~/.codex/config.toml
./install.sh remove --target codex --only mcp --global   # remove managed servers
```

Codex loads a project `.codex/config.toml` only when the project is trusted in
`~/.codex/config.toml`. MCP servers moved from the `settings` step to the `mcp`
step; pass `--global` to keep writing the user config. See
[Project Vs Global Scope](README.md#project-vs-global-scope) and
[Removing Installed Config](README.md#removing-installed-config).

If you clear `~/.codex/plugins/cache/`, rerun the base step so
`codex plugin add` re-creates the snapshots:

```bash
./install.sh install --target codex --only base
```

Leftovers from a pre-v6 install (`ycc@local-ycc-plugins`, the
`~/.codex/plugins/ycc/` link, the cache under
`~/.codex/plugins/cache/local-ycc-plugins/ycc`, and
`~/.agents/plugins/marketplace.json` entries) are not touched by `install`.
Retire them with
[`migrate --target codex`](README.md#migrating-to-native-packages).

## Codex Desktop

Codex Desktop uses the same installed plugin and custom-agent locations when it
reads the standard Codex config directories:

| Surface                      | Location                                          |
| ---------------------------- | ------------------------------------------------- |
| Native plugin cache          | `~/.codex/plugins/cache/ycc/<package>/<version>/` |
| Marketplace registration     | `[marketplaces.ycc]` in Codex CLI state/config    |
| Plugin enablement and config | `~/.codex/config.toml`                            |
| Custom agents                | `~/.codex/agents/`                                |

Recommended desktop install:

```bash
./install.sh install --target codex --mode repo --settings --rules
```

Then restart Codex Desktop. The `ycc` and `ycc-mcp` plugins from the `ycc`
marketplace appear in the desktop app's plugin UI or `/plugins` surface.

For contributor/local desktop testing, use local mode instead:

```bash
./install.sh install --target codex --settings --rules
```

After local source edits, run `./scripts/sync.sh --only codex`, rerun the base
step, then restart or reload Codex Desktop.

If Codex Desktop does not show `ycc`, confirm it is using the same `~/.codex/`
directory as the Codex CLI/TUI.

## Codex Notes

- Codex support is native. Skills and shared helpers ship as the `ycc` Codex
  plugin, MCP server connections as `ycc-mcp`, and agents are emitted as Codex
  custom-agent TOMLs installed by `install.sh`.
- Codex does not install this repository's custom slash-command layer. Use the
  bundled skills directly and Codex built-ins such as `/plan` and `/review`.
- Native `ycc@ycc` skill bodies resolve bundled paths relative to each
  `SKILL.md`. The `~/.codex/plugins/ycc/` symlink and the `local-ycc-plugins`
  marketplace belong to pre-v6 installs; `./install.sh migrate --target codex`
  retires them.
- Agent shell scope is not enforced on Codex. A custom agent cannot narrow the
  shell to a command list: it inherits the parent session's sandbox, approval
  policy and command rules, and can only turn the shell off entirely. The fixer
  agents (`pr-comment-fixer`, `review-fixer`, `release-fix-applier`) need their
  type-check and build commands, so their allowlist is a prompt instruction
  here. Run them under a sandbox and approval policy you trust. OpenCode and OMP
  enforce the same lists natively.
