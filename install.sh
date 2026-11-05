#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# install.sh — sync plugin assets to target IDE config directories
# ---------------------------------------------------------------------------

# Resolve symlinks so the linked `ycc` command (see 'cli') still finds the repo.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CLI_NAME="ycc"
# shellcheck disable=SC2034  # read by steps.sh (target resolution).
ALL_TARGETS=(claude cursor codex opencode agents omp)

# shellcheck source=scripts/lib/install/core.sh
source "${SCRIPT_DIR}/scripts/lib/install/core.sh"
# shellcheck source=scripts/lib/install/steps.sh
source "${SCRIPT_DIR}/scripts/lib/install/steps.sh"
# shellcheck source=scripts/lib/install/select.sh
source "${SCRIPT_DIR}/scripts/lib/install/select.sh"
# shellcheck source=scripts/lib/install/bundle.sh
source "${SCRIPT_DIR}/scripts/lib/install/bundle.sh"
# shellcheck source=scripts/lib/install/cli.sh
source "${SCRIPT_DIR}/scripts/lib/install/cli.sh"
# shellcheck source=scripts/lib/install/cleanup.sh
source "${SCRIPT_DIR}/scripts/lib/install/cleanup.sh"
# Each target implements the contract described in its targets/<t>.sh header.
for _target in "${ALL_TARGETS[@]}"; do
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/scripts/lib/install/targets/${_target}.sh"
done
unset _target

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  install     Initial setup: base step plus opt-in steps (flags below).
              $(basename "$0") install --target <targets> [--mode <mode>] [--settings] [--rules] [--mcp] [--hooks] [--only <steps>] [--package <ids>] [--plugins <names>] [--mods <names>] [--skills <names>] [--with-deps] [--project|--global] [--force] [--dry-run]
  sync        Sync what you name, nothing else.
              $(basename "$0") sync --target <targets> --intent <intents> [--plugins <names>] [--mods <names>] [--skills <names>] [--with-deps] [--mode <mode>] [--project|--global] [--force] [--dry-run]
  remove      Strip installer-managed config and native installs.
              $(basename "$0") remove --target <targets> (--only <steps> | --intent <intents>) [--plugins <names>] [--mods <names>] [--skills <names>] [--project|--global] [--force] [--purge-cache] [--dry-run]
  cli         Put this installer on PATH as '${CLI_NAME}'.
              $(basename "$0") cli [--dir <dir>] [--force]
  completion  Print or install shell completion.
              $(basename "$0") completion [--shell bash|zsh|fish] [--install [--force]]
  list        Print the selectable kinds, or the names a kind takes (for --<kind>).
              $(basename "$0") list [<kind>] [--target <targets>]   (e.g. list skills, list plugins, list mods)

A command is required; a bare '$(basename "$0") install --target ...' is rejected.

Install ycc into an AI coding tool.

Native packages: claude, codex, cursor and omp install ycc only through
their own plugin CLIs (the ycc marketplace and its packages ycc, ycc-mcp,
ycc-hooks, ycc-rules). opencode installs it as the npm plugin
@yandy-r/ycc-opencode: the base step writes one 'plugins' entry into
~/.config/opencode/opencode.json. The agents target has no native route;
the installer copies its skills. After a successful native install (and on
remove), the installer automatically retires the legacy copies and config
an older ycc installer wrote for that target — only entries it can prove it
owns (recorded hash, ownership record or a byte-identical copy); your own
files are never touched.

Command on PATH ('cli' / 'completion' subcommands):
  cli         Symlink this install.sh as '${CLI_NAME}' into the first of
              \$XDG_BIN_HOME, ~/.local/bin, ~/bin that is on PATH (else
              ~/.local/bin, with a warning). --dir overrides. Then run
              '${CLI_NAME} sync ...' from any project; --project targets the
              current directory's git toplevel.
  completion  Print the completion script for --shell (default: \$SHELL).
              --install symlinks it where the shell autoloads it:
                bash  \${BASH_COMPLETION_USER_DIR:-\${XDG_DATA_HOME:-~/.local/share}/bash-completion}/completions/${CLI_NAME}
                zsh   \${XDG_DATA_HOME:-~/.local/share}/zsh/site-functions/_${CLI_NAME}
                fish  \${XDG_CONFIG_HOME:-~/.config}/fish/completions/${CLI_NAME}.fish
  Both refuse to replace an existing file or foreign symlink without --force.

  ./install.sh cli && ${CLI_NAME} completion --install

The 'sync' subcommand is the recommended entry point: say WHAT you want synced
and each target maps it onto the steps it actually supports. Structured config
files are MERGED (repo-managed keys only), so local edits, tokens, trusted
projects and CLI-written marketplace entries survive. 'install' is the
step-flag form used for first-time setup.

  $(basename "$0") sync --target claude --intent base,mcp,hooks
  $(basename "$0") sync --target all --intent settings,rules --global
  $(basename "$0") sync --target opencode --intent base,settings,rules
  $(basename "$0") sync --target opencode --intent base --mode repo
  $(basename "$0") sync --target claude --intent mods --mods status-bar
  $(basename "$0") sync --target codex --intent agents
  $(basename "$0") sync --target cursor --intent base,rules,mcp
  $(basename "$0") sync --target agents --intent skills --skills clean
  $(basename "$0") sync --target agents --intent skills --skills code-review --with-deps
  $(basename "$0") sync --target opencode --intent plugins --plugins oh-my-opencode-slim

