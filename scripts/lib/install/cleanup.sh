# shellcheck shell=bash
# cleanup.sh — automatic retirement of installer-owned legacy state.
#
# Native targets (claude, codex, cursor, omp) call run_legacy_cleanup after a
# successful native install step and from remove. scripts/install_migrate.py
# does the work: it retires only proven installer-owned leftovers (hash,
# ownership record or byte-identical copy; never user data) and installs
# nothing. --dry-run previews.

# run_legacy_cleanup <target> — returns non-zero when the helper refuses
# (e.g. the Codex native gate fails or omp is unavailable).
run_legacy_cleanup() {
    local target="$1"
    case "${target}" in
        claude|codex|cursor|omp) ;;
        *) err "legacy cleanup is not supported for target '${target}'"; return 1 ;;
    esac
    command -v python3 >/dev/null 2>&1 || { err "python3 is required for the ${target} legacy cleanup"; return 1; }
    local -a command=(python3 "${SCRIPT_DIR}/scripts/install_migrate.py" --targets "${target}")
    [[ "${DRY_RUN:-0}" == "1" ]] && command+=(--dry-run)
    # remove: the native packages are already gone, so cleanup skips the installed proof.
    [[ "${COMMAND:-}" == "remove" ]] && command+=(--removing)
    # omp records project installs at the installer's project root; cleanup must use the same one.
    [[ "${target}" == "omp" ]] && command+=(--project-root "$(project_root)")
    "${command[@]}"
}
