# shellcheck shell=bash
# claude.sh — the Claude target: implements the per-target contract that install.sh
# dispatches through (see scripts/lib/install/steps.sh):
#   claude_valid_steps, claude_intent_steps <intent>, claude_config_groups,
#   claude_supports_repo_mode, claude_reads_agents_skills, sync_claude_target, remove_claude_target
#
# Sourced by install.sh (never run directly); inherits SCRIPT_DIR and the
# shared helpers from core.sh / steps.sh / bundle.sh. The mods step lives in
# claude-mods.sh.

# shellcheck source=scripts/lib/install/targets/claude-mods.sh
source "${SCRIPT_DIR}/scripts/lib/install/targets/claude-mods.sh"

# claude_valid_steps — comma-separated steps Claude accepts for --only.
claude_valid_steps() { echo "base,skills,agents,commands,settings,rules,mcp,hooks,mods"; }

# claude_dry_run_steps — steps --dry-run can preview (merge helper only).
claude_dry_run_steps() { echo "mcp"; }

# claude_intent_steps <intent> — steps <intent> maps to; empty means no-op.
claude_intent_steps() {
    case "$1" in
        base|settings|rules|mcp) echo "$1" ;;
        # Project hooks use the native plugin, which carries its own activation;
        # the settings group remains global until its own project support lands.
        hooks)
            if [[ "$(step_scope claude hooks)" == "project" ]]; then
                echo "hooks"
            else
                echo "settings,hooks"
            fi
            ;;
        # Claude plugin enablement is pure settings.json state (enabledPlugins,
        # extraKnownMarketplaces). Add 'base' explicitly to also run the CLI's
        # marketplace registration, which needs network access.
        plugins) echo "settings" ;;
        # Mods install from the ycc-mods marketplace via the claude CLI.
        mods) echo "mods" ;;
        # skills/agents/commands install standalone entries into the tool's
        # own user dirs; 'base' ships the whole bundle/plugin.
        skills|agents|commands) echo "$1" ;;
        *) echo "" ;;
    esac
}

# claude_config_groups — default managed config groups for settings.json.
# The intent filter (and its order) lives in config_groups_for_target.
claude_config_groups() { echo "settings,hooks,plugins"; }

claude_supports_repo_mode() { return 0; }

# Claude Code does not read ~/.agents/skills.
claude_reads_agents_skills() { return 1; }

# claude_marketplace_source — local checkout or upstream source for ycc.
claude_marketplace_source() {
    if [[ "${1:-${MODE:-local}}" == "local" ]]; then
        realpath "${SCRIPT_DIR}"
    else
        echo "yandy-r/ystack"
    fi
}