Intents (valid: base, skills, agents, commands, settings, rules, mcp, hooks,
plugins, mods):
  base      Install the target's ycc package or bundle (claude/codex: the
            ycc plugin from the ycc marketplace; cursor: register the ycc
            marketplace; omp: the native ycc packages; opencode: the
            @yandy-r/ycc-opencode plugins entry; agents: the copied skills).
  skills    claude/codex/cursor/opencode: part of the ycc package (maps to
            base). agents: the whole ~/.agents/skills target.
  agents    claude/cursor/opencode: part of the ycc package (maps to base).
            codex: custom agents in ~/.codex/agents (no native carrier).
  commands  claude/cursor/opencode: part of the ycc package (maps to base;
            opencode commands are /ycc:<skill>).

  agents/codex slices need no plugin. Each entry is copied with plugin-root
  paths and 'ycc:' prefixes rewritten so it works on its own; only entries
  ycc installed (or identical copies) are ever replaced or removed, so your
  own skills/agents in those dirs are left alone (--force overrides).
  Destinations:
    codex     ~/.codex/agents/<name>.toml (custom agents; always the full set)
  The agents target ships ycc skills ONLY, once, into the cross-tool dir:
    agents    ~/.agents/skills/<name> (+ ~/.agents/ycc-shared/), read by Zed,
              Codex, opencode, Cursor, Gemini CLI, Copilot, Amp, Goose, Windsurf
  settings  Merge repo-managed config keys (models, effort levels, ...).
            Project scope by default on claude, codex and opencode; cursor
            and omp write only with --global (see Scope).
  rules     Link native global instructions (claude CLAUDE.md, codex
            default.rules + AGENTS.md, opencode/omp AGENTS.md). cursor: the
            ycc-rules package (maps to base).
  mcp       claude: 'claude plugin install ycc-mcp@ycc'. codex: 'codex plugin
            add ycc-mcp@ycc' (user scope). cursor: the ycc-mcp package (maps
            to base). opencode: part of @yandy-r/ycc-opencode (maps to base).
  hooks     claude: 'claude plugin install ycc-hooks@ycc'. cursor: the
            ycc-hooks package (maps to base).
  plugins   Merge plugin enablement and marketplace entries. Add 'base' too
            when you also want the target's CLI to perform registration.
            The plugins config group is global-only (pass --global); opencode
            catalog plugins also install per project.
  mods      Install the Claude Code mods under ycc/mods (claude only for now).

  Intents a target cannot execute are reported and skipped. 'sync' is exclusive:
  it never implicitly runs 'base'.

  Intent → step mapping per target:
    claude    base, skills, agents, commands → base   settings→settings
              rules→rules  mcp→mcp  hooks→hooks  plugins→settings  mods→mods
    codex     base, skills → base  agents→agents  settings→settings
              rules→rules  mcp→mcp  plugins → settings (config.toml)
              commands, hooks, mods → no-op
    cursor    base, skills, agents, commands, rules, mcp, hooks → base
              settings→settings   plugins, mods → no-op
    opencode  base, skills, agents, commands, mcp → base  settings→settings
              rules→rules  plugins → settings (opencode.json)  hooks, mods → no-op
              (on remove, skills/agents/commands/mcp print a notice and
              remove nothing; remove --intent base takes back the package)
    agents    base→base  skills→skills  everything else → no-op
              (both install ~/.agents/skills + ycc-shared/, the whole target;
              only the skills step is narrowed by --skills)
    omp       base→base,dedupe  plugins→base,dedupe  settings→settings  rules→rules
              skills, agents, commands, hooks, mcp, mods → no-op
              (the native packages ycc, ycc-mcp and ycc-rules carry skills, agents,
              commands, MCP servers and rules; dedupe is default-on and writes the user
              config.yml; settings and rules are opt-in, user scope only;
              settings runs only with --global)

Remove ('remove' subcommand):
  Undoes what the selected steps installed, for every target and intent (same
  intent → step mapping as 'sync'). Requires --only or --intent; rejects
  --mode. Only installer-owned things go:
    settings/plugins            managed config keys; keys you added are
                                never touched, a managed value you edited is
                                kept with a warning unless --force. A config
                                file left empty is deleted.
    rules                       symlinks, only while they still point here.
    claude mcp / hooks          'claude plugin uninstall ycc-mcp@ycc' /
                                'ycc-hooks@ycc' at the step's scope; a
                                project marketplace goes only when declared
                                there and no longer used.
    claude statusline script    only while identical to the repo (or --force);
                                --global only.
    codex mcp                   'codex plugin remove ycc-mcp@ycc'.
    base                        claude: 'claude plugin uninstall ycc@ycc' +
                                marketplace remove; codex: the ycc@ycc and
                                ycc-mcp@ycc plugins, the ycc marketplace and
                                the custom agents ycc installed; cursor:
                                'agent plugin marketplace remove ycc' (the
                                packages themselves are removed in
                                /plugins); opencode: the
                                @yandy-r/ycc-opencode plugins entry ycc wrote
                                (another ycc-opencode entry needs --force);
                                omp: first, with the
                                profile's last recorded install (also via
                                --intent base/plugins), the dedupe
                                skills.ignoredSkills entries; then the
                                ycc-owned 'omp plugin' installs of the
                                scope, the ycc marketplace and export once
                                nothing ycc-owned or foreign needs them, and
                                at --project the empty .omp/plugins files
                                and dirs ycc's project install created.
                                claude, codex, cursor and opencode then
                                retire the legacy copies an older installer
                                wrote.
    skills / agents / commands  agents/codex agents: the standalone entries
                                ycc installed (or that are still identical
                                to the bundle); never your own. opencode:
                                a notice only (they ship in the package).
    mods (claude)               uninstall each mod + the ycc-mods marketplace.

  $(basename "$0") remove --target claude --only mcp            # project scope
  $(basename "$0") remove --target claude --intent mcp --global
  $(basename "$0") remove --target codex --intent settings,rules  # project settings
  $(basename "$0") remove --target all --intent base,settings,rules,hooks,plugins,mods
  $(basename "$0") remove --target opencode --intent base        # the plugins entry + legacy cleanup
  $(basename "$0") remove --target opencode --intent plugins --plugins oh-my-opencode-slim --purge-cache
  $(basename "$0") remove --target all --only settings --dry-run  # preview, change nothing
  $(basename "$0") remove --target omp --only base --dry-run    # preview the omp uninstall

  Global settings/plugins need --global:
  $(basename "$0") remove --target claude,codex,opencode --intent settings,plugins --global

