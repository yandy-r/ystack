# shellcheck shell=bash
# opencode-catalog.sh — the opt-in catalog of third-party opencode plugins
# (ycc/settings/opencode-plugins.json), applied by the opencode settings step.
#
# Sourced by targets/opencode.sh (never run directly). Every catalog entry is
# default-off: sync installs only the names --plugins selects; remove acts on
# the selected names, or on every catalog name without --plugins (each step is
# ownership-gated, so plugins ycc never installed are untouched).
#
# Per plugin, sync runs:
#   1. opencode_plugin_catalog.py source      -> temp {"plugins":[…],"agents":{…}}
#   2. merge_managed_config.py opencode-catalog --state-scope <name> (own state)
#   3. opencode_plugin_catalog.py companions sync (hash-owned config files)
#   4. opencode_plugin_catalog.py notes        (manual follow-ups ycc never automates)
# and remove runs the --remove merge, then (only once opencode.json no longer
# loads the plugin) `companions remove`, `purge-cache` (with --purge-cache)
# and `notes --remove`.

OPENCODE_CATALOG_HELPER="${SCRIPT_DIR}/scripts/opencode_plugin_catalog.py"

# opencode_catalog <subcommand> [args...] — run the catalog helper.
opencode_catalog() {
    python3 "${OPENCODE_CATALOG_HELPER}" "$@"
}

# opencode_catalog_names — catalog plugin names, one per line. plugins_names
# lists them after the bundle names; config_group_selection splits them off
# into PLUGINS_CATALOG_SELECT so the bundle merge only sees bundle names.
opencode_catalog_names() {
    opencode_catalog names
}

# opencode_settings_paths — set OPENCODE_SETTINGS_FILE (opencode.json) and
# OPENCODE_COMPANION_DIR for the settings step's scope: global
# ~/.config/opencode/, project <root>/opencode.json + <root>/.opencode/.
opencode_settings_paths() {
    if [[ "$(step_scope opencode settings)" == "project" ]]; then
        local root
        root="$(project_root)"
        OPENCODE_SETTINGS_FILE="${root}/opencode.json"
        OPENCODE_COMPANION_DIR="${root}/.opencode"
    else
        OPENCODE_SETTINGS_FILE="${HOME}/.config/opencode/opencode.json"
        OPENCODE_COMPANION_DIR="${HOME}/.config/opencode"
    fi
}

# opencode_preflight — project scope merges catalog plugins only: the bundle
# settings, bundle plugins and the guard directory are global-only.
opencode_preflight() {
    [[ "${SCOPE}" == "project" ]] || return 0
    target_runs_step opencode settings || return 0
    local name bundle="" catalog=""
    if has_selection plugins; then
        local -a names=()
        mapfile -t names < <(opencode_catalog_names)
        for name in $(selection_for_target plugins opencode | tr ',' ' '); do
            if [[ " ${names[*]} " == *" ${name} "* ]]; then
                catalog+="${catalog:+,}${name}"
            else
                bundle+="${bundle:+,}${name}"
            fi
        done
    fi
    if target_merges_group opencode settings || ! target_merges_group opencode plugins \
        || [[ -z "${catalog}" || -n "${bundle}" ]]; then
        err "--project for opencode settings supports catalog plugins only (the bundle settings and plugins are global-only)"
        [[ -n "${bundle}" ]] && err "  bundle plugins selected: ${bundle//,/, }"
        err "  e.g. ${CLI_NAME} sync --target opencode --intent plugins --plugins <catalog names> --project"
        err "  catalog names: $(opencode_catalog_names | paste -sd, - | sed 's/,/, /g')"
        exit 1
    fi
}

# opencode_catalog_run_names <command> — the catalog names this settings run
# acts on: the selected ones; on remove without --plugins, every catalog name.
# Empty when the run does not merge the plugins group.
opencode_catalog_run_names() {
    [[ ",$(config_groups_for_target opencode)," == *",plugins,"* ]] || return 0
    if [[ -n "${PLUGINS_CATALOG_SELECT}" ]]; then
        echo "${PLUGINS_CATALOG_SELECT}"
    elif [[ "$1" == "remove" ]] && ! has_selection plugins; then
        opencode_catalog_names | paste -sd, -
    fi
}

