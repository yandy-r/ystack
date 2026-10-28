# shellcheck shell=bash
# bundle.sh — bundle selection, mirroring and removal for the install/sync/remove steps.
#
# Sourced by install.sh (never run directly); relies on its helpers (info,
# warn, err, step_enabled) and globals (SCRIPT_DIR, COMMAND, FORCE).
#
# 'base' ships a target's whole bundle (claude/codex: the registered plugin;
# cursor/opencode: the mirrored bundle dirs). The 'skills', 'agents' and
# 'commands' slices install just those entries, standalone, into the tool's
# own user directories (~/.claude/skills/<name>, ~/.codex/agents/<name>.toml,
# ...) via scripts/install_slices.py — no plugin registration involved.

SLICE_HELPER="${SCRIPT_DIR}/scripts/install_slices.py"

# selected_slices <slice...> — echo the given slices whose step is enabled.
selected_slices() {
    local -a picked=()
    local slice
    for slice in "$@"; do
        step_enabled "${slice}" && picked+=("${slice}")
    done
    echo "${picked[*]}"
}

# slice_selection_kinds <target> <slice> — the --<kind> selections that
# narrow <slice> on <target>, space-separated (empty: the whole slice). Claude
# skills are its commands: on install/sync its skills slice takes the union of
# --skills and --commands over whichever of those steps run; a kind without a
# selection does not widen it. On remove only --skills narrows it: removing
# claude commands only retires legacy wrappers, never skills.
slice_selection_kinds() {
    local -a kinds=()
    local kind
    if [[ "$1" == claude && "$2" == skills ]]; then
        for kind in skills commands; do
            # shellcheck disable=SC2153  # COMMAND is install.sh's subcommand global.
            [[ "${kind}" == commands && "${COMMAND}" == remove ]] && continue
            step_enabled "${kind}" && has_selection "${kind}" && kinds+=("${kind}")
        done
    elif is_selectable_kind "$2" && has_selection "$2"; then
        kinds=("$2")
    fi
    echo "${kinds[*]:-}"
}