Scope (--project | --global, mutually exclusive):
  Without a flag, steps that support project scope use it (claude mcp and
  hooks; settings on claude, codex and opencode) and all others
  stay global; cursor and omp settings are skipped with a notice (their
  --project is an error). --project with a step lacking project support is
  an error. The project is the git toplevel of the current directory (else
  the directory). Package installs keep mcp, hooks and settings global. omp
  base,dedupe are opt-in: only with an explicit --project (omp installs
  default to user scope; dedupe always writes the user config.yml).

  Settings write only user-global files with --global (install, sync and
  remove alike). A defaulted run warns while the global file still holds
  ycc-managed keys.

    target    mcp --project (default)         mcp --global
    claude    claude plugin install           claude plugin install
              ycc-mcp@ycc --scope project     ycc-mcp@ycc --scope user
    codex     none (--project is an error)    codex plugin add ycc-mcp@ycc
    cursor    the ycc-mcp package, picked in /plugins (base step)

    target    hooks --project (default)       hooks --global
    claude    claude plugin install           claude plugin install
              ycc-hooks@ycc --scope project   ycc-hooks@ycc --scope user
              (both need Claude Code >= 2.1.300; project scope writes
              <project>/.claude/settings.json and is refused at \$HOME)
    cursor    the ycc-hooks package, picked in /plugins (base step)

    target    settings --project (default)    settings --global
    claude    <project>/.claude/settings.json ~/.claude/settings.json +
                                              ~/.claude/statusline-command.sh
    codex     <project>/.codex/config.toml    ~/.codex/config.toml
              (Codex loads it only for trusted projects)
    opencode  <project>/opencode.json         ~/.config/opencode/opencode.json
              (catalog plugins: + <project>/.opencode/)
    cursor    none (skipped unless --global)  ~/.cursor/cli-config.json
    omp       none (skipped unless --global)  <agentDir>/config.yml
    Project files take preference keys only. claude: env, attribution, model,
    modelSettings, alwaysThinkingEnabled, effortLevel. codex: personality,
    model, model_reasoning_effort, model_context_window,
    model_auto_compact_token_limit, plan_mode_reasoning_effort, service_tier,
    [agents], [features]. opencode: every managed settings key. Global-only:
    the plugins config group (opencode catalog plugins excepted), claude
    statusLine, permissions and skip*PermissionPrompt, codex approval and
    sandbox keys. These project files are usually committed: review them
    before committing. Refused at \$HOME (default scope skips with a notice).

    target    base --project                  base (default, or --global)
    omp       omp plugin install --scope      omp plugin install --scope user
              project (refused at \$HOME)

Merge semantics (all structured config files):
  - Keys this repo declares as managed are written; every other key is kept.
  - A managed value the installer previously wrote is updated automatically.
  - A managed value YOU changed is preserved, with a warning; --force takes
    the repo value instead.
  - Ownership is tracked by hash in ~/.config/ycc/managed-config-state.json
    (hashes only — never values).

