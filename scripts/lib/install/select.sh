# shellcheck shell=bash
# select.sh — item selection: --<kind> <names> narrows a step to the named
# items (--mcps for opencode's mcp step, --skills / --agents / --commands for
# the opencode / agents standalone slices, --mods for the claude mods step,
# --plugins for the settings step's plugins config group), and
# 'list [<kind>]' prints them. --with-deps (install/sync) extends a
# --skills / --agents selection per target with its ycc:<name> dependencies
# the target ships (expand_with_deps, called by run_target).
#
# Native-package targets (claude, codex, cursor, omp) install whole packages,
# so NATIVE_UNSELECTABLE_KINDS cannot narrow them: preflight_native_selections
# rejects such a selection when only native targets run, and skips those
# targets with one notice otherwise.
#
# Adding a kind: append it to SELECTABLE_KINDS, add its registry rows below
# and define a '<kind>_names <target>' adapter (names the repo ships for
# <target>, one per line). Parsing, preflight, 'list' and shell completion
# pick it up from here; the kind's step reads selection_for_target. A kind
# that narrows one managed config group of its step also sets
# SELECTION_GROUP: preflight then also requires that group on the target.
#
# Sourced by install.sh (never run directly); uses err/warn from core.sh,
# TARGETS / resolve_targets / valid_steps_for_target / step_enabled /
# config_groups_for_target from steps.sh, and PACKAGE / INTENTS / CLI_NAME at
# call time.

SELECTABLE_KINDS=(mcps skills agents commands plugins mods)
declare -gA SELECTION_STEP=([mcps]=mcp [skills]=skills [agents]=agents [commands]=commands [plugins]=settings [mods]=mods)
declare -gA SELECTION_NOUN=([mcps]="MCP server" [skills]=skill [agents]=agent [commands]=command [plugins]=plugin [mods]=mod)
declare -gA SELECTION_NOUNS=([mcps]="MCP servers" [skills]=skills [agents]=agents [commands]=commands [plugins]=plugins [mods]=mods)
# Kinds (plus --with-deps) that narrow only the opencode / agents targets.
NATIVE_UNSELECTABLE_KINDS=(mcps skills agents commands)
NATIVE_TARGETS=(claude codex cursor omp)
declare -gA SELECTION_STEP_HINT=(
    [mcps]="sync/remove --intent mcp, install --mcp or --only mcp"
    [skills]="it narrows the standalone skills slice; use --intent skills or --only skills"
    [agents]="it narrows the standalone agents slice; use --intent agents or --only agents"
    [commands]="it narrows the standalone commands slice; use --intent commands or --only commands"
    [plugins]="it narrows the plugins config group; use --intent plugins, or install --only settings"
    [mods]="claude only; use --intent mods or --only mods"
)
# SELECTION_GROUP[<kind>] — the managed config group (config_groups_for_target)
# a kind narrows; unset for kinds that narrow a whole step.
declare -gA SELECTION_GROUP=([plugins]=plugins)
# SELECTION[<kind>] — the names given with --<kind>, comma-separated.
declare -gA SELECTION=()

# mcps_names <target> — MCP servers the repo manages for <target>'s MCP
# merge step (opencode only; native targets ship the whole ycc-mcp package).
mcps_names() {
    [[ "$1" == opencode ]] || return 0
    local profile src
    read -r profile src <<< "$(mcp_source "$1")"
    python3 "${CONFIG_MERGE_HELPER}" --profile "${profile}" --source "${src}" \
        --destination /dev/null --groups mcp --list-entries
}

# plugins_names <target> — the plugin entries <target>'s plugins config group
# manages: claude/codex 'name@marketplace' keys, opencode package names
# (versions stripped), then the target's opt-in catalog names
# (<t>_catalog_names, opencode). Marketplaces follow their plugins and are
# never listed. Empty for targets without a plugins group.
plugins_names() {
    [[ ",$("${1}_config_groups")," == *",plugins,"* ]] || return 0
    if [[ "$1" == codex ]]; then
        python3 "${SCRIPT_DIR}/scripts/codex_install.py" settings --groups plugins --list-entries
        return
    fi
    local profile src
    read -r profile src <<< "$(plugins_source "$1")"
    python3 "${CONFIG_MERGE_HELPER}" --profile "${profile}" --source "${src}" \
        --destination /dev/null --groups plugins --list-entries
    if declare -F "${1}_catalog_names" >/dev/null; then
        "${1}_catalog_names"
    fi
}

