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
        # The project root itself can be ~/.config/opencode when that
        # directory is versioned as its own repo; then the "project" file IS
        # the global file, and companions must not land in a nested
        # .opencode/ directory. Fall back to the global paths.
        if [[ "${OPENCODE_SETTINGS_FILE}" == "$(opencode_settings_global_dest)" ]]; then
            OPENCODE_SETTINGS_FILE="$(opencode_settings_global_dest)"
            OPENCODE_COMPANION_DIR="${HOME}/.config/opencode"
        fi
    else
        OPENCODE_SETTINGS_FILE="${HOME}/.config/opencode/opencode.json"
        OPENCODE_COMPANION_DIR="${HOME}/.config/opencode"
    fi
}

# opencode_preflight — with --project, a plugins selection must name catalog
# plugins only: the bundle plugins and the guard directory are global-only
# (the bundle settings group is project-capable since the settings step now
# defaults to project scope).
opencode_preflight() {
    [[ "${SCOPE}" == "project" ]] || return 0
    target_runs_step opencode settings || return 0
    target_merges_group opencode plugins || return 0
    has_selection plugins || return 0
    local name bundle=""
    local -a names=()
    mapfile -t names < <(opencode_catalog_names)
    for name in $(selection_for_target plugins opencode | tr ',' ' '); do
        [[ -n "${name}" ]] || continue
        [[ " ${names[*]} " == *" ${name} "* ]] || bundle+="${bundle:+,}${name}"
    done
    if [[ -n "${bundle}" ]]; then
        err "--project for opencode plugins supports catalog plugins only (the bundle plugins and the guard directory are global-only)"
        err "  bundle plugins selected: ${bundle//,/, }"
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
    python3 "${CONFIG_MERGE_HELPER}" --profile opencode-catalog --destination "$2" \
        --state-scope "$1" --has-state >/dev/null 2>&1
}

# opencode_catalog_legacy_hint <sync|remove> — the settings legacy hint covers
# the opencode-config profile only; a catalog-only install
# (--intent plugins --plugins <name> --global) leaves opencode-catalog[NAME]
# state instead, so check that too, for the selected or recorded names.
opencode_catalog_legacy_hint() {
    [[ -z "${SCOPE}" && -z "${PACKAGE:-}" ]] || return 0
    [[ "$(step_scope opencode settings)" == "project" ]] || return 0
    [[ -z "${SETTINGS_LEGACY_HINT_SHOWN[opencode]:-}" ]] || return 0
    local name
    for name in $(opencode_catalog_names); do
        if opencode_catalog_has_state "${name}" "$(opencode_settings_global_dest)"; then
            warn "opencode: settings now default to project scope; $(opencode_settings_global_dest) still holds ycc-managed keys from earlier syncs — pass --global to update or remove them."
            SETTINGS_LEGACY_HINT_SHOWN[opencode]=1
            return 0
        fi
    done
}