Options:
  --target <targets>  Comma-separated targets: claude, cursor, codex, opencode,
                      agents, omp, or all (which must stand alone). Every target
                      is validated before any of them runs. all skips omp unless
                      omp >= 18.12.2 is on PATH and an OMP package is listed.
  --mode <mode>       Marketplace source mode (default: local). Supported:
                        local — claude adds this checkout as a directory
                                marketplace; codex runs 'codex plugin
                                marketplace add <checkout>' and installs
                                ycc@ycc and ycc-mcp@ycc from it; omp exports
                                this checkout's packages; opencode writes a
                                file:///<checkout>/packages/opencode/ycc-opencode
                                plugins entry; agents copies its skills.
                                cursor registers the published GitHub catalog
                                either way (Cursor rejects filesystem
                                marketplaces).
                        repo  — register the upstream github repo
                                yandy-r/ystack as the marketplace source:
                                claude adds the github slug via the CLI;
                                codex adds https://github.com/yandy-r/ystack.git
                                at ref main and installs ycc@ycc and
                                ycc-mcp@ycc from it, skipping local
                                generation and custom-agent sync; cursor
                                registers https://github.com/yandy-r/ystack;
                                omp registers https://github.com/yandy-r/ystack.git
                                and installs its listed packages from it;
                                opencode writes @yandy-r/ycc-opencode@<version>
                                (the published lockstep release). agents
                                REJECTS --mode repo (no remote-source
                                concept); --target all + --mode repo skips
                                it with a warning.
  --settings          Additive: MERGE repo-managed keys into per-machine config
                      files while preserving local model choices, tokens,
                      marketplace entries written by the CLI, trusted-project
                      lists, and unknown keys. Managed values changed locally
                      are preserved unless --force is passed. Non-structured
                      companion files (for example the Claude statusline script)
                      still use copy semantics.
                      Mode-agnostic. Scope per target (project = default,
                      --global = user files; see Scope above):
                        claude   — <project>/.claude/settings.json (preference
                                   keys only) | ~/.claude/settings.json +
                                   statusline-command.sh (global only)
                        codex    — <project>/.codex/config.toml (trusted
                                   projects only; no approval/sandbox keys)
                                   | ~/.codex/config.toml
                        opencode — <project>/opencode.json |
                                   ~/.config/opencode/opencode.json
                        cursor   — global-only (skipped unless --global):
                                   ~/.cursor/cli-config.json (CLI model
                                   preference)
                        omp      — global-only (skipped unless --global):
                                   <agentDir>/config.yml (modelRoles,
                                   retry.fallbackChains, tools.approvalMode;
                                   user scope)
                      Project files are usually committed; review them first.
  --rules             Additive: SYMLINK rules files so edits flow across
                      systems. Refuses to replace a real rules file without
                      --force; replaces existing symlinks idempotently.
                      Mode-agnostic. Scope per target:
                        claude   — CLAUDE.md at ~/.claude/
                        codex    — default.rules + AGENTS.md at ~/.codex/
                        opencode — AGENTS.md at ~/.config/opencode/
                        omp      — AGENTS.md → <agentDir>/ (user scope)
                        cursor   — the ycc-rules package (base step)
  --mcp               Additive: also run the target's 'mcp' step (claude:
                      ycc-mcp@ycc plugin; codex: ycc-mcp@ycc plugin, user
                      scope). Scope follows --project (default) / --global.
                      opencode has no mcp step: its MCP servers ship in
                      @yandy-r/ycc-opencode.
  --hooks             install only: additive, also run the target's 'hooks'
                      step (claude: the ycc-hooks@ycc plugin, project scope
                      by default, user scope with --global; Claude Code >=
                      2.1.300). Silently ignored by targets without hook
                      support. On sync/remove use --intent hooks.
  --plugins <names>   Comma-separated plugin entries: the settings step merges
                      (or removes) only these in the plugins config group —
                      claude enabledPlugins 'name@marketplace' keys plus the
                      marketplaces they use, codex [plugins."name@mkt"]
                      tables, opencode plugins items by package name (no
                      version). settings keys in the same run stay whole.
                      Requires the plugins group (--intent plugins, or
                      install --only settings); not with --package.
                      Marketplaces follow their plugins; remove keeps one
                      while an enabled plugin still uses it. A target that
                      manages none of them skips its plugins group. The
                      plugins group is global-only: pass --global (default
                      scope skips it with a notice; an explicit --project
                      rejects --intent plugins / --plugins, except opencode
                      catalog names).
                      opencode also offers an opt-in catalog of pinned
                      third-party plugins (ycc/settings/opencode-plugins.json,
                      e.g. oh-my-opencode-slim): only --plugins installs one;
                      it merges the pinned item plus its managed keys, ships
                      its companion config, and prints manual follow-ups.
                      remove without --plugins takes back every catalog
                      plugin ycc installed. Catalog plugins also install per
                      project: <project>/opencode.json, companions in
                      <project>/.opencode/.
                      Names: '$(basename "$0") list plugins'
  --mods <names>      Comma-separated claude mods (ycc-mods marketplace
                      plugins): the mods step installs (or uninstalls) only
                      these. Requires the mods step (--intent mods / --only
                      mods); claude only. remove --mods keeps the ycc-mods
                      marketplace while another '<mod>@ycc-mods' key is still
                      in ~/.claude/settings.json enabledPlugins.
                      Names: '$(basename "$0") list mods'

  agents selections. The native-package targets (claude, codex, cursor, omp,
  opencode) install whole packages, so --skills and --with-deps do not apply
  to them: with only native targets selected they are an error; with
  --target all (or another mix) they apply to the agents target and the
  native targets skip them with one notice.
  --skills <names>    Comma-separated skills: the agents target's skills step
                      installs (or removes) only these instead of every skill;
                      requires the skills step (--intent skills / --only
                      skills). Other installed skills are left in place
                      (narrowing, never pruning); ~/.agents/ycc-shared/ always
                      ships with them. 'base' is never filtered. After a
                      selective install, missing ycc:<name> dependencies are
                      reported (warn only). Names: '$(basename "$0") list skills'
  --with-deps         install / sync only, with --skills: also select the
                      ycc:<name> dependencies of the selected skills
                      (transitively) that the agents target ships; skips
                      dependencies available from elsewhere (your own
                      entries) unless ycc owns them.
                      Prints 'agents: --with-deps adds ...'.

  --project           Scope-capable steps (claude mcp and hooks;
                      settings on claude, codex and opencode) write into the
                      current project. Default when neither flag is given
                      (except package installs, whose mcp, hooks and settings
                      stay global). Claude project plugins and project
                      settings refuse \$HOME. Project settings carry
                      preference keys only and never the global-only plugins
                      group (opencode catalog plugins excepted). cursor and
                      omp settings and codex mcp reject it. omp base installs
                      at omp's project scope only with an explicit --project
                      (never at \$HOME).
  --global            Scope-capable steps write into user-global config (claude
                      plugins at --scope user).
  --force             Let repo-managed config values win over local edits, and
                      replace real rules files with repo symlinks when needed.
                      Unknown/unmanaged config keys are never removed.
                      omp: reinstall ycc-owned packages
                      ('omp plugin install --force') and replace a stale ycc
                      export directory.
  --purge-cache       remove only, opencode: also delete the opencode package
                      cache (~/.cache/opencode npm/, packages/, node_modules/)
                      of each catalog plugin removed from opencode.json.
  --dry-run           install / sync / remove: preview without writing any
                      config, file, plugin install or ownership state. Each
                      target previews the steps it can (settings, rules;
                      claude mcp/hooks plugin calls; cursor base; opencode
                      base, which skips the local package build;
                      remove-only base on claude/codex; every omp step),
                      including the legacy cleanup it would run. Steps
                      without a preview say so and skip.
  --only <steps>      Exclusive: run only the comma-separated steps
                      (e.g. --only settings, --only rules,settings).
                      Overrides defaults and --settings/--rules/--mcp/--hooks.
                      A skills/agents/commands step a target has no home for
                      is skipped with a notice (e.g. commands on codex); with
                      --target all, so is any step another target accepts
                      (e.g. --only mcp skips opencode and agents). A step no
                      target has is still an error.
  --intent <intents>  'sync' / 'remove' subcommands only. Comma-separated intents (see
                      above). Cannot be combined with --only or the additive
                      --settings/--rules/--mcp flags.
  --package <ids>     'install' only. Comma-separated ids from the package model:
                      claude: ycc, ycc-mcp, ycc-hooks, ycc-all;
                      codex: ycc, ycc-mcp; cursor: ycc, ycc-rules, ycc-mcp,
                      ycc-hooks; omp: ycc, ycc-mcp, ycc-rules (ycc-hooks
                      excluded: herdr reporting is 'herdr integration install
                      omp'); opencode: @yandy-r/ycc-opencode.
                      Each package maps onto the target's native route:
                        claude  ycc → base (ycc@ycc), ycc-mcp → mcp
                                (ycc-mcp@ycc), ycc-hooks → hooks
                                (ycc-hooks@ycc), ycc-all → all three; plugins
                                install at user scope
                        codex   ycc → base (ycc@ycc + ycc-mcp@ycc), ycc-mcp →
                                mcp (ycc-mcp@ycc); both also sync the custom
                                agents (local mode)
                        cursor  every package → base (register the
                                marketplace; the /plugins hint names the
                                packages)
                        omp     each package → one 'omp plugin install'
                        opencode @yandy-r/ycc-opencode → base (the
                                plugins entry)
                      claude and codex also add their installer-fallback
                      settings and rules (cursor: settings); omp and
                      opencode never (their --settings and --rules stay
                      opt-in). No catalog
                      entries are ever created. A package unavailable for a
                      target fails before any writes; --target all warns and
                      skips that target.
                      Cannot combine with --intent, --only or additive flags.
  --help              Show this help message

install semantics:
  Default (no --only):
    - Run the target's 'base' step (if any).
    - Additionally run 'settings' / 'rules' / 'mcp' / 'hooks' if their flag is
      passed.
  With --only <steps>:
    - Run exactly the listed steps. Nothing else.
  With --package <ids>:
    - Run the validated closure's deliverable steps for each selected target.
    - Example: $(basename "$0") install --package ycc,ycc-mcp --target claude

  Transport semantics:
    - --settings (copy)   dest absent: cp; dest is a symlink: warn + rm + cp;
                          dest is a real file: error unless --force.
    - --rules    (symlink) idempotent link; refuses to replace a real file
                          without --force.

Target steps:
  claude    base | settings | rules | mcp | hooks | mods
            base:     'claude plugin marketplace add <repo> --scope user'
                      + 'claude plugin install ycc@ycc --scope user'. Breaks
                      ~/.claude/settings.json symlink (if any) first so the CLI
                      write doesn't pollute the committed source file. Edits
                      in ycc/ apply on /reload-plugins. Then retires legacy
                      ycc copies (standalone skills/agents, command wrappers,
                      hook and MCP config an older installer wrote).
            settings: MERGE managed keys from ycc/settings/settings.json into
                      <project>/.claude/settings.json (default; preference
                      keys only, no statusline) or, with --global,
                      ~/.claude/settings.json and COPY statusline-command.sh.
                      Local edits and CLI-written marketplace entries are
                      preserved unless --force resolves a managed conflict.
            rules:    symlink ycc/settings/rules/CLAUDE.md into
                      ~/.claude/.
            mcp:      'claude plugin install ycc-mcp@ycc' at --scope project
                      (default) or --scope user (--global).
            hooks:    'claude plugin install ycc-hooks@ycc' at --scope project
                      (default) or --scope user (--global); needs Claude Code
                      >= 2.1.300. WorktreeCreate keeps worktrees in
                      <repo>/.claude/worktrees/.
                      For project scope, when ycc is not already known, the
                      marketplace is declared in the project's
                      settings.local.json (local mode) or settings.json (repo
                      mode).
            mods:     'claude plugin marketplace add ycc/mods --scope user'
                      (the local 'ycc-mods' marketplace) + 'claude plugin
                      install <mod>@ycc-mods --scope user' for each mod it
                      lists. Mods load in place; edits apply on /reload-plugins.
  codex     base | agents | settings | rules | mcp (needs codex >= 0.160)
            base:     generate + validate (local mode) and sync custom agents
                      into ~/.codex/agents, then 'codex plugin marketplace add
                      <checkout | repo>' and 'codex plugin add ycc@ycc' +
                      'ycc-mcp@ycc'; then retires the legacy copies (plugin
                      links, local-ycc-plugins cache and catalog entry,
                      ~/.codex/skills copies, [mcp_servers] merges). A missing
                      or older codex CLI is an error.
                      Rerun this step after ./scripts/sync.sh --only codex to
                      refresh Codex's snapshots of the plugins.
            agents:   generate + install each custom agent into ~/.codex/agents/.
            settings: MERGE managed keys from .codex-plugin/config/config.toml
                      into <project>/.codex/config.toml (default; preference
                      keys only, loaded only for trusted projects) or
                      ~/.codex/config.toml (--global). Comments, trusted
                      projects, MCP bearer tokens, connector entries and
                      unknown tables are preserved; the 'plugins' intent maps
                      here too (--global only).
            mcp:      'codex plugin add ycc-mcp@ycc' (user scope only).
            rules:    symlink .codex-plugin/config/default.rules AND
                      ycc/settings/rules/AGENTS.md into ~/.codex/.
  cursor    base | settings
            base:     'agent plugin marketplace add https://github.com/yandy-r/ystack'
                      (idempotent; local mode registers the same URL), then
                      prints the /plugins step naming the packages for the
                      requested intents (ycc, ycc-rules, ycc-mcp, ycc-hooks):
                      the agent CLI has no non-interactive plugin install.
                      Without the agent CLI it prints the manual IDE steps.
                      Then retires the legacy ~/.cursor copies (skills,
                      agents, rules, commands, hooks, MCP merges).
            settings: --global only (skipped otherwise): merge
                      packages/cursor/installer-fallback/config/cli-config.json
                      into ~/.cursor/cli-config.json (main CLI model
                      preference). Cursor's project .cursor/cli.json carries
                      permissions only.
  opencode  base | settings | rules
            base:     local mode: generate + validate + format
                      packages/opencode/ycc-opencode. Then merge ONE plugins
                      entry into ~/.config/opencode/opencode.json (always
                      global): file:///<checkout>/packages/opencode/ycc-opencode
                      (local) or @yandy-r/ycc-opencode@<version> (repo). Any
                      older ycc-opencode entry (another version, @latest, a
                      bare name, an npm: alias, another file:// checkout) is
                      replaced in place, keeping its options; other plugins
                      items are untouched. Then retires the legacy file copy
                      (once the entry loads the package): byte-identical
                      ~/.config/opencode/{skills,agents,commands,shared,
                      ycc-sensitive-guard} entries, owned mcp.servers and the
                      owned "./ycc-sensitive-guard" plugins item. Restart
                      opencode (>= 2.0.30); commands are /ycc:<skill>.
                      remove: takes back only the entry ycc wrote (or the
                      exact entry this checkout would write; --force for
                      any other ycc-opencode entry), then the same cleanup.
            settings: MERGE managed keys from .opencode-plugin/opencode.json
                      into <project>/opencode.json (default) or
                      ~/.config/opencode/opencode.json (--global). Local model
                      choices, provider credentials and unknown keys are
                      preserved; the 'plugins' intent maps here too (bundle
                      plugins --global only; catalog plugins either scope).
            rules:    symlink .opencode-plugin/AGENTS.md into
                      ~/.config/opencode/ (generator-produced from
                      ycc/settings/rules/CLAUDE.md — the same user-global
                      ruleset as every other target). The package skips its
                      own copy when the request already carries it.
  agents    base | skills (both run the same thing)
            base/skills:  generate + validate the .agents-plugin bundle, then
                      install each skill into ~/.agents/skills/ (+ shared
                      helpers in ~/.agents/ycc-shared/). Foreign skills and
                      ~/.agents/plugins/ are never touched.
  omp       base | dedupe | settings | rules (needs omp >= 18.12.2 on PATH)
            base:     retire a legacy 'omp plugin link' install first, then
                      generate + validate packages/omp, export them to
                      \${XDG_DATA_HOME:-~/.local/share}/ycc/omp-marketplace,
                      register that export as the omp marketplace 'ycc', then
                      'omp plugin install|upgrade --scope user|project' for
                      ycc@ycc, ycc-mcp@ycc (MCP servers ycc-mcp:<server>) and
                      ycc-rules@ycc (rules ycc-<family>-<stem>).
                      Ownership is recorded per omp profile in
                      ~/.config/ycc/omp-native-install.json; remove touches
                      only what ycc installed.
            dedupe:   default-on, user scope (also with --project). Append the
                      agents/<name> and opencode/<name> aliases of ycc skills
                      the agents/opencode targets installed
                      (installed-units.json) to <agentDir>/config.yml
                      skills.ignoredSkills, so OMP loads each ycc skill once.
                      Hash-owned list items; user items and user-authored
                      skills are never touched. --only base skips it (and
                      prints the duplicates); remove --only dedupe takes the
                      entries back.
            settings: opt-in, user scope only, --global only (skipped
                      otherwise; ycc never writes project .omp/config.yml).
                      MERGE the ycc-owned modelRoles, retry.fallbackChains
                      and tools.approvalMode leaves from
                      ycc/settings/omp/config.yml into <agentDir>/config.yml
                      (needs PyYAML); local edits are kept unless --force.
            rules:    opt-in, user scope only. symlink
                      ycc/settings/rules/AGENTS.md into <agentDir>/.
  all       Run claude then cursor then codex then opencode then agents (then
            omp, once omp >= 18.12.2 is on PATH and an OMP package is listed);
            step flags propagate.

Examples:
  $(basename "$0") install --target claude                         # ycc@ycc from the local marketplace
  $(basename "$0") install --target claude --settings --rules      # base + project settings + link rules
  $(basename "$0") install --target claude --mcp --hooks           # base + ycc-mcp@ycc + ycc-hooks@ycc (project)
  $(basename "$0") install --target claude --only mcp,hooks --global  # ycc-mcp@ycc + ycc-hooks@ycc (user scope)
  $(basename "$0") install --target claude --only settings --global  # ~/.claude/settings.json + statusline
  $(basename "$0") install --target claude --settings --force      # repo values win for managed-key conflicts
  $(basename "$0") install --target claude --package ycc-all       # ycc, ycc-mcp, ycc-hooks (user scope)
  $(basename "$0") install --target codex                          # ycc@ycc + ycc-mcp@ycc + custom agents
  $(basename "$0") install --target codex --settings --rules       # base + project config.toml + link rules
  $(basename "$0") install --target codex --only settings --global # ~/.codex/config.toml only
  $(basename "$0") install --target codex --only agents            # just ~/.codex/agents
  $(basename "$0") install --target cursor                         # register the ycc marketplace + /plugins hint
  $(basename "$0") install --target cursor --rules --mcp --hooks   # same; the hint adds ycc-rules, ycc-mcp, ycc-hooks
  $(basename "$0") install --target cursor --only settings --global  # ~/.cursor/cli-config.json
  $(basename "$0") install --target opencode                       # the @yandy-r/ycc-opencode plugins entry (this checkout)
  $(basename "$0") install --target opencode --mode repo           # pin the published @yandy-r/ycc-opencode@<version>
  $(basename "$0") install --target opencode --settings --rules    # base + merge opencode.json + link AGENTS.md
  $(basename "$0") install --target agents                         # ycc skills → ~/.agents/skills
  $(basename "$0") install --target all --settings --rules --mcp   # project settings (cursor/omp skip)
  $(basename "$0") install --target all --settings --rules --global  # new machine: user-global settings
  $(basename "$0") install --target claude,codex --only rules      # rules for two targets
  $(basename "$0") install --target all --rules --force            # force-replace user-authored rules files

  # Repo mode (track the upstream github repo instead of the local checkout):
  $(basename "$0") install --target claude --mode repo             # register yandy-r/ystack
                                                                     # as a github marketplace source
  $(basename "$0") install --target codex  --mode repo             # add the git marketplace at ref main
                                                                     # and install ycc@ycc + ycc-mcp@ycc;
                                                                     # skip local generation/agents-sync
  $(basename "$0") install --target all    --mode repo             # claude, cursor, codex, opencode (+ omp)
                                                                     # in repo mode; agents is skipped
  $(basename "$0") install --target claude --mode repo --settings --rules

  # OMP (oh-my-pi >= 18.12.2; native packages through 'omp plugin'):
  $(basename "$0") install --target omp                            # export + install ycc@ycc, ycc-mcp@ycc, ycc-rules@ycc (user scope)
  $(basename "$0") install --target omp --dry-run                  # preview every omp call; no writes
  $(basename "$0") install --target omp --package ycc              # skills/agents/commands only, no MCP servers
  $(basename "$0") install --target omp --project                  # omp project scope (not at \$HOME)
  $(basename "$0") install --target omp --force                    # reinstall the ycc-owned packages
  $(basename "$0") remove  --target omp --only base                # uninstall what ycc installed
  $(basename "$0") install --target omp --settings --rules --global  # ycc model roles + approvals, AGENTS.md (user scope)
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET=""
TARGETS=()
MODE="local"
MODE_SET=0
COMMAND=""
MCP=0
SETTINGS=0
RULES=0
HOOKS=0
FORCE=0
# Read by targets/opencode-catalog.sh (remove only).
PURGE_CACHE=0
# Read by select.sh (expand_with_deps; install/sync only).
WITH_DEPS=0
EXCLUSIVE_STEPS=0
ONLY_STEPS=()
INTENTS=()
PACKAGE=""
PACKAGE_CONFLICT_FLAG=0
SCOPE=""
# Read by core.sh (merge helper), steps.sh (skip_dry_run_steps) and targets/omp.sh.
export DRY_RUN=0

case "${1:-}" in
    cli|completion|list)
        for arg in "$@"; do
            if [[ "${arg}" == "--package" || "${arg}" == --package=* ]]; then
                err "--package is only supported by the 'install' subcommand"
                exit 1
            fi
        done
        case "$1" in
            cli)        shift; run_cli_command "$@"; exit 0 ;;
            completion) shift; run_completion_command "$@"; exit 0 ;;
            list)       shift; run_list_command "$@"; exit 0 ;;
        esac
        ;;