# claude_marketplace_declaration — where a ycc marketplace declaration is
# visible to this project. Declarations, not the machine-wide marketplace
# registration, decide reuse: the CLI's `marketplace list` reports every
# marketplace registered on the machine, including one another project
# declared in its own settings.local.json, so trusting it would let a remove
# in that other project retract this project's plugin. Prints
# "<status>:<scope>[:owned]" — status declared or undeclared; ":owned" when
# the declaration is exactly the shape this installer writes (so remove may
# retract it and sync may re-register the machine from it). An unreadable
# file counts as undeclared (adding is then guarded by the registration
# check below). Scopes: user, project, local.
claude_marketplace_declaration() {
    python3 - "${HOME}/.claude/settings.json" "${1}/.claude/settings.json" \
        "${1}/.claude/settings.local.json" "$(realpath "${SCRIPT_DIR}")" <<'PY'
import json
import pathlib
import sys

checkout = sys.argv[4]
shapes = {
    "local": {"source": {"source": "directory", "path": checkout}},
    "project": {"source": {"source": "github", "repo": "yandy-r/ystack"}},
}
for scope, name in zip(("user", "project", "local"), sys.argv[1:4]):
    try:
        config = json.loads(pathlib.Path(name).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        continue
    marketplaces = config.get("extraKnownMarketplaces") if isinstance(config, dict) else None
    declaration = marketplaces.get("ycc") if isinstance(marketplaces, dict) else None
    if isinstance(declaration, (dict, str)):
        owned = ":owned" if declaration == shapes.get(scope) else ""
        print(f"declared:{scope}{owned}")
        sys.exit(0)
print("undeclared:none")
PY
}

# claude_registered_marketplace_source — the machine-wide registration for
# ycc, from `claude plugin marketplace list --json`. Prints "<status>:<source>"
# where status is registered (with a comparable source string) or unknown
# (unparseable or failed lookup) and the machine-level registration is absent.
# Only a parsed list can establish absence; a failed lookup must never repoint
# an existing ycc.
claude_registered_marketplace_source() {
    local marketplaces
    marketplaces="$(claude plugin marketplace list --json 2>/dev/null)" || { echo "unknown:"; return; }
    python3 -c '
import json
import sys

try:
    entries = json.load(sys.stdin)
except (ValueError, TypeError):
    entries = None
if not isinstance(entries, list):
    print("unknown:")
    sys.exit(0)
entry = next((e for e in entries if isinstance(e, dict) and e.get("name") == "ycc"), None)
if entry is None:
    print("absent:")
    sys.exit(0)
repo, path, url = entry.get("repo"), entry.get("path"), entry.get("url")
if isinstance(repo, str):
    print("registered:repo " + repo)
elif isinstance(path, str):
    print("registered:path " + path)
elif isinstance(url, str):
    print("registered:url " + url)
else:
    print("registered:")
' <<< "${marketplaces}"
}

# claude_registered_source_matches — true when the machine-registered ycc
# source string describes the source this run would declare. A same-source
# registration cannot be repointed by adding, so the declaration is safe.
claude_registered_source_matches() {
    local registration="$1" source_arg
    source_arg="$(claude_marketplace_source)"
    case "${registration}" in
        "registered:repo yandy-r/ystack") [[ "${source_arg}" == "yandy-r/ystack" ]] ;;
        "registered:path ${source_arg}") return 0 ;;
        *) return 1 ;;
    esac
}

# claude_project_install_plugin <plugin> — enable a native package in this
# project. A visible declaration always wins (never repointed, never
# duplicated); otherwise the machine registration decides whether adding the
# declaration at this scope would repoint something.
claude_project_install_plugin() {
    local plugin="$1" root declaration registration source_arg marketplace_scope
    root="$(project_root)"
    require_claude_cli
    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    (
        cd "${root}" || exit 1
        declaration="$(claude_marketplace_declaration "${root}")"
        registration="$(claude_registered_marketplace_source)"
        case "${registration}" in
            registered:*)
                if [[ "${declaration}" == undeclared:* ]] \
                    && ! claude_registered_source_matches "${registration}"; then
                    warn "The ycc marketplace is registered from a different source (${registration#registered:}); declaring it here would repoint it"
                    warn "Skipped the plugin install. Declare ycc for this project yourself, or rerun with --global"
                    exit 0
                fi
                ;;
            unknown:*)
                if [[ "${declaration}" == undeclared:* ]]; then
                    warn "The marketplace list could not be read; no marketplace is added because adding could repoint an existing ycc marketplace"
                    warn "Skipped the plugin install. Declare ycc for this project yourself, or rerun with --global"
                    exit 0
                fi
                ;;
        esac
        marketplace_scope=project
        [[ "${MODE:-local}" == "local" ]] && marketplace_scope=local
        if [[ "${declaration}" == undeclared:* ]] \
            || { [[ "${declaration}" == *:owned ]] && [[ "${registration}" == absent: ]]; }; then
            # Undeclared, or the machine registration is gone while this
            # project's own installer-shaped declaration remains (another
            # project's remove can drop the registration): (re-)add from the
            # declaration's own scope and source, else the mode's default.
            # Adding never repoints here — the guards above excluded a
            # foreign registration, and re-adding over an exact-shape
            # declaration leaves the file untouched (verified against Claude
            # Code 2.1.310). The add also re-registers the machine, healing
            # this project's plugin. A foreign declaration is never rewritten:
            # it is reused as-is and the install simply reports failure.
            case "${declaration}" in
                declared:local:owned)
                    marketplace_scope=local
                    source_arg="$(realpath "${SCRIPT_DIR}")"
                    ;;
                declared:project:owned)
                    marketplace_scope=project
                    source_arg="yandy-r/ystack"
                    ;;
                *)
                    source_arg="$(claude_marketplace_source)"
                    ;;
            esac
            info "Running: claude plugin marketplace add ${source_arg} --scope ${marketplace_scope}"
            claude plugin marketplace add "${source_arg}" --scope "${marketplace_scope}"
        else
            info "reusing the ycc marketplace declared in ${declaration#declared:} settings (not repointing it)"
        fi
        info "Running: claude plugin install ${plugin}@ycc --scope project"
        claude plugin install "${plugin}@ycc" --scope project \
            || warn "plugin install returned non-zero — check 'claude plugin list'"
    )
}