# mods_names <target> — the mods claude's mods step installs (the ycc-mods
# marketplace's plugins); other targets have no mods step.
mods_names() {
    [[ "$1" == claude ]] || return 0
    mods_plugin_names
}

# skills_names <target> / agents_names <target> — the selectable entries of
# <target>'s standalone skills / agents slice (helper entries such as _shared
# are never listed; file entries by stem). Empty for native-package targets.
skills_names() {
    native_target "$1" && return 0
    python3 "${SLICE_HELPER}" list --target "$1" --slice skills
}

agents_names() {
    native_target "$1" && return 0
    python3 "${SLICE_HELPER}" list --target "$1" --slice agents
}

# commands_names <target> — the commands <target>'s commands step installs.
commands_names() {
    native_target "$1" && return 0
    python3 "${SLICE_HELPER}" list --target "$1" --slice commands
}

# native_target <target> — true for a native-package target (claude, codex,
# cursor, omp), which no NATIVE_UNSELECTABLE_KINDS selection narrows.
native_target() {
    [[ " ${NATIVE_TARGETS[*]} " == *" $1 "* ]]
}

# native_selection_flags — the given --<kind> (NATIVE_UNSELECTABLE_KINDS) and
# --with-deps flags, space-separated (empty when none was passed).
native_selection_flags() {
    local kind
    local -a flags=()
    for kind in "${NATIVE_UNSELECTABLE_KINDS[@]}"; do
        has_selection "${kind}" && flags+=("--${kind}")
    done
    [[ "${WITH_DEPS:-0}" == "1" ]] && flags+=(--with-deps)
    [[ -n "${SKILLS_HOME:-}" ]] && flags+=(--skills-home)
    echo "${flags[*]:-}"
}