esac

case "${1:-}" in
    install|sync|remove) COMMAND="$1"; shift ;;
    --help|-h) usage; exit 0 ;;
    "") usage; exit 1 ;;
    migrate)
        err "'migrate' was removed in v6.3.0: install and sync now install the native packages and retire legacy installer state themselves"
        shift
        err "  e.g. $(basename "$0") install $*"
        exit 1
        ;;
    *)
        err "missing or unknown command '$1' (expected: install, sync, remove, cli, completion, list)"
        err "  e.g. $(basename "$0") install $*"
        exit 1
        ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            [[ $# -lt 2 ]] && { err "--target requires an argument"; exit 1; }
            TARGET="$2"
            shift 2
            ;;
        --mode)
            [[ $# -lt 2 ]] && { err "--mode requires an argument (local|repo)"; exit 1; }
            MODE="$2"
            MODE_SET=1
            if [[ ! "$MODE" =~ ^(local|repo)$ ]]; then
                err "Invalid --mode: ${MODE} (supported: local, repo)"
                exit 1
            fi
            shift 2
            ;;
        --package)
            if [[ "${COMMAND}" != "install" ]]; then
                err "--package is only supported by the 'install' subcommand"
                exit 1
            fi
            [[ $# -lt 2 ]] && { err "--package requires an argument (a comma-separated list of package ids)"; exit 1; }
            [[ "$2" == --* ]] && { err "--package requires an argument (a comma-separated list of package ids)"; exit 1; }
            [[ -n "$2" ]] || { err "--package contains an empty value"; exit 1; }
            PACKAGE="$2"
            shift 2
            ;;
        --only)
            PACKAGE_CONFLICT_FLAG=1
            [[ $# -lt 2 ]] && { err "--only requires a comma-separated list of steps"; exit 1; }
            IFS=',' read -r -a ONLY_STEPS <<< "$2"
            if [[ ${#ONLY_STEPS[@]} -eq 0 ]]; then
                err "--only requires at least one step"
                exit 1
            fi
            shift 2
            ;;
        --intent)
            PACKAGE_CONFLICT_FLAG=1
            [[ $# -lt 2 ]] && { err "--intent requires a comma-separated list of intents"; exit 1; }
            IFS=',' read -r -a INTENTS <<< "$2"
            shift 2
            ;;
        --mcp)      MCP=1; shift ;;
        --settings) SETTINGS=1; shift ;;
        --rules)    RULES=1; shift ;;
        --hooks)
            # install only: boolean "also run the hooks step" (sync/remove use --intent hooks).
            if [[ "${COMMAND}" != "install" ]]; then
                err "--hooks is install's step flag; ${COMMAND} takes --intent hooks"
                exit 1
            fi
            HOOKS=1
            shift
            ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --purge-cache) PURGE_CACHE=1; shift ;;
        --with-deps) WITH_DEPS=1; shift ;;
        --project|--global)
            if [[ -n "${SCOPE}" && "${SCOPE}" != "${1#--}" ]]; then
                err "--project and --global are mutually exclusive"
                exit 1
            fi
            SCOPE="${1#--}"
            shift
            ;;
        --force)
            # shellcheck disable=SC2034  # read by core.sh, cli.sh, and bundle.sh
            FORCE=1
            shift
            ;;
        --help|-h)  usage; exit 0 ;;
        --*)
            # --<kind> <names>: item selection for any kind in select.sh.
            if is_selectable_kind "${1#--}"; then
                [[ $# -lt 2 ]] && { err "$1 requires a comma-separated list of ${SELECTION_NOUNS[${1#--}]}"; exit 1; }
                parse_selection "${1#--}" "$2"
                shift 2
                continue
            fi
            ;&
        *)
            err "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "${TARGET}" ]]; then
    err "Missing required --target flag"
    usage
    exit 1
fi

if [[ "${COMMAND}" == "remove" ]]; then
    # remove never guesses: say exactly what to remove.
    if [[ "${SETTINGS}" == "1" || "${RULES}" == "1" || "${MCP}" == "1" ]]; then
        err "remove does not accept --settings, --rules, or --mcp (use --only or --intent)"
        exit 1
    fi
    if [[ "${MODE_SET}" == "1" ]]; then
        err "remove does not accept --mode (it undoes local and repo installs alike)"
        exit 1
    fi
    if [[ ${#ONLY_STEPS[@]} -eq 0 && ${#INTENTS[@]} -eq 0 ]]; then
        err "remove requires --only <steps> or --intent <intents>"
        exit 1
    fi
elif [[ "${PURGE_CACHE}" == "1" ]]; then
    err "--purge-cache is only valid with 'remove'"
    exit 1
fi

if [[ "${WITH_DEPS}" == "1" ]]; then
    if [[ "${COMMAND}" == "remove" ]]; then
        err "--with-deps is only valid with install or sync"
        exit 1
    fi
    if ! has_selection skills; then
        err "--with-deps needs --skills"
        exit 1
    fi
fi

if [[ -n "${PACKAGE}" ]]; then
    if [[ "${COMMAND}" != "install" ]]; then
        err "--package is only supported by the 'install' subcommand"
        exit 1
    fi
    if [[ "${PACKAGE_CONFLICT_FLAG}" == 1 || "${SETTINGS}" == "1" || "${RULES}" == "1" || "${MCP}" == "1" || "${HOOKS}" == "1" ]]; then
        err "--package cannot be combined with --intent, --only, --settings, --rules, --mcp, or --hooks"
        exit 1
    fi
fi

if [[ ${#INTENTS[@]} -gt 0 && "${COMMAND}" != "install" ]]; then
    if [[ ${#ONLY_STEPS[@]} -gt 0 || "${SETTINGS}" == "1" || "${RULES}" == "1" || "${MCP}" == "1" ]]; then
        err "${COMMAND} --intent cannot be combined with --only, --settings, --rules, or --mcp"
        exit 1
    fi

    declare -A seen_intents=()
    unique_intents=()
    for intent in "${INTENTS[@]}"; do
        if [[ -z "${intent}" ]]; then
            err "--intent contains an empty value"
            exit 1
        fi
        intent_valid=0
        for allowed in "${VALID_INTENTS[@]}"; do
            [[ "${intent}" == "${allowed}" ]] && intent_valid=1 && break
        done
        if [[ ${intent_valid} -eq 0 ]]; then
            err "unknown intent '${intent}' (valid: ${VALID_INTENTS[*]})"
            exit 1
        fi
        if [[ -z "${seen_intents[${intent}]:-}" ]]; then
            unique_intents+=("${intent}")
            seen_intents["${intent}"]=1
        fi
    done
    INTENTS=("${unique_intents[@]}")
elif [[ "${COMMAND}" == "sync" ]]; then
    err "sync requires --intent <intent,...>"
    exit 1
elif [[ ${#INTENTS[@]} -gt 0 ]]; then
    err "--intent requires the 'sync' or 'remove' subcommand"
    exit 1
fi

if [[ ${#ONLY_STEPS[@]} -gt 0 ]]; then
    EXCLUSIVE_STEPS=1
    if [[ "${SETTINGS}" == "1" ]]; then
        warn "--settings is ignored when --only is used"
    fi
    if [[ "${RULES}" == "1" ]]; then
        warn "--rules is ignored when --only is used"
    fi
    if [[ "${MCP}" == "1" ]]; then
        warn "--mcp is ignored when --only is used"
    fi
    if [[ "${HOOKS}" == "1" ]]; then
        warn "--hooks is ignored when --only is used"
    fi
fi

resolve_targets "${TARGET}"
# Before any target preflight: agents-only selections never reach a native target.
preflight_native_selections
if [[ -n "${PACKAGE}" ]]; then
    [[ "${TARGET}" == "all" ]] && PACKAGE_ALL_TARGETS_REQUESTED=1
    package_preflight_targets
    order_targets
    run_package_targets
else
    order_targets
    preflight_targets
    action="sync"
    [[ "${COMMAND}" == "remove" ]] && action="remove"
    for target in "${TARGETS[@]}"; do
        run_target "${target}" "${action}_${target}_target"
    done
fi
