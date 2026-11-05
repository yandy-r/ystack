# shellcheck shell=bash
# bundle.sh — standalone slice installs for the install/sync/remove steps.
#
# Sourced by install.sh (never run directly); relies on its helpers (info,
# warn, err, step_enabled) and globals (SCRIPT_DIR, COMMAND, FORCE).
#
# A slice installs entries standalone, entry by entry, into a tool's own user
# directory (~/.agents/skills/<name>, ~/.codex/agents/<name>.toml) via
# scripts/install_slices.py — no plugin registration involved. Only the agents
# target (its skills) and codex (its custom agents, always whole) install
# slices; every other target installs native packages.

SLICE_HELPER="${SCRIPT_DIR}/scripts/install_slices.py"

# run_slice <target> <slice> [select] — install (or, under 'remove', take
# back) one standalone slice. Entries ycc did not install are never replaced
# or removed without --force. With 'select' (passed only where the slice STEP
# runs, never for 'base'), a --skills selection narrows the slice to the
# named entries <target> ships; it ships none of them → skip.
run_slice() {
    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    local target="$1" slice="$2" action="install"
    # shellcheck disable=SC2153  # COMMAND is install.sh's subcommand global.
    [[ "${COMMAND}" == "remove" ]] && action="remove"
    local -a command=(python3 "${SLICE_HELPER}" "${action}" --target "${target}" --slice "${slice}")
    [[ "${FORCE:-0}" == "1" ]] && command+=(--force)
    [[ "${DRY_RUN:-0}" == "1" ]] && command+=(--dry-run)
    if [[ "${3:-}" == "select" ]] && is_selectable_kind "${slice}" && has_selection "${slice}" \
        && ! native_target "${target}"; then
        local names nouns="${SELECTION_NOUNS[${slice}]}"
        names="$(selection_for_target "${slice}" "${target}")"
        if [[ -z "${names}" ]]; then
            warn "none of the selected ${nouns} ($(selection_for "${slice}" | tr ',' ' ')) ship for ${target} — skipping"
            return 0
        fi
        info "${nouns^}: ${names//,/, }"
        command+=(--entries "${names}")
    fi
    "${command[@]}"
}

# require_scripts <path...> — fail unless every helper script exists and is readable.
require_scripts() {
    local s
    for s in "$@"; do
        [[ -f "${s}" ]] || { err "Missing required script: ${s}"; exit 1; }
        [[ -r "${s}" ]] || { err "Script not readable: ${s}"; exit 1; }
    done
}
