# shellcheck shell=bash
# cursor.sh — the Cursor target: implements the per-target contract that install.sh
# dispatches through (see scripts/lib/install/steps.sh):
#   cursor_valid_steps, cursor_intent_steps <intent>, cursor_config_groups,
#   cursor_supports_repo_mode, cursor_reads_agents_skills, sync_cursor_target, remove_cursor_target
# plus the optional scope-note hooks: cursor_settings_scope_note,
# cursor_settings_global_dest (settings is global-only: no cursor_project_groups).
#
# Sourced by install.sh (never run directly); inherits SCRIPT_DIR and the
# shared helpers from core.sh / steps.sh / bundle.sh / cleanup.sh.
#
# Cursor installs ycc only through its native plugins (ycc, ycc-rules, ycc-mcp,
# ycc-hooks). The 'agent' CLI can register the marketplace but has no
# non-interactive 'plugin install': the packages are picked in /plugins. The
# base step registers the marketplace, prints that hint, then retires the
# installer-owned file-copy leftovers (run_legacy_cleanup cursor).

CURSOR_PACKAGES_DIR="${SCRIPT_DIR}/packages/cursor"
CURSOR_CLI_CONFIG_SRC="${CURSOR_PACKAGES_DIR}/installer-fallback/config/cli-config.json"
# Cursor rejects filesystem marketplace sources, so local mode registers the
# published GitHub catalog too.
CURSOR_MARKETPLACE_URL="https://github.com/yandy-r/ystack"
CURSOR_MARKETPLACE_NAME="ycc"

# cursor_valid_steps — comma-separated steps Cursor accepts for --only.
cursor_valid_steps() { echo "base,settings"; }

# Both steps preview themselves under --dry-run.
cursor_dry_run_steps() { cursor_valid_steps; }

# cursor_intent_steps <intent> — steps <intent> maps to; empty means no-op.
cursor_intent_steps() {
    case "$1" in
        # Every ycc component ships as a native package: one marketplace step.
        base|skills|agents|commands|rules|mcp|hooks) echo "base" ;;
        settings) echo "settings" ;;
        # Plugin enablement happens in /plugins; mods are Claude Code only.
        plugins|mods) echo "" ;;
        *) echo "" ;;
    esac
}

# cursor_config_groups — default managed config groups for cli-config.json.
cursor_config_groups() { echo "settings"; }

# Cursor CLI settings have no project scope: the project .cursor/cli.json
# carries permissions only, so ycc never writes one. The default (unscoped)
# settings step is skipped with this note (skip_unscoped_settings, steps.sh);
# an explicit --project is rejected in preflight with the note appended.
cursor_settings_scope_note() { echo "Cursor's project .cursor/cli.json carries permissions only; every other CLI setting is global."; }

# cursor_settings_global_dest — the only settings destination (the note names
# it for the --global command that restores the old behavior).
cursor_settings_global_dest() { echo "${HOME}/.cursor/cli-config.json"; }

# Both modes register the GitHub marketplace.
cursor_supports_repo_mode() { return 0; }

# The native plugins carry the skills; nothing is written to ~/.cursor/skills.
cursor_reads_agents_skills() { return 1; }

# cursor_hint_packages — the native packages the requested intents name, plus
# the ones replacing legacy carriers this run's cleanup retired (CURSOR_RETIRED).
cursor_hint_packages() {
    local -a wanted=()
    local intent
    # shellcheck disable=SC2206  # word-split the space-separated package list.
    wanted+=(${CURSOR_RETIRED:-})
    if [[ -n "${PACKAGE:-}" ]]; then
        wanted+=("${PACKAGE}")
    elif [[ ${#INTENTS[@]} -gt 0 ]]; then
        for intent in "${INTENTS[@]}"; do
            case "${intent}" in
                base|skills|agents|commands) wanted+=(ycc) ;;
                rules) wanted+=(ycc-rules) ;;
                mcp) wanted+=(ycc-mcp) ;;
                hooks) wanted+=(ycc-hooks) ;;
            esac
        done
    else
        wanted+=(ycc)
        [[ "${RULES:-0}" == "1" ]] && wanted+=(ycc-rules)
        [[ "${MCP:-0}" == "1" ]] && wanted+=(ycc-mcp)
        [[ "${HOOKS:-0}" == "1" ]] && wanted+=(ycc-hooks)
    fi
    # Stable package order, each once.
    local -a packages=()
    local package
    for package in ycc ycc-rules ycc-mcp ycc-hooks; do
        [[ " ${wanted[*]:-} " == *" ${package} "* ]] && packages+=("${package}")
    done
    echo "${packages[*]}"
}

# cursor_marketplace_registered — true when 'agent plugin marketplace list
# --format json' shows a marketplace sourced from the ycc GitHub repository.
# An unreadable listing counts as unregistered.
cursor_marketplace_registered() {
    local listing
    listing="$(agent plugin marketplace list --format json 2>/dev/null)" || return 1
    python3 -c '
import json
import sys

repo = sys.argv[1].rstrip("/").removesuffix(".git").lower()


def found(value: object) -> bool:
    if isinstance(value, dict):
        return any(found(v) for v in value.values())
    if isinstance(value, list):
        return any(found(v) for v in value)
    return isinstance(value, str) and value.rstrip("/").removesuffix(".git").lower().endswith(repo)


sys.exit(0 if found(json.loads(sys.argv[2])) else 1)
' "${CURSOR_MARKETPLACE_URL#https://}" "${listing}" 2>/dev/null
}