# preflight_native_selections — the flags above apply to opencode and agents
# only. With only native targets selected they are an error; next to
# opencode/agents, the native targets skip them with one notice.
preflight_native_selections() {
    local flags target
    flags="$(native_selection_flags)"
    [[ -n "${flags}" ]] || return 0
    local -a native=() other=()
    for target in "${TARGETS[@]}"; do
        if native_target "${target}"; then native+=("${target}"); else other+=("${target}"); fi
    done
    [[ ${#native[@]} -gt 0 ]] || return 0
    if [[ ${#other[@]} -eq 0 ]]; then
        err "${flags// /, } narrow only the opencode and agents targets; ${native[*]// /, } install whole native packages"
        err "  drop ${flags// /, }, or add --target opencode / agents."
        exit 1
    fi
    local joined="${native[*]}"
    info "${flags// /, }: native-package targets ${joined// /, } install whole packages — skipped there" >&2
}

# is_selectable_kind <name> — true when --<name> selects items.
is_selectable_kind() {
    [[ " ${SELECTABLE_KINDS[*]} " == *" $1 "* ]]
}

# parse_selection <kind> <csv> — set SELECTION[<kind>] (spaces dropped, deduped, order kept).
parse_selection() {
    local kind="$1" name
    local -a requested=() names=()
    IFS=',' read -r -a requested <<< "${2// /}"
    for name in "${requested[@]}"; do
        if [[ -z "${name}" ]]; then
            err "--${kind} contains an empty value"
            exit 1
        fi
        [[ " ${names[*]:-} " == *" ${name} "* ]] || names+=("${name}")
    done
    if [[ ${#names[@]} -eq 0 ]]; then
        err "--${kind} requires at least one ${SELECTION_NOUN[${kind}]}"
        exit 1
    fi
    local IFS=','
    SELECTION[${kind}]="${names[*]}"
}

# selection_for <kind> — the --<kind> names, comma-separated (empty: none given).
selection_for() {
    echo "${SELECTION[$1]:-}"
}

has_selection() {
    [[ -n "${SELECTION[$1]:-}" ]]
}

# selection_for_target <kind> <target> — the selected names <target> ships, comma-separated.
selection_for_target() {
    local -a shipped=() selected=()
    local name
    mapfile -t shipped < <("${1}_names" "$2")
    for name in ${SELECTION[$1]//,/ }; do
        [[ " ${shipped[*]:-} " == *" ${name} "* ]] && selected+=("${name}")
    done
    local IFS=','
    echo "${selected[*]:-}"
}

# kind_step_selected <kind> <target> — true when the run executes <target>'s
# step for <kind> (and, for a SELECTION_GROUP kind, that step merges the group).
kind_step_selected() {
    target_runs_step "$2" "${SELECTION_STEP[$1]}" || return 1
    [[ -n "${SELECTION_GROUP[$1]:-}" ]] || return 0
    target_merges_group "$2" "${SELECTION_GROUP[$1]}"
}

# expand_with_deps <target> — under --with-deps, extend <target>'s --skills /
# --agents selection with the ycc:<name> dependencies of its selected names
# that <target> ships and lacks (or that ycc owns): install_slices.py closure.
# Only a kind with a selection whose step runs is extended. Skills
# consolidated into ~/.agents/skills are not this target's to install, so they
# keep warning. Native-package targets have no slices. Called by run_target,
# which restores the selection after.
expand_with_deps() {
    [[ "${WITH_DEPS:-0}" == "1" ]] || return 0
    local target="$1" kind names line added name
    native_target "${target}" && return 0
    local -a seeds=()
    for kind in skills agents; do
        if ! has_selection "${kind}" || ! step_enabled "${kind}"; then continue; fi
        [[ "${kind}" == skills ]] && skills_consolidated "${target}" && continue
        names="$(selection_for_target "${kind}" "${target}")"
        [[ -n "${names}" ]] && seeds+=("--${kind}" "${names}")
    done
    [[ ${#seeds[@]} -gt 0 ]] || return 0
    local output
    output="$(python3 "${SLICE_HELPER}" closure --target "${target}" "${seeds[@]}")" \
        || { err "${target}: --with-deps dependency lookup failed"; exit 1; }
    while IFS=$'\t' read -r kind added; do
        [[ -n "${added}" ]] || continue
        local -a fresh=()
        for name in ${added//,/ }; do
            [[ ",${SELECTION[${kind}]:-}," == *",${name},"* ]] && continue
            SELECTION[${kind}]+="${SELECTION[${kind}]:+,}${name}"
            fresh+=("${name}")
        done
        [[ ${#fresh[@]} -gt 0 ]] || continue
        line="${fresh[*]}"
        info "${target}: --with-deps adds ${SELECTION_NOUNS[${kind}]}: ${line// /, }"
    done <<< "${output}"
}

# target_runs_step <target> <step> — true when the run executes <step> on
# <target>. Subshell: intent mapping rewrites ONLY_STEPS.
target_runs_step() {
    local step="$2"
    [[ ",$(valid_steps_for_target "$1")," == *",${step},"* ]] || return 1
    (
        if [[ -n "${PACKAGE:-}" ]]; then
            package_configure_steps "$(package_steps_csv "$1")"
        elif [[ ${#INTENTS[@]} -gt 0 ]]; then
            configure_intents_for_target "$1" >/dev/null
        fi
        step_enabled "${step}"
    )
}

# target_merges_group <target> <group> — true when <target>'s settings step
# merges managed config <group> this run. Subshell, as target_runs_step.
target_merges_group() {
    (
        if [[ -n "${PACKAGE:-}" ]]; then
            package_configure_steps "$(package_steps_csv "$1")"
        elif [[ ${#INTENTS[@]} -gt 0 ]]; then
            configure_intents_for_target "$1" >/dev/null
        fi
        [[ ",$(config_groups_for_target "$1")," == *",$2,"* ]]
    )
}

# preflight_selections — each --<kind> needs its step on a selected target,
# and every name must ship for at least one of them. A target that ships only
# some of the names warns here and skips the rest; one that ships none skips
# its step (the step says so when it runs). Native-package targets never take
# a NATIVE_UNSELECTABLE_KINDS selection (install.sh ran
# preflight_native_selections right after resolving the targets).
preflight_selections() {
    local kind target name any
    local -a selected=() shipped=() names=() missing=() partial=()
    for kind in "${SELECTABLE_KINDS[@]}"; do
        has_selection "${kind}" || continue
        IFS=',' read -r -a selected <<< "${SELECTION[${kind}]}"
        shipped=()
        partial=()
        any=0
        for target in "${TARGETS[@]}"; do
            if native_target "${target}" && [[ " ${NATIVE_UNSELECTABLE_KINDS[*]} " == *" ${kind} "* ]]; then
                continue
            fi
            kind_step_selected "${kind}" "${target}" || continue
            any=1
            mapfile -t names < <("${kind}_names" "${target}")
            missing=()
            for name in "${selected[@]}"; do
                [[ " ${names[*]:-} " == *" ${name} "* ]] || missing+=("${name}")
            done
            if [[ ${#missing[@]} -gt 0 && ${#missing[@]} -lt ${#selected[@]} ]]; then
                partial+=("${target} does not ship ${SELECTION_NOUNS[${kind}]} ${missing[*]} — skipping them there")
            fi
            for name in ${names[@]+"${names[@]}"}; do
                [[ " ${shipped[*]:-} " == *" ${name} "* ]] || shipped+=("${name}")
            done
        done
        if [[ ${any} -eq 0 ]]; then
            err "--${kind} needs the ${SELECTION_STEP[${kind}]} step (${SELECTION_STEP_HINT[${kind}]}) on a target that has one"
            exit 1
        fi
        for name in "${selected[@]}"; do
            if [[ " ${shipped[*]:-} " != *" ${name} "* ]]; then
                err "unknown ${SELECTION_NOUN[${kind}]} '${name}' (managed for ${TARGETS[*]}: ${shipped[*]:-none})"
                err "  list them with: ${CLI_NAME} list ${kind} --target <targets>"
                exit 1
            fi
        done
        for name in ${partial[@]+"${partial[@]}"}; do warn "${name}"; done
    done
}

# run_list_command [<kind>] [--target <targets>] — no kind: print the
# selectable kinds; else the <kind> names the repo ships for the targets
# (default all) whose valid steps include the kind's step, first-seen order,
# one per line. Shell completion reads both. LIST_COMMAND_LABEL names the
# command in errors (the list-mcps alias sets it; its kind is fixed).
run_list_command() {
    local kind="" target_csv="all" label="${LIST_COMMAND_LABEL:-list}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                [[ $# -lt 2 ]] && { err "--target requires an argument"; exit 1; }
                target_csv="$2"
                shift 2
                ;;
            --help|-h) usage; exit 0 ;;
            -*) err "Unknown option for ${label}: $1"; exit 1 ;;
            *)
                if [[ -n "${kind}" ]]; then
                    [[ "${label}" == list ]] && err "list takes one kind (got '${kind}' and '$1')"
                    [[ "${label}" == list ]] || err "Unknown option for ${label}: $1"
                    exit 1
                fi
                kind="$1"
                shift
                ;;
        esac
    done
    if [[ -z "${kind}" ]]; then
        printf '%s\n' "${SELECTABLE_KINDS[@]}"
        return 0
    fi
    if ! is_selectable_kind "${kind}"; then
        err "unknown kind '${kind}' (valid: ${SELECTABLE_KINDS[*]})"
        exit 1
    fi
    resolve_targets "${target_csv}"
    local -a names=() seen=()
    local target name
    for target in "${TARGETS[@]}"; do
        [[ ",$(valid_steps_for_target "${target}")," == *",${SELECTION_STEP[${kind}]},"* ]] || continue
        mapfile -t names < <("${kind}_names" "${target}")
        for name in ${names[@]+"${names[@]}"}; do
            [[ " ${seen[*]:-} " == *" ${name} "* ]] && continue
            seen+=("${name}")
            echo "${name}"
        done
    done
}
