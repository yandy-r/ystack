# shellcheck shell=bash disable=SC2034  # Globals are read by sourcing installer/target files.
# packages.sh — package planning ('install --package'): expands the package
# model closure into per-target installer steps (claude/codex: the native
# base, mcp and hooks plugin installs; cursor: the marketplace step; omp: its
# native packages; opencode: the @yandy-r/ycc-opencode plugins entry) and
# drives the per-target sync functions through the
# exclusive-steps machinery.
#
# Sourced by install.sh (never run directly); reads PACKAGE, TARGETS, MODE
# and ALL_TARGETS at call time. Python owns package semantics and
# rejection reasons (scripts/package_install_plan.py); this file only parses
# the plan, validates it against each target's contract, and dispatches.

PACKAGE=""
PACKAGE_ALL_TARGETS_REQUESTED=0
PACKAGE_TARGETS=()
PACKAGE_STEPS=()

# package_steps_csv <target> — the planner's comma-separated steps for <target>.
package_steps_csv() {
    local i
    for ((i = 0; i < ${#PACKAGE_TARGETS[@]}; i++)); do
        if [[ "${PACKAGE_TARGETS[i]}" == "$1" ]]; then
            printf '%s' "${PACKAGE_STEPS[i]// /,}"
            return 0
        fi
    done
    return 1
}

# package_validate_steps <target> <csv> — every planner step must be a step the
# target actually supports; the planner never emits an unsupported one, so this
# is a guard against planner/target drift, not user input.
package_validate_steps() {
    local target="$1" csv="$2"
    local -a requested=() valid=()
    IFS=',' read -r -a requested <<< "${csv}"
    IFS=',' read -r -a valid <<< "$(valid_steps_for_target "${target}")"
    local step v found
    for step in "${requested[@]}"; do
        found=0
        for v in "${valid[@]}"; do
            [[ "${step}" == "${v}" ]] && { found=1; break; }
        done
        if [[ ${found} -eq 0 ]]; then
            err "package planner selected unsupported step '${step}' for target '${target}' (valid: $(valid_steps_for_target "${target}"))"
            return 1
        fi
    done
}

# package_configure_steps <csv> — map one target's plan onto ONLY_STEPS.
package_configure_steps() {
    IFS=',' read -r -a ONLY_STEPS <<< "$1"
    EXCLUSIVE_STEPS=1
}

# package_preflight_targets — expand PACKAGE over TARGETS and validate every
# package×target pair before any target runs, mirroring preflight_targets.
package_preflight_targets() {
    PACKAGE_TARGETS=()
    PACKAGE_STEPS=()
    local skip_flag=""
    [[ "${PACKAGE_ALL_TARGETS_REQUESTED:-0}" == "1" ]] && skip_flag="--skip-unsupported"

    local targets_csv output
    targets_csv="$(IFS=,; printf '%s' "${TARGETS[*]:-}")"
    [[ -n "${targets_csv}" ]] || { err "--package requires at least one --target"; exit 1; }
    command -v python3 >/dev/null 2>&1 || { err "python3 is required for --package (package model planning)"; exit 1; }

    if ! output="$(python3 "${SCRIPT_DIR}/scripts/package_install_plan.py" \
        --packages "${PACKAGE}" --targets "${targets_csv}" --shell ${skip_flag})"; then
        exit 1
    fi

    local kind target steps
    while IFS=$'\t' read -r kind target steps; do
        case "${kind}" in
            warning) warn "${target}${steps:+ ${steps}}" ;;
            target)
                package_validate_steps "${target}" "${steps}" || exit 1
                PACKAGE_TARGETS+=("${target}")
                PACKAGE_STEPS+=("${steps//,/ }")
                ;;
            "") ;;
            *)
                err "unexpected package planner output line: ${kind}"
                exit 1
                ;;
        esac
    done <<< "${output}"

    if [[ ${#PACKAGE_TARGETS[@]} -eq 0 ]]; then
        err "no requested target can install package '${PACKAGE}'"
        exit 1
    fi
    TARGETS=("${PACKAGE_TARGETS[@]}")

    preflight_targets
}

# run_package_targets — drive each planned target through its existing sync
# function with that target's planned steps selected exclusively.
run_package_targets() {
    local target
    for target in "${TARGETS[@]}"; do
        run_target "${target}" "sync_${target}_target"
    done
}