# claude_project_remove_plugin <plugin> — retract project enablement; remove
# only declarations the installer could write, once neither project file needs ycc.
claude_project_remove_plugin() {
    local plugin="$1" root actions action
    root="$(project_root)"
    require_claude_cli
    (
        cd "${root}" || exit 1
        run_claude_cli plugin uninstall "${plugin}@ycc" --scope project
    )
    actions="$(python3 - "${root}/.claude" "${plugin}" "$(realpath "${SCRIPT_DIR}")" <<'PY'
import json
import pathlib
import sys

directory, removed, checkout = pathlib.Path(sys.argv[1]), f"{sys.argv[2]}@ycc", sys.argv[3]
configs = {}
for scope, filename in (("project", "settings.json"), ("local", "settings.local.json")):
    path = directory / filename
    try:
        config = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        if not isinstance(config, dict):
            raise ValueError("settings must be an object")
    except (OSError, ValueError):
        print(f"keep:{filename} could not be read")
        sys.exit(0)
    configs[scope] = config
others = set()
for config in configs.values():
    enabled = config.get("enabledPlugins")
    if isinstance(enabled, dict):
        others.update(key for key, value in enabled.items()
                      if isinstance(key, str) and key != removed and key.endswith("@ycc") and value is True)
if others:
    print("keep:other ycc plugins are still enabled: " + ", ".join(sorted(others)))
    sys.exit(0)
for scope, config in configs.items():
    marketplaces = config.get("extraKnownMarketplaces")
    declaration = marketplaces.get("ycc") if isinstance(marketplaces, dict) else None
    # Owned only on the exact shape the installer writes (via the CLI): a
    # local directory declaration pointing at this checkout, or the unpinned
    # upstream github repo. ref/path/url pins and forks are the user's.
    if scope == "local":
        owned = declaration == {"source": {"source": "directory", "path": checkout}}
    else:
        owned = declaration == {"source": {"source": "github", "repo": "yandy-r/ystack"}}
    if owned:
        print(f"remove:{scope}")
    elif declaration is not None:
        print(f"keep:{scope} ycc marketplace source does not match the installer source")
if not any(isinstance(config.get("extraKnownMarketplaces"), dict)
           and "ycc" in config["extraKnownMarketplaces"] for config in configs.values()):
    print("keep:no project or local ycc marketplace declaration")
PY
)"
    while IFS= read -r action; do
        if [[ "${action}" == remove:* ]]; then
            (
                cd "${root}" || exit 1
                run_claude_cli plugin marketplace remove ycc --scope "${action#remove:}"
            )
        else
            info "kept the ycc marketplace: ${action#keep:}"
        fi
    done <<< "${actions}"
}