# opencode_catalog_sync — merge, ship companions and print notes for each
# selected catalog plugin (after config_group_selection, opencode_settings_paths).
opencode_catalog_sync() {
    local names name tmp rc=0
    names="$(opencode_catalog_run_names sync)"
    [[ -n "${names}" ]] || return 0
    info "Catalog plugins: ${names//,/, }"
    [[ "${DRY_RUN:-0}" == "1" ]] || mkdir -p "${OPENCODE_COMPANION_DIR}"
    tmp="$(mktemp -d)"
    for name in ${names//,/ }; do
        opencode_catalog_sync_one "${name}" "${tmp}/source.json" || { rc=$?; break; }
    done
    rm -rf "${tmp}"
    [[ ${rc} -eq 0 ]] || exit "${rc}"
}

# opencode_catalog_sync_one <name> <tmp source.json>
opencode_catalog_sync_one() {
    local name="$1" src="$2"
    local -a force=() dry_run=()
    [[ "${FORCE:-0}" == "1" ]] && force=(--force)
    [[ "${DRY_RUN:-0}" == "1" ]] && dry_run=(--dry-run)
    opencode_catalog source --names "${name}" --out "${src}" || return $?
    merge_settings_config opencode-catalog "${src}" "${OPENCODE_SETTINGS_FILE}" plugins,agents \
        --state-scope "${name}" || return $?
    opencode_catalog companions sync --names "${name}" --dest-dir "${OPENCODE_COMPANION_DIR}" \
        "${force[@]}" "${dry_run[@]}" || return $?
    opencode_catalog notes --names "${name}"
}

# opencode_catalog_remove — undo opencode_catalog_sync for this run's names.
opencode_catalog_remove() {
    local names name tmp rc=0
    names="$(opencode_catalog_run_names remove)"
    [[ -n "${names}" ]] || return 0
    tmp="$(mktemp -d)"
    for name in ${names//,/ }; do
        opencode_catalog_remove_one "${name}" "${tmp}/source.json" || { rc=$?; break; }
    done
    rm -rf "${tmp}"
    [[ ${rc} -eq 0 ]] || exit "${rc}"
}

# opencode_catalog_remove_one <name> <tmp source.json> — an unselected name
# (remove without --plugins) is skipped unless ycc recorded merging it into
# this opencode.json: matching values alone never prove ownership. The
# companion, the cache purge and the removal notes are left alone while
# opencode.json still loads the plugin (a kept local entry still uses them).
# The purge and notes further apply only to a selected name, or to one this
# run took out of opencode.json.
opencode_catalog_remove_one() {
    local name="$1" src="$2" loaded=0
    local -a force=() dry_run=()
    [[ "${DRY_RUN:-0}" == "1" ]] && dry_run=(--dry-run)
    if [[ ",${PLUGINS_CATALOG_SELECT}," != *",${name},"* ]] \
        && ! opencode_catalog_has_state "${name}" "${OPENCODE_SETTINGS_FILE}"; then
        return 0
    fi
    [[ "${FORCE:-0}" == "1" ]] && force=(--force)
    opencode_config_loads "${OPENCODE_SETTINGS_FILE}" "${name}" && loaded=1
    opencode_catalog source --names "${name}" --out "${src}" || return $?
    remove_settings opencode-catalog "${src}" "${OPENCODE_SETTINGS_FILE}" plugins,agents \
        --state-scope "${name}" || return $?
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        if opencode_config_loads_after_remove "${OPENCODE_SETTINGS_FILE}" "${name}" "${src}" \
            opencode-catalog plugins,agents "${name}"; then
            info "kept the ${name} companion config: ${OPENCODE_SETTINGS_FILE} would still load it"
            [[ "${PURGE_CACHE:-0}" == "1" ]] && info "kept the ${name} package cache: ${OPENCODE_SETTINGS_FILE} would still load it"
            return 0
        fi
    elif opencode_config_loads "${OPENCODE_SETTINGS_FILE}" "${name}"; then
        info "kept the ${name} companion config: ${OPENCODE_SETTINGS_FILE} still loads it"
        [[ "${PURGE_CACHE:-0}" == "1" ]] && info "kept the ${name} package cache: ${OPENCODE_SETTINGS_FILE} still loads it"
        return 0
    fi
    opencode_catalog companions remove --names "${name}" --dest-dir "${OPENCODE_COMPANION_DIR}" \
        "${force[@]}" "${dry_run[@]}" || return $?
    [[ ${loaded} -eq 1 || ",${PLUGINS_CATALOG_SELECT}," == *",${name},"* ]] || return 0
    if [[ "${PURGE_CACHE:-0}" == "1" ]]; then
        opencode_catalog purge-cache --names "${name}" "${dry_run[@]}" || return $?
    fi
    opencode_catalog notes --names "${name}" --remove
}

# opencode_config_loads_after_remove <opencode.json> <name> <src> <profile>
# <groups> [state-scope] — query the real removal plan without writing config
# or state. Planning failures conservatively report that the name still loads.
opencode_config_loads_after_remove() {
    local -a command=(
        loads-after-remove
        --destination "$1"
        --name "$2"
        --source "$3"
        --profile "$4"
        --groups "$5"
    )
    [[ $# -lt 6 ]] || command+=(--state-scope "$6")
    [[ "${FORCE:-0}" == "1" ]] && command+=(--force)
    opencode_catalog "${command[@]}"
}

# opencode_catalog_has_state <name> <opencode.json> — true when the managed
# config state records a catalog merge of <name> into <opencode.json>.
opencode_catalog_has_state() {
    local state="${YCC_MANAGED_CONFIG_STATE:-${XDG_CONFIG_HOME:-${HOME}/.config}/ycc/managed-config-state.json}"
    [[ -f "${state}" ]] || return 1
    python3 - "${state}" "opencode-catalog[$1]:$2" <<'PY'
import json
import sys

try:
    state = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if isinstance(state, dict) and state.get(sys.argv[2]) else 1)
PY
}