# run_slice <target> <slice> [select] — install (or, under 'remove', take
# back) one standalone slice. Entries ycc did not install are never replaced
# or removed without --force. With 'select' (passed only where the slice STEP
# runs, never for 'base'), a --skills / --agents / --commands selection
# narrows the slice to the named entries <target> ships; it ships none of
# them → skip.
run_slice() {
    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    local target="$1" slice="$2" action="install"
    # shellcheck disable=SC2153  # COMMAND is install.sh's subcommand global.
    [[ "${COMMAND}" == "remove" ]] && action="remove"
    local -a command=(python3 "${SLICE_HELPER}" "${action}" --target "${target}" --slice "${slice}")
    [[ "${FORCE:-0}" == "1" ]] && command+=(--force)
    [[ "${DRY_RUN:-0}" == "1" ]] && command+=(--dry-run)
    local -a kinds=()
    [[ "${3:-}" == "select" ]] && read -r -a kinds <<< "$(slice_selection_kinds "${target}" "${slice}")"
    # Claude remove: --commands names legacy wrappers to retire, not skills;
    # without --skills the skills slice would go whole, so skip it instead.
    if [[ "${3:-}" == "select" && "${action}" == remove && "${target}" == claude && "${slice}" == skills \
        && ${#kinds[@]} -eq 0 ]] && has_selection commands; then
        info "--commands only retires legacy command wrappers on claude; pass --skills to remove skills — skipping the skills slice"
        return 0
    fi
    if [[ ${#kinds[@]} -gt 0 ]]; then
        local kind name names="" selected="" nouns="${SELECTION_NOUNS[${kinds[0]}]}"
        for kind in "${kinds[@]}"; do
            for name in $(selection_for_target "${kind}" "${target}" | tr ',' ' '); do
                [[ ",${names}," == *",${name},"* ]] || names+="${names:+,}${name}"
            done
            selected+="${selected:+ }$(selection_for "${kind}" | tr ',' ' ')"
        done
        if [[ -z "${names}" ]]; then
            warn "none of the selected ${nouns} (${selected}) ship for ${target} — skipping"
            return 0
        fi
        info "${nouns^}: ${names//,/, }"
        command+=(--entries "${names}")
        # What another kind's step installs on this target in the same run
        # counts as available for the dependency warnings ('*': its whole slice).
        # On claude the 'commands' intent is an alias for the skills slice;
        # commands only need their paired skills.
        local other pending
        for other in skills agents; do
            [[ "${other}" != "${slice}" ]] || continue
            [[ "${slice}" != commands || "${other}" == skills ]] || continue
            # 'base' ships every skill this run (mirror, plugin, or the
            # consolidated ~/.agents/skills), so commands' skills are pending.
            if [[ "${slice}" == commands ]] && step_enabled base; then
                pending='*'
            else
                step_enabled "${other}" || { [[ "${other}" == skills && "${target}" == claude ]] && step_enabled commands; } || continue
                pending='*'
                # Claude skills: narrowed by the same --skills/--commands union
                # its skills slice installs with (empty union: whole slice).
                local -a union=()
                if [[ "${other}" == skills && "${target}" == claude ]]; then
                    read -r -a union <<< "$(slice_selection_kinds claude skills)"
                elif has_selection "${other}"; then
                    union=("${other}")
                fi
                if [[ ${#union[@]} -gt 0 ]]; then
                    pending=""
                    for kind in "${union[@]}"; do
                        pending+="${pending:+,}$(selection_for_target "${kind}" "${target}")"
                    done
                fi
            fi
            command=(env "YCC_PENDING_${other^^}=${pending}" "${command[@]}")
        done
    fi
    "${command[@]}"
}

# selected_bundle_units <unit...>
# Echo (space-separated) which generated bundle <unit>s need (re)generating:
# all of them when 'base' is enabled, otherwise the ones an enabled slice
# step installs. 'shared' (cross-skill helpers that skill bodies reference)
# rides along with 'skills'.
selected_bundle_units() {
    if step_enabled base; then
        echo "$*"
        return 0
    fi
    local -a picked=()
    local unit
    for unit in "$@"; do
        case "${unit}" in
            skills|agents|commands) step_enabled "${unit}" && picked+=("${unit}") ;;
            shared) step_enabled skills && picked+=(shared) ;;
        esac
    done
    echo "${picked[*]}"
}

# require_scripts <path...> — fail unless every helper script exists and is readable.
require_scripts() {
    local s
    for s in "$@"; do
        [[ -f "${s}" ]] || { err "Missing required script: ${s}"; exit 1; }
        [[ -r "${s}" ]] || { err "Script not readable: ${s}"; exit 1; }
    done
}

# sync_bundle_units <src_root> <dest_root> <unit...>
# Mirror each <src_root>/<unit>/ into <dest_root>/<unit>/ (rsync --delete). A
# unit the bundle no longer ships is removed from the destination.
sync_bundle_units() {
    local src_root="$1" dest_root="$2"
    shift 2
    local unit src_unit dest_unit
    for unit in "$@"; do
        src_unit="${src_root}/${unit}/"
        dest_unit="${dest_root}/${unit}/"
        if [[ -d "${src_unit}" ]]; then
            if dry_run_note copy "${src_unit}" "${dest_unit}"; then
                if [[ -d "${dest_unit}" ]]; then
                    local itemized line pruned
                    itemized="$(rsync -an --delete --itemize-changes "${src_unit}" "${dest_unit}")"
                    while IFS= read -r line; do
                        [[ "${line}" == '*deleting'* ]] || continue
                        pruned="${line#'*deleting'}"
                        pruned="${pruned#"${pruned%%[![:space:]]*}"}"
                        info "[dry-run] would remove ${dest_unit}${pruned}"
                    done <<< "${itemized}"
                fi
                continue
            fi
            mkdir -p "${dest_unit}"
            rsync -av --delete "${src_unit}" "${dest_unit}"
            info "Synced ${unit}/ → ${dest_unit}"
        elif [[ -d "${dest_unit}" ]]; then
            if ! dry_run_note remove "${dest_unit}"; then
                rm -rf "${dest_unit}"
                warn "Removed ${dest_unit} (missing from $(basename "${src_root}"))"
            fi
        else
            warn "Source not found, skipping: ${src_unit}"
        fi
    done
}

# remove_mirrored_entries <src_dir> <dest_dir> — delete each top-level entry
# the bundle ships from the installed mirror, then the mirror if left empty.
# Entries a newer or older bundle shipped under other names are not touched.
remove_mirrored_entries() {
    local src_dir="$1" dest_dir="$2"
    if [[ ! -d "${dest_dir}" ]]; then
        info "nothing to remove: ${dest_dir}"
        return 0
    fi
    [[ -d "${src_dir}" ]] || { warn "bundle source missing, skipping: ${src_dir}"; return 0; }
    local entry name count=0
    for entry in "${src_dir}"/* "${src_dir}"/.[!.]*; do
        [[ -e "${entry}" || -L "${entry}" ]] || continue
        name="$(basename "${entry}")"
        if [[ -e "${dest_dir}/${name}" || -L "${dest_dir}/${name}" ]]; then
            dry_run_note remove "${dest_dir}/${name}" || rm -rf "${dest_dir:?}/${name}"
            count=$((count + 1))
        fi
    done
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        local retained=0
        for entry in "${dest_dir}"/* "${dest_dir}"/.[!.]* "${dest_dir}"/..?*; do
            [[ -e "${entry}" || -L "${entry}" ]] || continue
            name="$(basename "${entry}")"
            if [[ ! -e "${src_dir}/${name}" && ! -L "${src_dir}/${name}" ]]; then
                retained=1
                break
            fi
        done
        [[ ${retained} -eq 1 ]] || dry_run_note remove "${dest_dir}"
        return 0
    fi
    info "removed ${count} bundle entr$([[ ${count} -eq 1 ]] && echo y || echo ies) from ${dest_dir}"
    if rmdir "${dest_dir}" 2>/dev/null; then
        info "removed empty directory ${dest_dir}"
    fi
}

# remove_slices <target> <slice...> — take back each enabled standalone slice
# (narrowed by a --skills / --agents / --commands selection).
remove_slices() {
    local target="$1" slice
    shift
    for slice in $(selected_slices "$@"); do
        printf '\n%s%s: remove standalone %s%s\n' "${BOLD}" "${target}" "${slice}" "${NC}"
        run_slice "${target}" "${slice}" select
    done
}