# cursor_plugins_hint — how to pick the packages in Cursor.
cursor_plugins_hint() {
    local packages
    packages="$(cursor_hint_packages)"
    info "Install the packages in Cursor: open /plugins (agent CLI or IDE), pick the '${CURSOR_MARKETPLACE_NAME}' marketplace and select: ${packages}"
}

# cursor_legacy_cleanup — retire the installer-owned file-copy leftovers and set
# CURSOR_RETIRED to the native packages that replace what it retired. A refusal
# (an edited carrier, a malformed hooks.json) is reported and never fatal: the
# native route does not depend on it, and later targets still run.
CURSOR_RETIRED=""
cursor_legacy_cleanup() {
    local out rc=0 line
    printf '\n%sCursor: retire installer-owned legacy copies%s\n' "${BOLD}" "${NC}"
    out="$(run_legacy_cleanup cursor 2>&1)" || rc=$?
    [[ -n "${out}" ]] && printf '%s\n' "${out}"
    CURSOR_RETIRED=""
    while IFS= read -r line; do
        [[ "${line}" == "Cursor legacy carriers "*" for: "* ]] && CURSOR_RETIRED="${line##* for: }"
    done <<< "${out}"
    if [[ ${rc} -ne 0 ]]; then
        warn "Cursor legacy cleanup kept every file-copy leftover (see above); resolve it, then re-run: ${CLI_NAME:-./install.sh} ${COMMAND} --target cursor"
    fi
}

# cursor_base_step — register the marketplace, retire the installer-owned
# file-copy leftovers, then print the /plugins hint.
cursor_base_step() {
    printf '\n%sCursor: register the ycc plugin marketplace%s\n' "${BOLD}" "${NC}"
    [[ "${MODE:-local}" == "local" ]] && \
        info "Cursor rejects filesystem marketplaces: registering the published catalog ${CURSOR_MARKETPLACE_URL}"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        info "[dry-run] would run: agent plugin marketplace add ${CURSOR_MARKETPLACE_URL}"
    elif ! command -v agent >/dev/null 2>&1; then
        warn "Cursor 'agent' CLI not found: in the Cursor IDE open /plugins, add the marketplace ${CURSOR_MARKETPLACE_URL}, then install the packages below"
    elif cursor_marketplace_registered; then
        info "ycc marketplace already registered (${CURSOR_MARKETPLACE_URL})"
    else
        agent plugin marketplace add "${CURSOR_MARKETPLACE_URL}" || {
            err "agent plugin marketplace add ${CURSOR_MARKETPLACE_URL} failed"
            exit 1
        }
    fi
    cursor_legacy_cleanup
    printf '\n'
    cursor_plugins_hint
}

cursor_settings_step() {
    printf '\n%sCursor: merge CLI settings%s\n' "${BOLD}" "${NC}"
    merge_settings_config "cursor-cli" "${CURSOR_CLI_CONFIG_SRC}" "${HOME}/.cursor/cli-config.json" "settings"
}

# ---------------------------------------------------------------------------
# Cursor sync (base: native marketplace + legacy cleanup; settings: cli-config.json)
# ---------------------------------------------------------------------------
sync_cursor_target() {
    validate_only_steps "cursor"
    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    local ran=0
    if step_enabled base; then
        cursor_base_step
        ran=1
    fi
    if step_enabled settings; then
        [[ "${DRY_RUN:-0}" == "1" ]] || mkdir -p "${HOME}/.cursor"
        cursor_settings_step
        ran=1
    fi
    [[ ${ran} -eq 1 ]] || warn "Cursor target ran no steps"
    printf '\n%sCursor %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
}

# ---------------------------------------------------------------------------
# Cursor remove (base: drop the marketplace + legacy cleanup; settings)
# ---------------------------------------------------------------------------
remove_cursor_target() {
    validate_only_steps "cursor"
    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    local ran=0
    if step_enabled settings; then
        printf '\n%sCursor: remove managed CLI settings%s\n' "${BOLD}" "${NC}"
        remove_settings "cursor-cli" "${CURSOR_CLI_CONFIG_SRC}" "${HOME}/.cursor/cli-config.json" "settings"
        ran=1
    fi
    if step_enabled base; then
        printf '\n%sCursor: remove the ycc plugin marketplace%s\n' "${BOLD}" "${NC}"
        if [[ "${DRY_RUN:-0}" == "1" ]]; then
            info "[dry-run] would run: agent plugin marketplace remove ${CURSOR_MARKETPLACE_NAME} (if registered)"
        elif ! command -v agent >/dev/null 2>&1; then
            warn "Cursor 'agent' CLI not found: remove the ycc packages and marketplace in the Cursor IDE (/plugins)"
        elif cursor_marketplace_registered; then
            agent plugin marketplace remove "${CURSOR_MARKETPLACE_NAME}" || {
                err "agent plugin marketplace remove ${CURSOR_MARKETPLACE_NAME} failed"
                exit 1
            }
        else
            info "ycc marketplace not registered; nothing to remove"
        fi
        cursor_legacy_cleanup
        ran=1
    fi
    [[ ${ran} -eq 1 ]] || warn "Cursor target ran no steps"
    printf '\n%sCursor remove complete.%s\n' "${BOLD}" "${NC}"
}