# claude_project_hooks_selected — compute the current target's hook selection
# without letting intent/package mapping leak out of preflight.
claude_project_hooks_selected() {
    (
        if [[ -n "${PACKAGE:-}" ]]; then
            package_configure_steps "$(package_steps_csv claude)"
        elif [[ ${#INTENTS[@]} -gt 0 ]]; then
            configure_intents_for_target claude >/dev/null
        fi
        step_enabled hooks && [[ "$(step_scope claude hooks)" == "project" ]]
    )
}

# claude_project_hooks_unavailable_reason — shared preflight/step availability
# check. An empty result means project hooks can run.
claude_project_hooks_unavailable_reason() {
    local root home
    root="$(cd "$(project_root)" && pwd -P)"
    home="$(cd "${HOME}" && pwd -P)"
    if [[ "${root}" == "${home}" ]]; then
        echo '--project at $HOME: claude project scope needs a project directory (cd into a project, or use --global)'
        return
    fi
    if ! command -v claude >/dev/null 2>&1; then
        echo "'claude' CLI is required but not found in PATH"
        return
    fi
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0
    local version major minor patch
    version="$(claude --version 2>/dev/null)" || version=""
    version="${version%%[[:space:]]*}"
    if [[ "${version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        patch="${BASH_REMATCH[3]}"
        if ((10#${major} < 2 || (10#${major} == 2 && (10#${minor} < 1 || (10#${minor} == 1 && 10#${patch} < 300))))); then
            echo "ycc-hooks needs Claude Code 2.1.300 or later (found ${version}); use --global for the installer-managed hooks"
        fi
    fi
    return 0
}

# claude_preflight — reject invalid selection always, unavailable hooks only
# when Claude was explicitly selected (all-target runs skip this step instead).
claude_preflight() {
    claude_project_hooks_selected || return 0
    if has_selection hooks; then
        err "--hooks <events> narrows settings.json hook events, which only the --global hooks step manages; at project scope the ycc-hooks plugin installs its whole hook set"
        err "  use --global, or drop --hooks"
        exit 1
    fi
    [[ "${TARGET}" == "all" ]] && return 0
    local reason
    reason="$(claude_project_hooks_unavailable_reason)"
    if [[ -n "${reason}" ]]; then
        err "${reason}"
        exit 1
    fi
}

claude_global_hooks_link_managed() {
    [[ -L "${HOME}/.claude/hooks" ]] || return 1
    [[ "$(readlink -f "${HOME}/.claude/hooks" 2>/dev/null || true)" == "$(realpath "${SCRIPT_DIR}/ycc/settings/hooks")" ]]
}

# ---------------------------------------------------------------------------
# Claude marketplace — registers ycc as a marketplace via the canonical CLI:
#
#   local mode:  claude plugin marketplace add <repo-path>            --scope user
#   repo  mode:  claude plugin marketplace add yandy-r/ystack --scope user
#                followed by:
#                claude plugin install ycc@ycc --scope user
#
# The CLI writes to ~/.claude/settings.json regardless of source type. That
# path is typically a symlink to ycc/settings/settings.json (via the
# 'settings' step), so we break the symlink first in BOTH modes — otherwise
# the CLI would follow the link and pollute the committed source-of-truth
# file with the marketplace registration.
#
# After this step, ~/.claude/settings.json is a REAL file. Re-running
# `install.sh install --target claude --only settings` would symlink over it and wipe
# the marketplace entry; the 'settings' step detects this and refuses
# without --force.
#
# CLI source form (verified via `claude plugin marketplace add --help`):
#   "Add a marketplace from a URL, path, or GitHub repo" — the
#   <owner>/<repo> slug is accepted directly for repo mode.
# ---------------------------------------------------------------------------
register_claude_marketplace() {
    local mode="${1:-local}"
    if [[ ! "$mode" =~ ^(local|repo)$ ]]; then
        err "register_claude_marketplace: invalid mode '${mode}' (expected local|repo)"
        exit 1
    fi

    command -v claude >/dev/null 2>&1 || {
        err "'claude' CLI is required but not found in PATH"
        exit 1
    }
    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    command -v realpath >/dev/null 2>&1 || { err "realpath is required but not found"; exit 1; }

    local source_arg
    source_arg="$(claude_marketplace_source "${mode}")"

    local settings="${HOME}/.claude/settings.json"

    # Break the symlink safely if it points into this repo (or anywhere).
    # We materialize the current content before the CLI writes to it.
    if [[ -L "${settings}" ]]; then
        local link_target
        link_target="$(readlink -f "${settings}")"
        info "${settings} is a symlink to ${link_target}"
        info "Breaking the symlink before CLI write (protects the committed source file from pollution)"
        local tmp
        tmp="$(mktemp)"
        cat "${settings}" > "${tmp}"
        rm "${settings}"
        mv "${tmp}" "${settings}"
    fi

    # Ensure parent dir exists (fresh $HOME case)
    mkdir -p "$(dirname "${settings}")"

    info "Running: claude plugin marketplace add ${source_arg} --scope user  (mode=${mode})"
    claude plugin marketplace add "${source_arg}" --scope user
    info "Running: claude plugin install ycc@ycc --scope user"
    claude plugin install ycc@ycc --scope user || warn "plugin install returned non-zero — check 'claude plugin list'"

    # Cleanup orphans from earlier broken attempts of this installer
    cleanup_claude_local_orphans
}

# claude_ycc_plugin_installed — print the registry file when ycc@ycc is installed.
claude_ycc_plugin_installed() {
    local registry="${HOME}/.claude/plugins/installed_plugins.json"
    [[ -f "${registry}" ]] && grep -q '"ycc@ycc"' "${registry}" && echo "${registry}"
    return 0
}

# Remove 'local-ycc-plugins' detritus from earlier (broken) versions of the
# installer that wrote to the wrong files with the wrong schema.
# ponytail: the inline Python here (and in claude-mods.sh) stays inline;
# move it to a tested scripts/*.py helper if it grows or gains branches.
cleanup_claude_local_orphans() {
    local files=("${HOME}/.claude.json" "${HOME}/.claude/settings.local.json")
    local f
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        python3 - "$f" <<'PY' || true
import json
import sys
from pathlib import Path

p = Path(sys.argv[1])
try:
    data = json.loads(p.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)

changed = False
extras = data.get("extraKnownMarketplaces")
if isinstance(extras, dict) and "local-ycc-plugins" in extras:
    del extras["local-ycc-plugins"]
    if not extras:
        del data["extraKnownMarketplaces"]
    changed = True

enabled = data.get("enabledPlugins")
if isinstance(enabled, dict) and "ycc@local-ycc-plugins" in enabled:
    del enabled["ycc@local-ycc-plugins"]
    if not enabled:
        del data["enabledPlugins"]
    changed = True

if changed:
    # If the file is now empty after cleanup and it's settings.local.json,
    # just delete it rather than leaving an empty file.
    if not data and p.name == "settings.local.json":
        p.unlink()
        print(f"removed empty orphan file {p}")
    else:
        p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"removed orphaned 'local-ycc-plugins' entries from {p}")
PY
    done
}

# ---------------------------------------------------------------------------
# Claude target (settings + mcp; no base)
# ---------------------------------------------------------------------------
sync_claude_target() {
    validate_only_steps "claude"

    local ran=0
    local base_ran=0
    if step_enabled base; then
        if [[ "${MODE:-local}" == "repo" ]]; then
            printf '\n%sClaude: register github repo as marketplace (yandy-r/ystack)%s\n' "${BOLD}" "${NC}"
        else
            printf '\n%sClaude: register repo checkout as local marketplace%s\n' "${BOLD}" "${NC}"
        fi
        register_claude_marketplace "${MODE:-local}"
        ran=1
        base_ran=1
    fi
    if step_enabled settings; then
        printf '\n%sClaude: merge settings + copy statusline%s\n' "${BOLD}" "${NC}"
        # Structured merge keeps CLI-written marketplace entries and local
        # machine preferences while updating repo-managed model, hook and
        # plugin keys. This is safe even when 'base' ran in the same invocation.
        config_group_selection claude "$(config_groups_for_target claude)"
        if [[ -n "${CONFIG_GROUPS}" ]]; then
            merge_settings_config \
                "claude-settings" \
                "${SCRIPT_DIR}/ycc/settings/settings.json" \
                "${HOME}/.claude/settings.json" \
                "${CONFIG_GROUPS}" "${CONFIG_SELECT[@]}"
        fi
        if [[ ${#INTENTS[@]} -eq 0 ]] || intent_requested settings; then
            copy_settings_file "${SCRIPT_DIR}/ycc/settings/statusline-command.sh" "${HOME}/.claude/statusline-command.sh"
        fi
        ran=1
    fi
    if step_enabled rules; then
        printf '\n%sClaude: link rules (CLAUDE.md)%s\n' "${BOLD}" "${NC}"
        # Documented user memory filename; do not also install a pointer prompt.
        # Leave legacy AGENTS.md links intact; remove still unlinks owned links.
        # https://code.claude.com/docs/en/memory
        link_rules_file "${SCRIPT_DIR}/ycc/settings/rules/CLAUDE.md" "${HOME}/.claude/CLAUDE.md"
        ran=1
    fi
    if step_enabled mcp; then
        printf '\n%sClaude: %s MCP servers%s\n' "${BOLD}" "${COMMAND}" "${NC}"
        run_mcp_step claude
        ran=1
    fi
    if step_enabled hooks; then
        if [[ "$(step_scope claude hooks)" == "project" ]]; then
            local root reason
            reason="$(claude_project_hooks_unavailable_reason)"
            if [[ -n "${reason}" ]]; then
                warn "Skipping Claude project hooks: ${reason}"
            else
                root="$(project_root)"
                printf '\n%sClaude: install ycc-hooks@ycc at project scope (%s)%s\n' "${BOLD}" "${root}" "${NC}"
                claude_project_install_plugin ycc-hooks
                if claude_global_hooks_link_managed; then
                    warn "The global hooks install is still active; WorktreeCreate would run twice. Remove it with: ${CLI_NAME} remove --target claude --intent hooks --global"
                fi
            fi
        else
            printf '\n%sClaude: link hooks directory into ~/.claude/hooks%s\n' "${BOLD}" "${NC}"
            # Directory-level symlink so new hook scripts are picked up automatically.
            # link_file refuses to replace a real directory at the destination, so an
            # existing ~/.claude/hooks (non-symlink) surfaces as an error rather than
            # being silently clobbered.
            link_file "${SCRIPT_DIR}/ycc/settings/hooks" "${HOME}/.claude/hooks"
        fi
        ran=1
    fi
    if step_enabled mods; then
        printf '\n%sClaude: install mods from the ycc-mods marketplace%s\n' "${BOLD}" "${NC}"
        install_claude_mods
        ran=1
        warn "Run /reload-plugins or start a new Claude Code session to load the mods."
    fi
    local slice skills_ran=0
    for slice in $(selected_slices skills agents commands); do
        # Skills are Claude's slash commands; install once for either alias
        # (run_slice narrows it to the union of --skills and --commands).
        if [[ "${slice}" == "commands" ]]; then
            [[ ${skills_ran} -eq 1 ]] && continue
            slice="skills"
        fi
        printf '\n%sClaude: install standalone %s into ~/.claude/%s%s\n' "${BOLD}" "${slice}" "${slice}" "${NC}"
        run_slice claude "${slice}" select
        [[ "${slice}" == "skills" ]] && skills_ran=1
        ran=1
        if [[ -n "$(claude_ycc_plugin_installed)" ]]; then
            warn "The ycc plugin is also installed; its ${slice} now appear twice (ycc:<name> and <name>). Drop one: ${CLI_NAME} remove --target claude --intent base"
        fi
    done
    if [[ $ran -eq 0 ]]; then
        warn "Claude target ran no steps (pass --settings, --rules, --mcp, --hooks, or --only ...)"
    fi
    printf '\n%sClaude %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
    if [[ $base_ran -eq 1 ]]; then
        if [[ "${MODE:-local}" == "repo" ]]; then
            warn "Run /reload-plugins or start a new Claude Code session. The 'ycc' marketplace in ~/.claude/settings.json now tracks the github source yandy-r/ystack."
            warn "Updates: rerun 'claude plugin install ycc@ycc --scope user' (or use the in-Claude /plugins UI) to pull the latest published commit."
            warn "The Claude settings file now contains the CLI-written marketplace entry. Re-running the settings step merges repo-managed keys and preserves that entry."
        else
            local claude_repo_root_msg
            claude_repo_root_msg="$(realpath "${SCRIPT_DIR}")"
            warn "Run /reload-plugins or start a new Claude Code session. The 'ycc' marketplace in ~/.claude/settings.json now points at ${claude_repo_root_msg} (directory source)."
            warn "Edits in ycc/ apply on plugin reload. No rsync, no cache clear."
            warn "The Claude settings file now contains the CLI-written marketplace entry. Re-running the settings step merges repo-managed keys and preserves that entry."
            warn "If you move or rename this repo, rerun ./install.sh install --target claude --only base."
        fi
    fi
}


# ---------------------------------------------------------------------------
# Claude remove
# ---------------------------------------------------------------------------
# run_claude_cli <args...> — a failed uninstall is reported, not fatal: the
# plugin or marketplace may simply not be registered.
run_claude_cli() {
    info "Running: claude $*"
    claude "$@" || warn "'claude $*' returned non-zero — check 'claude plugin list'"
}

require_claude_cli() {
    command -v claude >/dev/null 2>&1 || { err "'claude' CLI is required but not found in PATH"; exit 1; }
}

# claude_hooks_still_managed — true when remove --hooks leaves a managed hook
# event outside the selection recorded in the managed-config ownership state
# for ~/.claude/settings.json: those events still run scripts from the
# ~/.claude/hooks link. False without --hooks (the whole group goes).
claude_hooks_still_managed() {
    has_selection hooks || return 1
    local state="${YCC_MANAGED_CONFIG_STATE:-${XDG_CONFIG_HOME:-${HOME}/.config}/ycc/managed-config-state.json}"
    [[ -f "${state}" ]] || return 1
    # Key the state like merge_managed_config.py: expanduser'd Path, so a
    # trailing slash in HOME cannot miss the recorded entry.
    python3 - "${state}" "${HOME}/.claude/settings.json" "$(selection_for hooks)" <<'PY'
import json
import pathlib
import sys

path, selected = sys.argv[1], set(sys.argv[3].split(","))
key = f"claude-settings:{pathlib.Path(sys.argv[2]).expanduser()}"
try:
    with open(path, encoding="utf-8") as f:
        entry = json.load(f).get(key) or {}
except (OSError, ValueError, AttributeError):
    sys.exit(1)
events = {p.split("/")[2] for p in entry if isinstance(p, str) and p.startswith("/hooks/") and len(p.split("/")) > 2}
sys.exit(0 if events - selected else 1)
PY
}

remove_claude_target() {
    validate_only_steps "claude"
    local claude_dir="${HOME}/.claude"

    if step_enabled mods; then
        printf '\n%sClaude: uninstall mods + the ycc-mods marketplace%s\n' "${BOLD}" "${NC}"
        remove_claude_mods
    fi
    if step_enabled hooks; then
        if [[ "$(step_scope claude hooks)" == "project" ]]; then
            local reason
            reason="$(claude_project_hooks_unavailable_reason)"
            if [[ -n "${reason}" ]]; then
                warn "Skipping Claude project hooks: ${reason}"
            else
                printf '\n%sClaude: uninstall ycc-hooks@ycc at project scope%s\n' "${BOLD}" "${NC}"
                claude_project_remove_plugin ycc-hooks
            fi
            if claude_global_hooks_link_managed; then
                warn "The global installer-managed hooks are still active. Remove them with: ${CLI_NAME} remove --target claude --intent hooks --global"
            fi
        else
            printf '\n%sClaude: unlink hooks directory%s\n' "${BOLD}" "${NC}"
            if claude_hooks_still_managed; then
                info "kept ${claude_dir}/hooks: managed hook events outside --hooks still use it"
            else
                unlink_owned_link "${SCRIPT_DIR}/ycc/settings/hooks" "${claude_dir}/hooks"
            fi
        fi
    fi
    if step_enabled mcp; then
        printf '\n%sClaude: remove MCP servers%s\n' "${BOLD}" "${NC}"
        run_mcp_step claude
    fi
    if step_enabled rules; then
        printf '\n%sClaude: unlink rules (CLAUDE.md + AGENTS.md)%s\n' "${BOLD}" "${NC}"
        unlink_owned_link "${SCRIPT_DIR}/ycc/settings/rules/CLAUDE.md" "${claude_dir}/CLAUDE.md"
        unlink_owned_link "${SCRIPT_DIR}/ycc/settings/rules/AGENTS.md" "${claude_dir}/AGENTS.md"
    fi
    if step_enabled settings; then
        printf '\n%sClaude: remove managed settings + statusline%s\n' "${BOLD}" "${NC}"
        config_group_selection claude "$(config_groups_for_target claude)"
        remove_settings "claude-settings" "${SCRIPT_DIR}/ycc/settings/settings.json" \
            "${claude_dir}/settings.json" "${CONFIG_GROUPS}" "${CONFIG_SELECT[@]}"
        if [[ ${#INTENTS[@]} -eq 0 ]] || intent_requested settings; then
            remove_copied_file "${SCRIPT_DIR}/ycc/settings/statusline-command.sh" "${claude_dir}/statusline-command.sh"
        fi
    fi
    remove_slices claude skills agents commands
    if step_enabled base; then
        printf '\n%sClaude: uninstall ycc + the ycc marketplace%s\n' "${BOLD}" "${NC}"
        require_claude_cli
        run_claude_cli plugin uninstall ycc@ycc --scope user
        run_claude_cli plugin marketplace remove ycc --scope user
    fi
    printf '\n%sClaude remove complete.%s\n' "${BOLD}" "${NC}"
}
