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
with `install.sh`. Package IDs, the catalog shape and tested versions are in
the [Codex package reference](v6/codex.md).

From a checkout, one command installs both plugins and the custom agents:

```bash
./install.sh install --target codex
```

The default `base` step generates and validates the Codex bundle, syncs custom
agents into `~/.codex/agents/`, registers this checkout as the Codex marketplace
`ycc` (`codex plugin marketplace add`), and installs + enables `ycc@ycc` and
`ycc-mcp@ycc` with `codex plugin add`. It then runs the
[legacy cleanup](README.md#automatic-legacy-cleanup), which retires what older
installers wrote (the `ycc@local-ycc-plugins` install, its links, cache and
catalog entry, `~/.codex/skills` copies, and merged `[mcp_servers.*]` tables)
and always keeps `~/.codex/agents/`.

The Codex CLI 0.160 or later is required. A missing or older `codex` CLI is an
error; the installer never copies plugin snapshots itself. Codex snapshots each
plugin into `~/.codex/plugins/cache/ycc/<package>/<version>/`, so rerun the
base step after regenerating the bundle.

Restart Codex after the install.

## Add Settings And Rules

For the full local Codex setup:

```bash
./install.sh sync --target codex --intent base,settings,rules           # project settings
./install.sh sync --target codex --intent settings,plugins --global      # user config.toml + plugins
```

The step-flag `install` form is equivalent:

```bash
./install.sh install --target codex --settings --rules
./install.sh install --target codex --settings --rules --global
```

Step behavior:

| Step       | Effect                                                                                                                                                                                                                                                                                                     |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `base`     | Generates and validates the Codex bundle, syncs custom agents from `.codex-plugin/agents/` into `~/.codex/agents/` (local mode; your own agents stay), registers the Codex marketplace `ycc`, installs + enables `ycc@ycc` and `ycc-mcp@ycc`, then runs the legacy cleanup. The `skills` intent maps here. |
| `agents`   | Generates the custom agents and installs each into `~/.codex/agents/<name>.toml`, leaving your own agents alone. Always the full set.                                                                                                                                                                      |
| `mcp`      | `codex plugin add ycc-mcp@ycc` (user scope only; `--project` is an error).                                                                                                                                                                                                                                 |
| `settings` | Default (project): merges the preference keys from `.codex-plugin/config/config.toml` into `<project>/.codex/config.toml`. With `--global`: merges every managed key into `~/.codex/config.toml`. Plugin enablement lives in the same file, so the `plugins` intent also maps here (`--global` only).      |
| `rules`    | Symlinks `.codex-plugin/config/default.rules` and `AGENTS.md` into `~/.codex/`; Codex reads `AGENTS.md`, not `CLAUDE.md`.                                                                                                                                                                                  |

Settings merge without rewriting the rest of TOML: comments, local trusted
projects, account-specific connectors, tokens, and unknown tables stay intact.
Managed defaults are `gpt-6-astra` at Medium effort for the main agent and
`gpt-5.6-sol` at High effort for spawned agents (`[agents]` defaults). `--rules`
symlinks the global rules so edits stay live.

## Settings Scope

The `settings` step defaults to `<project>/.codex/config.toml`, which Codex
layers above `~/.codex/config.toml` and loads **only when the project is
trusted** in `~/.codex/config.toml` (`[projects."<path>"] trust_level`). The
installer warns when it writes the file and never writes trust entries: trust
stays your decision.

The project file carries preference keys only: `personality`, `model`,
`model_reasoning_effort`, `model_context_window`,
`model_auto_compact_token_limit`, `plan_mode_reasoning_effort`,
`service_tier`, `[agents]` and `[features]`. Approval and sandbox keys
(`approval_policy`, `approvals_reviewer`, `sandbox_mode`,
`[sandbox_workspace_write]`) and `[plugins.*]` stay global, so a committed
project file never widens anyone's approval or sandbox posture. Keys Codex
ignores at project level (provider, auth, profile, `notify`, `otel`) are never
written there.

`.codex/config.toml` is usually committed and applies to everyone who trusts
the project. Review the diff before committing, or keep these preferences
global with `--global`. From `$HOME` (where the project file would be the user
file) a default run skips the step with a notice. A defaulted run warns while
`~/.codex/config.toml` still holds ycc-managed keys. See
[Project Vs Global Scope](README.md#project-vs-global-scope).

## Global Rules

Codex loads global instructions from `~/.codex/AGENTS.md` (or an
`AGENTS.override.md` under `CODEX_HOME`); see the
[official AGENTS.md guide](https://learn.chatgpt.com/docs/agent-configuration/agents-md).
The installer uses the default home path, links the complete tool-neutral body
as `AGENTS.md`, and does not alter overrides. `default.rules` is separate command
approval policy. `CLAUDE.md` is not a native global filename: no new link is made.
Existing older links stay in place until `remove --intent rules`, which removes
only links owned by this checkout, never real files or foreign links.

## Local Vs Repo Mode

Local mode is the default and is best for contributors:

```bash
./install.sh install --target codex --mode local
```

Local mode runs `codex plugin marketplace add <this checkout>`, installs
`ycc@ycc` and `ycc-mcp@ycc` from the checkout's `.codex-plugin/ycc` and
`.codex-plugin/ycc-mcp`, and syncs the custom agents into `~/.codex/agents/`.

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
repository. Repo mode skips local generation and does not sync custom agents;
add `--only agents` (or run local mode) for those.

## Selective Steps

Use `--only` to run exactly the listed steps:

```bash
./install.sh install --target codex --only base
./install.sh install --target codex --only agents                  # just ~/.codex/agents
./install.sh install --target codex --only settings                # <project>/.codex/config.toml
./install.sh install --target codex --only settings --global       # ~/.codex/config.toml
./install.sh install --target codex --only rules
./install.sh install --target codex --only mcp                     # ycc-mcp@ycc
./install.sh remove  --target codex --only mcp                     # codex plugin remove ycc-mcp@ycc
```

The selection flags (`--skills`, `--with-deps`) narrow only the `agents`
target and do not apply to Codex: `ycc@ycc` and `ycc-mcp@ycc` install whole,
and the custom agents always ship as the full set.
See [Project Vs Global Scope](README.md#project-vs-global-scope) and
[Removing Installed Config](README.md#removing-installed-config).

If you clear `~/.codex/plugins/cache/`, rerun the base step so
`codex plugin add` re-creates the snapshots:

```bash
./install.sh install --target codex --only base
```

`remove --target codex --only base` removes `ycc@ycc`, `ycc-mcp@ycc`, the `ycc`
marketplace, and only the custom agents ycc recorded in
`~/.config/ycc/installed-units.json`. Your own agents and edited copies stay.

## Codex Desktop

Codex Desktop uses the same installed plugin and custom-agent locations when it
reads the standard Codex config directories:

| Surface                      | Location                                          |
| ---------------------------- | ------------------------------------------------- |
| Native plugin cache          | `~/.codex/plugins/cache/ycc/<package>/<version>/` |
| Marketplace registration     | `[marketplaces.ycc]` in Codex CLI state/config    |
| Plugin enablement and config | `~/.codex/config.toml`                            |
| Custom agents                | `~/.codex/agents/`                                |

Recommended desktop install (user-global settings, so every project gets them):

```bash
./install.sh install --target codex --mode repo --settings --rules --global
```

Then restart Codex Desktop. The `ycc` and `ycc-mcp` plugins from the `ycc`
marketplace appear in the desktop app's plugin UI or `/plugins` surface.

For contributor/local desktop testing, use local mode instead:

```bash
./install.sh install --target codex --settings --rules --global
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
  `SKILL.md`.
- Agent shell scope is not enforced on Codex. A custom agent cannot narrow the
  shell to a command list: it inherits the parent session's sandbox, approval
  policy and command rules, and can only turn the shell off entirely. The fixer
  agents (`pr-comment-fixer`, `review-fixer`, `release-fix-applier`) need their
  type-check and build commands, so their allowlist is a prompt instruction
  here. Run them under a sandbox and approval policy you trust. OpenCode and OMP
  enforce the same lists natively.
